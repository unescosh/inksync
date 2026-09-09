import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/hlc.dart';
import '../data/database.dart';
import 'merge.dart';
import 'webdav_client.dart';

/// 同步引擎。
///
/// 协议要点（详见 docs/02-同步协议与冲突解决.md）：
///  · 远端只**追加**文件：`changes/<HLC>-<node>.jsonl`，文件名字典序即时间序；
///  · 书籍文件按 sha256 **内容寻址**：同名即同内容，天然幂等、免冲突、可秒传；
///  · 唯一需要并发写的 `manifest.json` 用 ETag + If-Match 乐观锁，冲突则重跑。

enum SyncPhase {
  idle,
  preparing,
  pulling,
  applying,
  pushing,
  transferring,
  finalizing,
  error,
}

class SyncReport {
  int pulledChanges = 0;
  int pushedChanges = 0;
  int uploadedBooks = 0;
  int downloadedBooks = 0;
  int uploadedCovers = 0;
  int downloadedCovers = 0;
  int conflicts = 0;
  final List<String> errors = [];
  Hlc? newLastHlc;

  bool get ok => errors.isEmpty;
  bool get isEmpty =>
      pulledChanges == 0 &&
      pushedChanges == 0 &&
      uploadedBooks == 0 &&
      downloadedBooks == 0 &&
      uploadedCovers == 0 &&
      downloadedCovers == 0;

  @override
  String toString() => '拉取 $pulledChanges / 推送 $pushedChanges / '
      '上传书 $uploadedBooks / 下载书 $downloadedBooks / '
      '上传封面 $uploadedCovers / 下载封面 $downloadedCovers / 冲突 $conflicts';
}

typedef SyncProgress = void Function(SyncPhase phase, String detail, double? fraction);

/// 本地 blob 仓库：书籍原文件按 sha256 存一份，多个书架条目可共享。
abstract class BlobStore {
  Future<String?> pathFor(String sha256);
  Future<String> importFile(String sourcePath, String sha256);
}

class DefaultBlobStore implements BlobStore {
  final math.Random _rng = math.Random.secure();

  Future<Directory> get _dir async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory(p.join(base.path, 'blobs'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  @override
  Future<String?> pathFor(String sha256) async {
    final f = File(p.join((await _dir).path, sha256.substring(0, 2), sha256));
    return await f.exists() ? f.path : null;
  }

  @override
  Future<String> importFile(String sourcePath, String sha256) async {
    final dir = Directory(p.join((await _dir).path, sha256.substring(0, 2)));
    if (!await dir.exists()) await dir.create(recursive: true);
    final dest = p.join(dir.path, sha256);
    final tmp = '$dest.tmp-${_rng.nextInt(1 << 30)}';
    await File(sourcePath).copy(tmp);
    await File(tmp).rename(dest);
    return dest;
  }
}

/// 封面仓库：封面图片按 coverHash(sha256) 内容寻址，
/// 存于 <cacheDir>/covers/<hash>.<ext>（扩展名由图片魔数决定）。
///
/// 与 BlobStore 完全镜像：同名即同内容，天然幂等、免冲突、可秒传。
/// 封面字节**不进 SQLite**（漫画封面几 MB，塞进库会让每次 watch 查询变慢），
/// 只把 coverHash 进库，文件本身随书跨端传。
abstract class CoverStore {
  /// 返回本地封面文件的绝对路径（带正确扩展名）；不存在返回 null。
  Future<String?> pathFor(String coverHash);

  /// 把 sourcePath 复制为 <cacheDir>/covers/<hash>.<ext>，返回最终路径。
  Future<String> importFile(String sourcePath, String coverHash, String ext);
}

class DefaultCoverStore implements CoverStore {
  DefaultCoverStore([this.cacheDir]);

  /// 不传则默认 <AppDocuments>/cache；桌面/测试可显式注入目录。
  final String? cacheDir;

  final math.Random _rng = math.Random.secure();

  Future<Directory> get _dir async {
    final base = cacheDir ?? p.join((await getApplicationDocumentsDirectory()).path, 'cache');
    final d = Directory(p.join(base, 'covers'));
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  @override
  Future<String?> pathFor(String coverHash) async {
    if (coverHash.isEmpty) return null;
    final dir = await _dir;
    for (final ext in const ['.jpg', '.png', '.webp', '.gif']) {
      final f = File(p.join(dir.path, '$coverHash$ext'));
      if (await f.exists()) return f.path;
    }
    return null;
  }

  @override
  Future<String> importFile(String sourcePath, String coverHash, String ext) async {
    final dir = await _dir;
    final dest = p.join(dir.path, '$coverHash$ext');
    final tmp = '$dest.tmp-${_rng.nextInt(1 << 30)}';
    await File(sourcePath).copy(tmp);
    await File(tmp).rename(dest);
    return dest;
  }
}

class ManifestFile {
  ManifestFile({required this.name, required this.bytes, required this.node});

  final String name;
  final int bytes;
  final String node;

  Map<String, dynamic> toJson() => {'n': name, 'b': bytes, 'd': node};

  static ManifestFile fromJson(Map<String, dynamic> j) => ManifestFile(
        name: j['n'] as String,
        bytes: (j['b'] as num?)?.toInt() ?? 0,
        node: j['d'] as String? ?? '',
      );
}

class Manifest {
  Manifest({required this.schema, required this.lastHlc, required this.files});

  final int schema;
  final String lastHlc;
  final List<ManifestFile> files;

  Map<String, dynamic> toJson() => {
        'schema': schema,
        'lastHlc': lastHlc,
        'files': files.map((f) => f.toJson()).toList(),
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      };

  static Manifest parse(String s) {
    final j = jsonDecode(s) as Map<String, dynamic>;
    return Manifest(
      schema: (j['schema'] as num?)?.toInt() ?? 1,
      lastHlc: j['lastHlc'] as String? ?? Hlc.zero.encode(),
      files: (j['files'] as List<dynamic>? ?? [])
          .map((e) => ManifestFile.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }
}

class SyncEngine {
  SyncEngine({
    required this.db,
    required this.client,
    required this.deviceId,
    required this.clock,
    required this.blobs,
    required this.covers,
    this.remoteRoot = 'inksync',
    this.onProgress,
  });

  final AppDatabase db;
  final WebDavClient client;
  final String deviceId;
  final HlcClock clock;
  final BlobStore blobs;
  final CoverStore covers;
  final String remoteRoot;
  final SyncProgress? onProgress;

  static const int _maxManifestRetries = 5;

  /// 单次推送的 outbox 记录上限（超过就拆成多个 changes 批次文件）。
  /// 太大 → 单个巨型文件，一次网络抖动整批重来；太小 → 批次文件数量膨胀，
  /// 每次轮询要列/下载更多文件。200 条是这两者的折中。
  static const int _outboxChunkSize = 200;

  String get _changesPath => '$remoteRoot/changes';
  String get _manifestPath => '$remoteRoot/manifest.json';
  String get _blobsPath => '$remoteRoot/blobs';
  String get _coversPath => '$remoteRoot/covers';

  String blobRemotePath(String sha) => '$_blobsPath/${sha.substring(0, 2)}/$sha';
  String coverRemotePath(String hash) => '$_coversPath/${hash.substring(0, 2)}/$hash';

  void _emit(SyncPhase phase, String detail, [double? f]) => onProgress?.call(phase, detail, f);

  /// 上次传输是否留下尾巴（有失败/未完成的文件）。
  /// 为 true 时即便本轮「无变更」也要跑一次传输，否则失败的那本永远补不回来。
  Future<bool> _hasPendingTransfers() async =>
      await db.getState(SyncStateKeys.pendingTransfers) == '1';

  // ══════════════════════ 主流程 ══════════════════════

  Future<SyncReport> sync() async {
    final report = SyncReport();

    for (var attempt = 0; attempt < _maxManifestRetries; attempt++) {
      try {
        final ok = await _syncOnce(report);
        if (ok) break;
        // manifest 写冲突（412）→ 重新拉取并再试
        _emit(SyncPhase.finalizing, 'manifest 冲突，重试 ${attempt + 1}/$_maxManifestRetries');
        await Future<void>.delayed(Duration(milliseconds: 200 * (attempt + 1)));
      } catch (e) {
        report.errors.add(e.toString());
        _emit(SyncPhase.error, e.toString());
        break;
      }
    }
    // 保养：回收「已处理且过期」的冲突留痕。conflict_log 是软删（dismissed），
    // 不定时清会随时间无界增长。纯维护操作，失败不该影响本轮同步结果，故吞掉。
    try {
      await db.purgeDismissedConflicts();
    } catch (_) {
      // 忽略：下次同步会再试
    }
    return report;
  }

  /// 返回 false 表示 manifest 写冲突，需要整轮重试
  Future<bool> _syncOnce(SyncReport report) async {
    // 0. 目录结构（幂等）
    _emit(SyncPhase.preparing, '检查远端目录');
    await client.mkcolAll('$remoteRoot/');
    await client.mkcolAll('$_changesPath/');
    await client.mkcolAll('$_blobsPath/');
    await client.mkcolAll('$_coversPath/');

    final lastApplied = await db.lastAppliedHlc;

    // 1. 拉 manifest（带 ETag，未变则 304）
    final cachedEtag = await db.getState(SyncStateKeys.manifestEtag);
    final got = await client.getIfChanged(_manifestPath, cachedEtag);
    final manifestEtag = got == null ? cachedEtag : got.etag;

    // 2. 列 changes/ → 只下载比 lastApplied 新的批次
    _emit(SyncPhase.pulling, '拉取变更');
    final entries = await client.propfind('$_changesPath/', depth: 1);
    final pending = entries
        .where((e) => !e.isDir && e.name.endsWith('.jsonl'))
        .map((e) => e.name)
        .where((n) {
          final h = _hlcOfFileName(n);
          if (h == null) return false;
          if (h.node == deviceId) return false; // 自己推的不拉
          return h.compareTo(lastApplied) > 0;
        })
        .toList()
      ..sort(); // 字典序 = 时间序

    // 3. 下载并应用
    //
    // 水位线只推进到「从头连续成功应用」的最后一个批次。任何失败/部分失败的批次
    // 都必须留在未应用区间，下次重新拉取重试——否则 `h.compareTo(lastApplied) > 0`
    // 会把它永久过滤掉，等于静默丢数据（哪怕当初只是网络抖了一下）。
    // 重试是安全的：同一条记录重放时 `remoteHlc <= localHlc`，`_mergeInto` 直接返回。
    _emit(SyncPhase.applying, '应用 ${pending.length} 个远端批次');
    var appliedThrough = lastApplied;
    var blocked = false;
    for (var i = 0; i < pending.length; i++) {
      final name = pending[i];
      final batchHlc = _hlcOfFileName(name);
      try {
        final bytes = await client.getBytes('$_changesPath/$name');
        final r = await _applyBatch(utf8.decode(bytes), report);
        report.pulledChanges += r.applied;
        if (!r.ok) {
          blocked = true; // 批内有记录没落地 → 整批重来
        } else if (!blocked && batchHlc != null && batchHlc.compareTo(appliedThrough) > 0) {
          appliedThrough = batchHlc;
        }
      } catch (e) {
        // 单个批次失败不能拖垮整轮同步：记账后继续，但从这里起水位线不再推进。
        report.errors.add('批次 $name 应用失败: $e');
        blocked = true;
      }
      _emit(SyncPhase.applying, '应用远端变更', (i + 1) / (pending.isEmpty ? 1 : pending.length));
    }

    // 4. 推送本地变更（一个批次一个文件，文件名 = 当前 HLC）
    _emit(SyncPhase.pushing, '推送本地变更');
    final pushed = await _pushChanges();
    report.pushedChanges = pushed;

    // 5. 传输书籍文件 + 封面（内容寻址，已存在即秒传跳过）
    //
    // 短路：manifest 未变（304）+ 本轮没推任何本地变更 + 上次传输没留尾巴
    // ⇒ 没有任何新工作需要探测远端，直接跳过 O(书本数) 的远端存在性检查。
    // 这是 5 分钟轮询能否成立的关键：`_transferBlobs`/`_transferCovers` 对每本书
    // 各发一次探测，200 本书就是 ~400 次请求/轮，约 4800 次/小时。
    // 前提（与本项目一致）：outbox 是本地变更的唯一事实来源，所以「没有本地变更
    // 要推 + 远端没变」时，不可能凭空冒出待传文件。
    final idle = got == null && pushed == 0 && !await _hasPendingTransfers();
    if (idle) {
      _emit(SyncPhase.transferring, '无变更，跳过文件传输');
    } else {
      final errsBefore = report.errors.length;
      _emit(SyncPhase.transferring, '同步书籍文件');
      await _transferBlobs(report);
      _emit(SyncPhase.transferring, '同步封面图片');
      await _transferCovers(report);
      // 传输失败要留痕：下次即便「无变更」也要重试，否则这本永远补传不了。
      await db.setState(
        SyncStateKeys.pendingTransfers,
        report.errors.length > errsBefore ? '1' : '0',
      );
    }

    // 5c. 对齐本地仓库：无头 CLI `pull` 已把 blobs/covers 写进本地仓库，
    //     但 App 主库的 localPath/coverPath 是后来才回填的可空缓存列，
    //     这里用 pathFor 兜底补齐，让书架 UI 直接显示"已下载"。
    //     日常同步调用也无害：文件已存在则命中列本非空，不会重复写。
    _emit(SyncPhase.transferring, '对齐本地仓库');
    await reconcileLocalRepo();

    // 6. 写 manifest（乐观锁）
    _emit(SyncPhase.finalizing, '写入 manifest');
    final newManifest = await _buildManifest(appliedThrough);
    final body = utf8.encode(jsonEncode(newManifest.toJson()));
    final ok = await client.putIfMatch(_manifestPath, body, manifestEtag);
    if (!ok) return false;

    // 7. 落本地状态
    final finalEtag = (await client.propfind(_manifestPath, depth: 0)).firstOrNullEtag;
    if (finalEtag != null) await db.setState(SyncStateKeys.manifestEtag, finalEtag);
    await db.setState(SyncStateKeys.lastAppliedHlc, newManifest.lastHlc);
    await db.setState(SyncStateKeys.lastSyncAt, DateTime.now().toUtc().toIso8601String());
    report.newLastHlc = Hlc.parse(newManifest.lastHlc);

    _emit(SyncPhase.idle, '同步完成');
    return true;
  }

  // ══════════════════════ 应用远端变更 ══════════════════════

  /// 返回（成功应用的记录数, 是否**全部**成功）。
  ///
  /// 「全部成功」这个返回值很关键：只要有一条记录没落地，整批就不能算应用完成，
  /// 否则水位线一旦推进，下次 `h.compareTo(lastApplied) > 0` 会把这个批次过滤掉
  /// —— 该变更就永久丢失了（哪怕当初只是网络抖了一下）。水位线逻辑见 `_syncOnce`
  /// 的 `appliedThrough`。
  Future<({int applied, bool ok})> _applyBatch(String jsonl, SyncReport report) async {
    var count = 0;
    var ok = true;
    for (final line in const LineSplitter().convert(jsonl)) {
      if (line.trim().isEmpty) continue;
      try {
        final rec = jsonDecode(line) as Map<String, dynamic>;
        await _applyRecord(rec, report);
        count++;
      } catch (e) {
        report.errors.add('记录解析失败: $e');
        ok = false;
      }
    }
    return (applied: count, ok: ok);
  }

  Future<void> _applyRecord(Map<String, dynamic> rec, SyncReport report) async {
    final type = rec['t'] as String?;
    final id = rec['id'] as String?;
    final hlcStr = rec['hlc'] as String?;
    final node = rec['node'] as String? ?? '';
    if (type == null || id == null || hlcStr == null) return;

    final remoteHlc = Hlc.parse(hlcStr);
    clock.observe(remoteHlc); // 推进本地时钟，保证后续 tick 一定更大

    switch (type) {
      case 'book':
        await _mergeInto(
          table: 'book',
          id: id,
          remote: (rec['d'] as Map?)?.cast<String, dynamic>(),
          remoteHlc: remoteHlc,
          node: node,
          report: report,
          read: () async {
            final r = await (db.select(db.books)..where((t) => t.id.equals(id))).getSingleOrNull();
            return r == null ? null : _bookToMap(r);
          },
          write: (m) => db.into(db.books).insertOnConflictUpdate(_bookCompanion(m)),
          base: () async => _baseOf('book', id),
          putBase: (m) => _putBase('book', id, m),
        );
      case 'progress':
        await _mergeInto(
          table: 'progress',
          id: id,
          remote: (rec['d'] as Map?)?.cast<String, dynamic>(),
          remoteHlc: remoteHlc,
          node: node,
          report: report,
          customMerge: mergeProgress,
          read: () async {
            final r = await (db.select(db.progresses)
              ..where((t) => t.bookId.equals(id)))
                .getSingleOrNull();
            return r == null ? null : _progressToMap(r);
          },
          write: (m) => db.into(db.progresses).insertOnConflictUpdate(_progressCompanion(m)),
          base: () async => _baseOf('progress', id),
          putBase: (m) => _putBase('progress', id, m),
        );
      case 'rule':
        await _mergeInto(
          table: 'rule',
          id: id,
          remote: (rec['d'] as Map?)?.cast<String, dynamic>(),
          remoteHlc: remoteHlc,
          node: node,
          report: report,
          read: () async {
            final r = await (db.select(db.rules)..where((t) => t.id.equals(id))).getSingleOrNull();
            return r == null ? null : _ruleToMap(r);
          },
          write: (m) => db.into(db.rules).insertOnConflictUpdate(_ruleCompanion(m)),
          base: () async => _baseOf('rule', id),
          putBase: (m) => _putBase('rule', id, m),
        );
      case 'collection':
        await _mergeInto(
          table: 'collection',
          id: id,
          remote: (rec['d'] as Map?)?.cast<String, dynamic>(),
          remoteHlc: remoteHlc,
          node: node,
          report: report,
          read: () async {
            final r = await (db.select(db.collections)
              ..where((t) => t.id.equals(id)))
                .getSingleOrNull();
            return r == null ? null : _collectionToMap(r);
          },
          write: (m) => db.into(db.collections).insertOnConflictUpdate(_collectionCompanion(m)),
          base: () async => _baseOf('collection', id),
          putBase: (m) => _putBase('collection', id, m),
        );
      case 'membership':
        await _mergeInto(
          table: 'membership',
          id: id,
          remote: (rec['d'] as Map?)?.cast<String, dynamic>(),
          remoteHlc: remoteHlc,
          node: node,
          report: report,
          customMerge: mergeMembership,
          read: () async {
            final r = await (db.select(db.memberships)
              ..where((t) => t.id.equals(id)))
              .getSingleOrNull();
            return r == null ? null : _membershipToMap(r);
          },
          write: (m) => db.into(db.memberships).insertOnConflictUpdate(_membershipCompanion(m)),
          base: () async => null,
          putBase: (m) async {},
        );
      case 'annotation':
        await _mergeInto(
          table: 'annotation',
          id: id,
          remote: (rec['d'] as Map?)?.cast<String, dynamic>(),
          remoteHlc: remoteHlc,
          node: node,
          report: report,
          read: () async {
            final r = await (db.select(db.annotations)
              ..where((t) => t.id.equals(id)))
              .getSingleOrNull();
            return r == null ? null : _annotationToMap(r);
          },
          write: (m) => db.into(db.annotations).insertOnConflictUpdate(_annotationCompanion(m)),
          base: () async => _baseOf('annotation', id),
          putBase: (m) => _putBase('annotation', id, m),
        );
    }
  }

  /// 通用"读本地 → 合并 → 写回"流水线
  Future<void> _mergeInto({
    required String table,
    required String id,
    required Map<String, dynamic>? remote,
    required Hlc remoteHlc,
    required String node,
    required SyncReport report,
    required Future<Map<String, dynamic>?> Function() read,
    required Future<void> Function(Map<String, dynamic>) write,
    required Future<Map<String, dynamic>?> Function() base,
    required Future<void> Function(Map<String, dynamic>) putBase,
    MergeResult Function(Map<String, dynamic>, Map<String, dynamic>,
            {required Hlc localHlc, required Hlc remoteHlc})?
        customMerge,
  }) async {
    if (remote == null) return;
    final local = await read();
    final baseMap = await base();

    if (local == null) {
      // 本地没有 → 直接写入（墓碑也要写，防止离线端复活）
      final m = Map<String, dynamic>.of(remote);
      m['hlc'] = remoteHlc.encode();
      m['updatedBy'] = node;
      await write(m);
      await putBase(m);
      return;
    }

    final localHlc = Hlc.parse(local['hlc'] as String? ?? Hlc.zero.encode());
    if (remoteHlc.compareTo(localHlc) <= 0) return; // 比本地旧，丢弃

    final result = customMerge != null
        ? customMerge(local, remote, localHlc: localHlc, remoteHlc: remoteHlc)
        : mergeEntity(local, remote, base: baseMap, localHlc: localHlc, remoteHlc: remoteHlc);

    final merged = Map<String, dynamic>.of(result.merged);
    merged['hlc'] = remoteHlc.encode();
    merged['updatedBy'] = node;
    merged['updatedAt'] = DateTime.now().toUtc().toIso8601String();
    await write(merged);
    await putBase(merged);

    // 冲突留痕：不静默覆盖
    for (final c in result.conflicts) {
      await db.logConflict(
        entityType: table,
        entityId: id,
        field: c.field,
        localValue: c.local,
        remoteValue: c.remote,
        winner: c.winner.name,
      );
      report.conflicts++;
    }
  }

  // ══════════════════════ 推送本地变更 ══════════════════════

  Future<int> _pushChanges() async {
    final rows = await db.pendingOutbox();
    if (rows.isEmpty) return 0;

    // 分块推送：原先把所有待推记录拼成**一个** jsonl（无大小上限），离线久了可能
    // 几千条几十 MB —— 一次网络抖动就整批失败、整批重来。分块后每块独立推进，
    // 某块失败只重试它自己（前面已成功的块已从 outbox 清掉，不会重复推）。
    var pushed = 0;
    for (var i = 0; i < rows.length; i += _outboxChunkSize) {
      final chunk =
          rows.sublist(i, math.min(i + _outboxChunkSize, rows.length));
      final hlc = clock.tick(); // 每块一个新 HLC，保证文件名递增且唯一
      final buf = StringBuffer();
      for (final r in chunk) {
        buf.writeln(
          jsonEncode({
            't': r.entityType,
            'id': r.entityId,
            'op': r.op,
            'hlc': r.hlc,
            'node': deviceId,
            if (r.op == 'upsert' || r.op == 'delete') 'd': jsonDecode(r.payloadJson),
          }),
        );
      }
      final fileName = '$_changesPath/${hlc.encode()}.jsonl';
      await client.putAtomic(fileName, utf8.encode(buf.toString()));
      await db.clearOutboxUpTo(chunk.last.seq);
      pushed += chunk.length;
    }
    return pushed;
  }

  /// [appliedThrough] 是本端「已成功应用到」的水位线（由 `_syncOnce` 算出）。
  ///
  /// manifest 的 lastHlc **必须**用它，而不能取目录里最新文件的文件名：后者会把
  /// 应用失败的批次也算成已应用，于是它们再也不会被拉取 —— 静默丢数据。
  Future<Manifest> _buildManifest(Hlc appliedThrough) async {
    final entries = await client.propfind('$_changesPath/', depth: 1);
    final files = entries
        .where((e) => !e.isDir && e.name.endsWith('.jsonl'))
        .map((e) => ManifestFile(
              name: e.name,
              bytes: e.size ?? 0,
              node: _hlcOfFileName(e.name)?.node ?? '',
            ))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    // 只保留最近 200 个批次，更老的按需从目录列表重建，避免 manifest 无限膨胀
    final kept = files.length > 200 ? files.sublist(files.length - 200) : files;
    // 注意：不要再写成 `_hlcOfFileName(kept.last.name)` —— 那是「远端最新」，
    // 不是「本端已应用」。两者在批次失败时会分叉，用错就会丢变更。
    final lastHlc = appliedThrough.encode();

    return Manifest(schema: 1, lastHlc: lastHlc, files: kept);
  }

  Hlc? _hlcOfFileName(String name) {
    final base = name.endsWith('.jsonl') ? name.substring(0, name.length - 6) : name;
    try {
      return Hlc.parse(base);
    } catch (_) {
      return null;
    }
  }

  // ══════════════════════ 书籍文件传输 ══════════════════════

  Future<void> _transferBlobs(SyncReport report) async {
    final books = await (db.select(db.books)).get();
    for (final b in books) {
      if (b.sha256.isEmpty) continue;
      final remotePath = blobRemotePath(b.sha256);

      // 上传：本地有文件、远端没有 → 传
      final localPath = b.localPath ?? await blobs.pathFor(b.sha256);
      if (localPath != null && await File(localPath).exists()) {
        final remoteHas = await _remoteHasBlob(b.sha256);
        if (!remoteHas) {
          try {
            final file = File(localPath);
            final len = await file.length();
            await client.putAtomicStream(
              remotePath,
              file.openRead(),
              contentLength: len,
              onProgress: (sent, total) => _emit(
                SyncPhase.transferring,
                '上传《${b.title}》',
                total <= 0 ? null : sent / total,
              ),
            );
            report.uploadedBooks++;
          } catch (e) {
            report.errors.add('上传《${b.title}》失败: $e');
          }
        }
        continue;
      }

      // 下载：本地没文件、远端有 → 下（流式落盘 + 增量校验 sha256，避免整文件进内存）
      try {
        final exists = await _remoteHasBlob(b.sha256);
        if (!exists) continue;
        final tmp = File(p.join(Directory.systemTemp.path, '${b.sha256}.dl'));
        final sink = tmp.openWrite();
        try {
          await client
              .getBytesStream(
                remotePath,
                onProgress: (sent, total) => _emit(
                  SyncPhase.transferring,
                  '下载《${b.title}》',
                  total <= 0 ? null : sent / total,
                ),
              )
              .pipe(sink);
        } catch (e) {
          try {
            await sink.close();
          } catch (_) {}
          try {
            await tmp.delete();
          } catch (_) {}
          rethrow;
        }
        // sink 已由 pipe 关闭；流式回读校验 sha256（不整文件进内存）
        final actual = (await sha256.bind(tmp.openRead()).first).toString();
        if (actual != b.sha256) {
          await tmp.delete();
          report.errors.add('《${b.title}》校验失败，已丢弃');
          continue;
        }
        final dest = await blobs.importFile(tmp.path, b.sha256);
        await tmp.delete();
        await (db.update(db.books)..where((t) => t.id.equals(b.id)))
            .write(BooksCompanion(localPath: Value(dest)));
        report.downloadedBooks++;
      } catch (e) {
        report.errors.add('下载《${b.title}》失败: $e');
      }
    }
  }

  /// 精确探测单个 blob：`propfind` depth 0，只回该资源自身。
  /// 不要改回「列整个分片目录再在内存里比对」——那会拉回最多 256 条目录项。
  Future<bool> _remoteHasBlob(String sha) => client.exists(blobRemotePath(sha));

  // ─────────────────────────── 封面图片传输 ───────────────────────────
  //
  // 封面与书籍完全镜像：按 coverHash 内容寻址，远端 covers/<hash[:2]>/<hash>，
  // 本地 <cacheDir>/covers/<hash>.<ext>。元数据（coverHash）已在 book payload 里
  // 同步，这里只负责把字节本身跨端传过去，并回填本地 coverPath。

  Future<void> _transferCovers(SyncReport report) async {
    final books = await (db.select(db.books)).get();
    for (final b in books) {
      final hash = b.coverHash;
      if (hash == null || hash.isEmpty) continue;
      final remotePath = coverRemotePath(hash);

      // 上传：本地有封面、远端没有 → 传（内容寻址，同名即同内容，天然幂等）
      final localPath = b.coverPath ?? await covers.pathFor(hash);
      if (localPath != null && await File(localPath).exists()) {
        if (!await _remoteHasCover(hash)) {
          try {
            final file = File(localPath);
            final len = await file.length();
            await client.putAtomicStream(
              remotePath,
              file.openRead(),
              contentLength: len,
              onProgress: (sent, total) => _emit(
                SyncPhase.transferring,
                '上传《${b.title}》封面',
                total <= 0 ? null : sent / total,
              ),
            );
            report.uploadedCovers++;
          } catch (e) {
            report.errors.add('上传《${b.title}》封面失败: $e');
          }
        }
        continue;
      }

      // 下载：本地没封面、远端有 → 下（流式落盘 + 增量校验 coverHash）
      try {
        if (!await _remoteHasCover(hash)) continue;
        final tmp = File(p.join(Directory.systemTemp.path, '$hash.dl'));
        final sink = tmp.openWrite();
        try {
          await client
              .getBytesStream(
                remotePath,
                onProgress: (sent, total) => _emit(
                  SyncPhase.transferring,
                  '下载《${b.title}》封面',
                  total <= 0 ? null : sent / total,
                ),
              )
              .pipe(sink);
        } catch (e) {
          try {
            await sink.close();
          } catch (_) {}
          try {
            await tmp.delete();
          } catch (_) {}
          rethrow;
        }
        // sink 已由 pipe 关闭；流式回读校验 coverHash（不整文件进内存）
        final actual = (await sha256.bind(tmp.openRead()).first).toString();
        if (actual != hash) {
          await tmp.delete();
          report.errors.add('《${b.title}》封面校验失败，已丢弃');
          continue;
        }
        final ext = await _coverExtForFile(tmp.path);
        final dest = await covers.importFile(tmp.path, hash, ext);
        await tmp.delete();
        // 回填本地封面路径，书架才能正常显示
        await (db.update(db.books)..where((t) => t.id.equals(b.id)))
            .write(BooksCompanion(coverPath: Value(dest)));
        report.downloadedCovers++;
      } catch (e) {
        report.errors.add('下载《${b.title}》封面失败: $e');
      }
    }
  }

  Future<bool> _remoteHasCover(String hash) => client.exists(coverRemotePath(hash));

  /// 把无头 CLI `pull` 已落到本地 blob/cover 仓库、但 drift 主库里
  /// `localPath`/`coverPath` 仍为空的行补回来（见 docs/02 §5.2.2、docs/09）。
  ///
  /// 无头备份线（docs/09）的 `pull` 直接写 `<appDocDir>/blobs/...` 与
  /// `<appDocDir>/cache/covers/...`——路径刻意与 [DefaultBlobStore]/[DefaultCoverStore]
  /// 对齐（Rust 侧 `FsBlobStore`/`FsCoverStore` 也按此布局落盘）。但 App 主库的
  /// `localPath`/`coverPath` 是后来才回填的可空缓存列，无头 `pull` 不经过
  /// `_transferBlobs`/`_transferCovers` 的回填分支，所以需要这里逐行用
  /// `blobs.pathFor(sha256)` / `covers.pathFor(coverHash)` 兜底查找，命中且本地
  /// 文件存在就回写，让书架 UI 直接显示"已下载"。
  ///
  /// 同时也在 `_syncOnce` 的 5c 步被调用：日常同步里，若某本书的文件已在本地
  /// 仓库但库里缓存列恰好为空（例如换端恢复、手动导入），也能在此补齐，无副作用。
  Future<void> reconcileLocalRepo() async {
    final books = await (db.select(db.books)).get();
    for (final b in books) {
      if (b.sha256.isNotEmpty && (b.localPath == null || b.localPath!.isEmpty)) {
        final p = await blobs.pathFor(b.sha256);
        if (p != null && await File(p).exists()) {
          await (db.update(db.books)..where((t) => t.id.equals(b.id)))
              .write(BooksCompanion(localPath: Value(p)));
        }
      }
      final hash = b.coverHash;
      if (hash != null && hash.isNotEmpty &&
          (b.coverPath == null || b.coverPath!.isEmpty)) {
        final p = await covers.pathFor(hash);
        if (p != null && await File(p).exists()) {
          await (db.update(db.books)..where((t) => t.id.equals(b.id)))
              .write(BooksCompanion(coverPath: Value(p)));
        }
      }
    }
  }

  /// 从图片二进制魔数推断扩展名（与 providers.dart::_coverExt 覆盖的格式对齐）。
  /// 远端封面不带扩展名，B 端落地时按此决定文件名后缀，保证 UI 能按 coverPath 找到它。
  String _coverExtForBytes(List<int> b) {
    if (b.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return '.jpg';
    if (b.length >= 8 &&
        b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47 &&
        b[4] == 0x0D && b[5] == 0x0A && b[6] == 0x1A && b[7] == 0x0A) {
      return '.png';
    }
    if (b.length >= 6 && b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x47) return '.gif';
    if (b.length >= 12 &&
        b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
      return '.webp';
    }
    return '.jpg';
  }

  /// 流式下载落地后，从临时文件头部魔数推断封面扩展名（封面体积小，仅读首 12 字节）。
  Future<String> _coverExtForFile(String path) async {
    final head = await File(path).openRead(0, 12).first;
    return _coverExtForBytes(head);
  }

  // ══════════════════════ base 快照（三方合并用） ══════════════════════

  Future<Map<String, dynamic>?> _baseOf(String table, String id) async {
    final key = 'base.$table.$id';
    final v = await db.getState(key);
    if (v == null) return null;
    return (jsonDecode(v) as Map).cast<String, dynamic>();
  }

  Future<void> _putBase(String table, String id, Map<String, dynamic> m) =>
      db.setState('base.$table.$id', jsonEncode(m));
}

// ══════════════════════ 行 ⇄ Map 转换 ══════════════════════

Map<String, dynamic> _bookToMap(BookRow r) => {
      'id': r.id,
      'sha256': r.sha256,
      'format': r.format,
      'title': r.title,
      'subtitle': r.subtitle,
      'author': r.author,
      'publisher': r.publisher,
      'language': r.language,
      'series': r.series,
      'seriesIndex': r.seriesIndex,
      'description': r.description,
      'tagsJson': r.tagsJson,
      'coverPath': r.coverPath,
      'coverHash': r.coverHash,
      'coverSource': r.coverSource,
      'fileSize': r.fileSize,
      'totalChars': r.totalChars,
      'addedAt': r.addedAt.toIso8601String(),
      'updatedAt': r.updatedAt.toIso8601String(),
      'hlc': r.hlc,
      'updatedBy': r.updatedBy,
      'deleted': r.deleted,
    };

BooksCompanion _bookCompanion(Map<String, dynamic> m) => BooksCompanion.insert(
      id: m['id'] as String,
      sha256: m['sha256'] as String? ?? '',
      format: m['format'] as String? ?? 'unknown',
      title: m['title'] as String? ?? '未命名',
      subtitle: Value(m['subtitle'] as String?),
      author: Value(m['author'] as String?),
      publisher: Value(m['publisher'] as String?),
      language: Value(m['language'] as String?),
      series: Value(m['series'] as String?),
      seriesIndex: Value((m['seriesIndex'] as num?)?.toDouble()),
      description: Value(m['description'] as String?),
      tagsJson: Value(m['tagsJson'] as String? ?? '[]'),
      localPath: Value(m['localPath'] as String?),
      coverPath: Value(m['coverPath'] as String?),
      coverHash: Value(m['coverHash'] as String?),
      coverSource: Value((m['coverSource'] as num?)?.toInt() ?? 0),
      fileSize: Value((m['fileSize'] as num?)?.toInt() ?? 0),
      totalChars: Value((m['totalChars'] as num?)?.toInt() ?? 0),
      addedAt: m['addedAt'] == null
          ? DateTime.now()
          : DateTime.tryParse(m['addedAt'] as String) ?? DateTime.now(),
      updatedAt: DateTime.tryParse(m['updatedAt'] as String? ?? '') ?? DateTime.now(),
      hlc: m['hlc'] as String? ?? Hlc.zero.encode(),
      updatedBy: m['updatedBy'] as String? ?? '',
      deleted: Value(m['deleted'] == true),
    );

Map<String, dynamic> _progressToMap(ProgressRow r) => {
      'bookId': r.bookId,
      'locatorJson': r.locatorJson,
      'percent': r.percent,
      'charOffset': r.charOffset,
      'anchorBefore': r.anchorBefore,
      'anchorAfter': r.anchorAfter,
      'forced': r.forced,
      'updatedAt': r.updatedAt.toIso8601String(),
      'hlc': r.hlc,
      'updatedBy': r.updatedBy,
    };

ProgressesCompanion _progressCompanion(Map<String, dynamic> m) => ProgressesCompanion.insert(
      bookId: m['bookId'] as String,
      locatorJson: m['locatorJson'] as String? ?? '{}',
      percent: Value((m['percent'] as num?)?.toDouble() ?? 0),
      charOffset: Value((m['charOffset'] as num?)?.toInt() ?? 0),
      anchorBefore: Value(m['anchorBefore'] as String?),
      anchorAfter: Value(m['anchorAfter'] as String?),
      forced: Value(m['forced'] == true),
      updatedAt: DateTime.tryParse(m['updatedAt'] as String? ?? '') ?? DateTime.now(),
      hlc: m['hlc'] as String? ?? Hlc.zero.encode(),
      updatedBy: m['updatedBy'] as String? ?? '',
    );

Map<String, dynamic> _ruleToMap(RuleRow r) => {
      'id': r.id,
      'name': r.name,
      'kind': r.kind,
      'pattern': r.pattern,
      'caseSensitive': r.caseSensitive,
      'colorValue': r.colorValue,
      'bgColorValue': r.bgColorValue,
      'bgOpacity': r.bgOpacity,
      'bold': r.bold,
      'italic': r.italic,
      'underline': r.underline,
      'priority': r.priority,
      'scopeCsv': r.scopeCsv,
      'enabled': r.enabled,
      'sortOrder': r.sortOrder,
      'hlc': r.hlc,
      'updatedBy': r.updatedBy,
      'deleted': r.deleted,
    };

RulesCompanion _ruleCompanion(Map<String, dynamic> m) => RulesCompanion.insert(
      id: m['id'] as String,
      name: m['name'] as String? ?? '',
      kind: m['kind'] as String? ?? 'regex',
      pattern: m['pattern'] as String? ?? '',
      caseSensitive: Value(m['caseSensitive'] == true),
      colorValue: (m['colorValue'] as num?)?.toInt() ?? 0xFFD32F2F,
      bgColorValue: (m['bgColorValue'] as num?)?.toInt() ?? 0xFFFFF176,
      bgOpacity: Value((m['bgOpacity'] as num?)?.toDouble() ?? 0.35),
      bold: Value(m['bold'] == true),
      italic: Value(m['italic'] == true),
      underline: Value(m['underline'] == true),
      priority: Value((m['priority'] as num?)?.toInt() ?? 0),
      scopeCsv: Value(m['scopeCsv'] as String? ?? 'novel'),
      enabled: Value(m['enabled'] != false),
      sortOrder: Value((m['sortOrder'] as num?)?.toInt() ?? 0),
      hlc: m['hlc'] as String? ?? Hlc.zero.encode(),
      updatedBy: m['updatedBy'] as String? ?? '',
      deleted: Value(m['deleted'] == true),
    );

Map<String, dynamic> _collectionToMap(CollectionRow r) => {
      'id': r.id,
      'name': r.name,
      'sortOrder': r.sortOrder,
      'colorValue': r.colorValue,
      'emoji': r.emoji,
      'hlc': r.hlc,
      'updatedBy': r.updatedBy,
      'deleted': r.deleted,
    };

CollectionsCompanion _collectionCompanion(Map<String, dynamic> m) => CollectionsCompanion.insert(
      id: m['id'] as String,
      name: m['name'] as String? ?? '',
      sortOrder: Value((m['sortOrder'] as num?)?.toInt() ?? 0),
      colorValue: Value((m['colorValue'] as num?)?.toInt()),
      emoji: Value(m['emoji'] as String?),
      hlc: m['hlc'] as String? ?? Hlc.zero.encode(),
      updatedBy: m['updatedBy'] as String? ?? '',
      deleted: Value(m['deleted'] == true),
    );

Map<String, dynamic> _membershipToMap(MembershipRow r) => {
      'id': r.id,
      'bookId': r.bookId,
      'collectionId': r.collectionId,
      'sortOrder': r.sortOrder,
      'removed': r.removed,
      'hlc': r.hlc,
      'updatedBy': r.updatedBy,
    };

MembershipsCompanion _membershipCompanion(Map<String, dynamic> m) => MembershipsCompanion.insert(
      id: m['id'] as String,
      bookId: m['bookId'] as String,
      collectionId: m['collectionId'] as String,
      sortOrder: Value((m['sortOrder'] as num?)?.toInt() ?? 0),
      removed: Value(m['removed'] == true),
      hlc: m['hlc'] as String? ?? Hlc.zero.encode(),
      updatedBy: m['updatedBy'] as String? ?? '',
    );

Map<String, dynamic> _annotationToMap(AnnotationRow r) => {
      'id': r.id,
      'bookId': r.bookId,
      'chapter': r.chapter,
      'charOffset': r.charOffset,
      'quote': r.quote,
      'note': r.note,
      'createdAt': r.createdAt.toIso8601String(),
      'updatedAt': r.updatedAt.toIso8601String(),
      'hlc': r.hlc,
      'updatedBy': r.updatedBy,
      'deleted': r.deleted,
    };

AnnotationsCompanion _annotationCompanion(Map<String, dynamic> m) => AnnotationsCompanion.insert(
      id: m['id'] as String,
      bookId: m['bookId'] as String? ?? '',
      chapter: Value((m['chapter'] as num?)?.toInt() ?? 0),
      charOffset: Value((m['charOffset'] as num?)?.toInt() ?? 0),
      quote: Value(m['quote'] as String?),
      note: m['note'] as String? ?? '',
      createdAt: DateTime.tryParse(m['createdAt'] as String? ?? '') ?? DateTime.now(),
      updatedAt: DateTime.tryParse(m['updatedAt'] as String? ?? '') ?? DateTime.now(),
      hlc: m['hlc'] as String? ?? Hlc.zero.encode(),
      updatedBy: m['updatedBy'] as String? ?? '',
      deleted: Value(m['deleted'] == true),
    );

extension _FirstOrNullEtag on List<DavEntry> {
  String? get firstOrNullEtag => isEmpty ? null : first.etag;
}
