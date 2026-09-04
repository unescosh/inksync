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
library;

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
  int conflicts = 0;
  final List<String> errors = [];
  Hlc? newLastHlc;

  bool get ok => errors.isEmpty;
  bool get isEmpty =>
      pulledChanges == 0 && pushedChanges == 0 && uploadedBooks == 0 && downloadedBooks == 0;

  @override
  String toString() => '拉取 $pulledChanges / 推送 $pushedChanges / '
      '上传 $uploadedBooks / 下载 $downloadedBooks / 冲突 $conflicts';
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
    this.remoteRoot = 'inksync',
    this.onProgress,
  });

  final AppDatabase db;
  final WebDavClient client;
  final String deviceId;
  final HlcClock clock;
  final BlobStore blobs;
  final String remoteRoot;
  final SyncProgress? onProgress;

  static const int _maxManifestRetries = 5;

  String get _changesPath => '$remoteRoot/changes';
  String get _manifestPath => '$remoteRoot/manifest.json';
  String get _blobsPath => '$remoteRoot/blobs';

  String blobRemotePath(String sha) => '$_blobsPath/${sha.substring(0, 2)}/$sha';

  void _emit(SyncPhase phase, String detail, [double? f]) => onProgress?.call(phase, detail, f);

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
    return report;
  }

  /// 返回 false 表示 manifest 写冲突，需要整轮重试
  Future<bool> _syncOnce(SyncReport report) async {
    // 0. 目录结构（幂等）
    _emit(SyncPhase.preparing, '检查远端目录');
    await client.mkcolAll('$remoteRoot/');
    await client.mkcolAll('$_changesPath/');
    await client.mkcolAll('$_blobsPath/');

    final lastApplied = await db.lastAppliedHlc;

    // 1. 拉 manifest（带 ETag，未变则 304）
    final cachedEtag = await db.getState(SyncStateKeys.manifestEtag);
    final got = await client.getIfChanged(_manifestPath, cachedEtag);
    Manifest remote;
    String? manifestEtag;
    if (got == null) {
      remote = Manifest(schema: 1, lastHlc: lastApplied.encode(), files: const []);
      manifestEtag = cachedEtag;
    } else {
      remote = Manifest.parse(utf8.decode(got.bytes));
      manifestEtag = got.etag;
    }

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
    _emit(SyncPhase.applying, '应用 ${pending.length} 个远端批次');
    for (var i = 0; i < pending.length; i++) {
      final name = pending[i];
      try {
        final bytes = await client.getBytes('$_changesPath/$name');
        final applied = await _applyBatch(utf8.decode(bytes), report);
        report.pulledChanges += applied;
      } catch (e) {
        // 单个批次失败不能拖垮整轮同步：记账后继续
        report.errors.add('批次 $name 应用失败: $e');
      }
      _emit(SyncPhase.applying, '应用远端变更', (i + 1) / (pending.isEmpty ? 1 : pending.length));
    }

    // 4. 推送本地变更（一个批次一个文件，文件名 = 当前 HLC）
    _emit(SyncPhase.pushing, '推送本地变更');
    final pushed = await _pushChanges(lastApplied);
    report.pushedChanges = pushed;

    // 5. 传输书籍文件（内容寻址，已存在即秒传跳过）
    _emit(SyncPhase.transferring, '同步书籍文件');
    await _transferBlobs(report);

    // 6. 写 manifest（乐观锁）
    _emit(SyncPhase.finalizing, '写入 manifest');
    final newManifest = await _buildManifest();
    final body = utf8.encode(jsonEncode(newManifest.toJson()));
    final ok = await client.putIfMatch(_manifestPath, body, manifestEtag);
    if (!ok) return false;

    // 7. 落本地状态
    final finalEtag = (await client.propfind(_manifestPath, depth: 0)).firstOrNullEtag;
    if (finalEtag != null) await db.setState(SyncStateKeys.manifestEtag, finalEtag);
    await db.setState(SyncStateKeys.lastAppliedHlc, newManifest.lastHlc);
    await db.setState(SyncStateKeys.lastPushedHlc, newManifest.lastHlc);
    await db.setState(SyncStateKeys.lastSyncAt, DateTime.now().toUtc().toIso8601String());
    report.newLastHlc = Hlc.parse(newManifest.lastHlc);

    _emit(SyncPhase.idle, '同步完成');
    return true;
  }

  // ══════════════════════ 应用远端变更 ══════════════════════

  Future<int> _applyBatch(String jsonl, SyncReport report) async {
    var count = 0;
    for (final line in const LineSplitter().convert(jsonl)) {
      if (line.trim().isEmpty) continue;
      try {
        final rec = jsonDecode(line) as Map<String, dynamic>;
        await _applyRecord(rec, report);
        count++;
      } catch (e) {
        report.errors.add('记录解析失败: $e');
      }
    }
    return count;
  }

  Future<void> _applyRecord(Map<String, dynamic> rec, SyncReport report) async {
    final type = rec['t'] as String?;
    final id = rec['id'] as String?;
    final op = rec['op'] as String?;
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
          op: op,
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
          op: op,
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
          op: op,
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
          op: op,
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
          op: op,
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
    }
  }

  /// 通用"读本地 → 合并 → 写回"流水线
  Future<void> _mergeInto({
    required String table,
    required String id,
    required Map<String, dynamic>? remote,
    required String? op,
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

  Future<int> _pushChanges(Hlc since) async {
    final rows = await db.pendingOutbox(since);
    if (rows.isEmpty) return 0;

    final hlc = clock.tick();
    final buf = StringBuffer();
    for (final r in rows) {
      buf.writeln(
        jsonEncode({
          't': r.entityType,
          'id': r.entityId,
          'op': r.op,
          'hlc': r.hlc,
          'node': deviceId,
          if (r.op == 'upsert') 'd': jsonDecode(r.payloadJson),
        }),
      );
    }
    final fileName = '$_changesPath/${hlc.encode()}.jsonl';
    await client.putAtomic(fileName, utf8.encode(buf.toString()));

    if (rows.isNotEmpty) {
      await db.clearOutboxUpTo(rows.last.seq);
    }
    return rows.length;
  }

  Future<Manifest> _buildManifest() async {
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
    final lastHlc = kept.isEmpty ? (await db.lastAppliedHlc).encode() : _hlcOfFileName(kept.last.name)!.encode();

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
            final bytes = await File(localPath).readAsBytes();
            await client.putAtomic(remotePath, bytes, onProgress: (sent, total) {
              _emit(SyncPhase.transferring, '上传《${b.title}》',
                  total == 0 ? null : sent / total);
            });
            report.uploadedBooks++;
          } catch (e) {
            report.errors.add('上传《${b.title}》失败: $e');
          }
        }
        continue;
      }

      // 下载：本地没文件、远端有 → 下（并校验 sha256）
      try {
        final exists = await _remoteHasBlob(b.sha256);
        if (!exists) continue;
        final bytes = await client.getBytes(remotePath);
        final actual = _sha256OfBytes(bytes);
        if (actual != b.sha256) {
          report.errors.add('《${b.title}》校验失败，已丢弃');
          continue;
        }
        final tmp = File(p.join((await getTemporaryDirectory()).path, b.sha256));
        await tmp.writeAsBytes(bytes, flush: true);
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

  Future<bool> _remoteHasBlob(String sha) async {
    final entries = await client.propfind('$_blobsPath/${sha.substring(0, 2)}/', depth: 1);
    return entries.any((e) => e.name == sha);
  }

  /// 书籍文件按 sha256 内容寻址。下载后必须校验，不符则丢弃重下。
  /// 与 Rust 核心 `sha256_file()` 结果一致（都是标准 SHA-256 十六进制）。
  String _sha256OfBytes(List<int> bytes) => sha256.convert(bytes).toString();

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
      hlc: Value(m['hlc'] as String? ?? Hlc.zero.encode()),
      updatedBy: Value(m['updatedBy'] as String? ?? ''),
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
      updatedAt: Value(DateTime.tryParse(m['updatedAt'] as String? ?? '') ?? DateTime.now()),
      hlc: Value(m['hlc'] as String? ?? Hlc.zero.encode()),
      updatedBy: Value(m['updatedBy'] as String? ?? ''),
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
      hlc: Value(m['hlc'] as String? ?? Hlc.zero.encode()),
      updatedBy: Value(m['updatedBy'] as String? ?? ''),
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
      hlc: Value(m['hlc'] as String? ?? Hlc.zero.encode()),
      updatedBy: Value(m['updatedBy'] as String? ?? ''),
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
      hlc: Value(m['hlc'] as String? ?? Hlc.zero.encode()),
      updatedBy: Value(m['updatedBy'] as String? ?? ''),
    );

extension _FirstOrNullEtag on List<DavEntry> {
  String? get firstOrNullEtag => isEmpty ? null : first.etag;
}
