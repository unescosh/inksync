import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

// drift 的 Value / *Companion / OrderingTerm 在本文件直接使用。
// 这里不会和 material 的 Table/Column 撞名 —— 本文件不 import material。
import 'package:crypto/crypto.dart' show sha256;
import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/hlc.dart';
import '../core/native_core.dart';
import '../data/database.dart';
import '../reader/rules.dart';
import '../sync/sync_engine.dart';
import '../sync/webdav_client.dart';

/// 依赖注入与全局状态。

// ─────────────────────────── 基础设施 ───────────────────────────

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(() => db.close());
  return db;
});

final nativeCoreProvider = Provider<NativeCore>((ref) => UnimplementedNativeCore());

const _storage = FlutterSecureStorage();

/// 设备 ID：8 位十六进制，用于 HLC 打破平局、以及判断"哪个批次是我自己推的"。
final deviceIdProvider = FutureProvider<String>((ref) async {
  final db = ref.watch(databaseProvider);
  final existing = await db.getState(SyncStateKeys.deviceId);
  if (existing != null && existing.length == 8) return existing;
  final rnd = math.Random.secure();
  final id = List.generate(8, (_) => rnd.nextInt(16).toRadixString(16)).join();
  await db.setState(SyncStateKeys.deviceId, id);
  return id;
});

final hlcClockProvider = FutureProvider<HlcClock>((ref) async {
  final id = await ref.watch(deviceIdProvider.future);
  return HlcClock(id);
});

/// WebDAV 凭据存系统安全区：
/// Android → Keystore / Windows → DPAPI(Credential Manager) / UOS → libsecret
final webdavConfigProvider = FutureProvider<WebDavConfig?>((ref) async {
  final raw = await _storage.read(key: 'webdav');
  if (raw == null) return null;
  final j = jsonDecode(raw) as Map<String, dynamic>;
  return WebDavConfig(
    baseUrl: j['baseUrl'] as String,
    username: j['username'] as String? ?? '',
    password: j['password'] as String? ?? '',
    acceptInvalidCerts: j['acceptInvalidCerts'] == true,
    pinnedCertSha256: j['pinnedCertSha256'] as String?,
  );
});

final webdavClientProvider = FutureProvider<WebDavClient?>((ref) async {
  final cfg = await ref.watch(webdavConfigProvider.future);
  if (cfg == null) return null;
  return WebDavClient(cfg);
});

final blobStoreProvider = Provider<BlobStore>((ref) => DefaultBlobStore());

final syncEngineProvider = FutureProvider<SyncEngine?>((ref) async {
  final client = await ref.watch(webdavClientProvider.future);
  if (client == null) return null;
  final db = ref.watch(databaseProvider);
  final deviceId = await ref.watch(deviceIdProvider.future);
  final clock = await ref.watch(hlcClockProvider.future);
  return SyncEngine(
    db: db,
    client: client,
    deviceId: deviceId,
    clock: clock,
    blobs: ref.watch(blobStoreProvider),
    onProgress: (phase, detail, f) => ref.read(syncProgressProvider.notifier).state =
        SyncProgressState(phase, detail, f),
  );
});

Future<void> saveWebDavConfig(WebDavConfig cfg) => _storage.write(
      key: 'webdav',
      value: jsonEncode({
        'baseUrl': cfg.baseUrl,
        'username': cfg.username,
        'password': cfg.password,
        'acceptInvalidCerts': cfg.acceptInvalidCerts,
        'pinnedCertSha256': cfg.pinnedCertSha256,
      }),
    );

// ─────────────────────────── 同步触发 ───────────────────────────

class SyncProgressState {
  SyncProgressState(this.phase, this.detail, this.fraction);

  final SyncPhase phase;
  final String detail;
  final double? fraction;

  bool get isRunning => phase != SyncPhase.idle && phase != SyncPhase.error;
}

final syncProgressProvider = StateProvider<SyncProgressState>(
  (ref) => SyncProgressState(SyncPhase.idle, '', null),
);

/// 同步控制器。
///
/// "实时"策略（WebDAV 没有推送，只能这样逼近）：
///  · [markDirty]  本地任何变更立刻调用，**debounce 3 秒**后触发一次同步；
///  · [syncNow]    立即同步（下拉刷新 / 手动点按钮）；
///  · 周期轮询     阅读中 60s、空闲 5min，由 UI 层定时器调用 [syncNow]，
///                 命中 304 时只有 1 个约 200 字节的请求，成本极低。
class SyncController extends Notifier<AsyncValue<SyncReport?>> {
  DateTime? _lastRun;
  bool _running = false;
  Timer? _debounceTimer;

  @override
  AsyncValue<SyncReport?> build() {
    ref.onDispose(() => _debounceTimer?.cancel());
    return const AsyncValue.data(null);
  }

  static const _debounce = Duration(seconds: 3);
  static const _minInterval = Duration(seconds: 2);

  void markDirty() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounce, () => syncNow());
  }

  Future<void> syncNow() async {
    if (_running) return;
    final now = DateTime.now();
    if (_lastRun != null && now.difference(_lastRun!) < _minInterval) return;

    final engine = await ref.read(syncEngineProvider.future);
    if (engine == null) {
      state = const AsyncValue.data(null);
      return;
    }

    _running = true;
    state = const AsyncValue.loading();
    try {
      final report = await engine.sync();
      _lastRun = DateTime.now();
      state = AsyncValue.data(report);
      // 同步完立刻再检查一次：如果期间又有本地变更（用户一直在翻页），继续追
      if (report.pushedChanges == 0 && report.pulledChanges > 0) {
        // 远端拉到了新东西，无需再推
      } else {
        final pending = await ref.read(databaseProvider).pendingOutbox(
              await ref.read(databaseProvider).lastAppliedHlc,
            );
        if (pending.isNotEmpty) markDirty();
      }
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    } finally {
      _running = false;
    }
  }
}

final syncTriggerProvider =
    NotifierProvider<SyncController, AsyncValue<SyncReport?>>(SyncController.new);

// ─────────────────────────── 排序 / 分组（本地偏好） ───────────────────────────

class SortController extends Notifier<SortSpec> {
  @override
  SortSpec build() => const SortSpec(SortKey.lastReadAt, descending: true);

  void apply(SortSpec s) => state = s;

  /// 手动拖拽排序。
  ///
  /// 调用方传**移动后的完整可见书籍 id 顺序**，而不是 (from, to) 下标 —— 因为书架
  /// 还叠了关键词搜索与分组过滤，UI 里的下标和数据库里的行序根本不是一回事，
  /// 用下标去写库必然错位。
  ///
  /// 落地位置分两种：
  ///  · 选中了分组 → `memberships.sort_order`（membership 是同步实体，写 outbox）；
  ///  · "全部"视图 → `books.custom_order`（**本地偏好，不同步、不写 outbox**）。
  Future<void> reorderBooks({
    required String? collectionId,
    required List<String> orderedBookIds,
  }) async {
    final db = ref.read(databaseProvider);

    if (collectionId == null) {
      await db.batch((b) {
        for (var i = 0; i < orderedBookIds.length; i++) {
          b.update(
            db.books,
            BooksCompanion(customOrder: Value(i)),
            where: (t) => t.id.equals(orderedBookIds[i]),
          );
        }
      });
      return;
    }

    final clock = await ref.read(hlcClockProvider.future);
    final deviceId = await ref.read(deviceIdProvider.future);

    for (var i = 0; i < orderedBookIds.length; i++) {
      final bookId = orderedBookIds[i];
      final id = '$bookId::$collectionId';
      final hlc = clock.tick();
      // upsert：即使 membership 行还不存在（刚拖进来的书）也能落地
      await db.into(db.memberships).insertOnConflictUpdate(
            MembershipsCompanion.insert(
              id: id,
              bookId: bookId,
              collectionId: collectionId,
              sortOrder: i,
              hlc: hlc.encode(),
              updatedBy: deviceId,
            ),
          );
      await db.into(db.outbox).insert(
            OutboxCompanion.insert(
              entityType: 'membership',
              entityId: id,
              op: 'upsert',
              payloadJson: jsonEncode({
                'id': id,
                'bookId': bookId,
                'collectionId': collectionId,
                'sortOrder': i,
                'removed': false,
                'hlc': hlc.encode(),
                'updatedBy': deviceId,
              }),
              hlc: hlc.encode(),
            ),
          );
    }
    ref.read(syncTriggerProvider.notifier).markDirty();
  }
}

final sortSpecProvider = NotifierProvider<SortController, SortSpec>(SortController.new);

class GroupController extends Notifier<GroupSpec> {
  @override
  GroupSpec build() => const GroupSpec(GroupKey.none);

  void apply(GroupSpec g) => state = g;

  void toggle(String label) {
    final next = Set<String>.from(state.collapsed);
    if (!next.remove(label)) next.add(label);
    state = GroupSpec(state.key, collapsed: next);
  }
}

final groupSpecProvider = NotifierProvider<GroupController, GroupSpec>(GroupController.new);

// ─────────────────────────── 数据查询 ───────────────────────────

class LibraryQuery {
  LibraryQuery({required this.sort, this.keyword, this.collectionId});

  final SortSpec sort;
  final String? keyword;
  final String? collectionId;

  @override
  bool operator ==(Object other) =>
      other is LibraryQuery &&
      other.sort.key == sort.key &&
      other.sort.descending == sort.descending &&
      other.keyword == keyword &&
      other.collectionId == collectionId;

  @override
  int get hashCode => Object.hash(sort.key, sort.descending, keyword, collectionId);
}

final libraryProvider =
    StreamProvider.family<List<BookWithProgress>, LibraryQuery>((ref, q) {
  final db = ref.watch(databaseProvider);
  return db.watchLibrary(
    sort: q.sort,
    keyword: (q.keyword?.isEmpty ?? true) ? null : q.keyword,
    collectionId: q.collectionId,
  );
});

final collectionsProvider = StreamProvider<List<CollectionRow>>((ref) {
  return ref.watch(databaseProvider).watchCollections();
});

/// 某本书所属的分组 id 集合，"加入分组"面板用来回显勾选。
final bookCollectionsProvider = StreamProvider.family<Set<String>, String>((ref, bookId) {
  return ref.watch(databaseProvider).watchBookCollectionIds(bookId);
});

// ─────────────────────────── 高亮规则 ───────────────────────────

final rawRulesProvider = StreamProvider<List<RuleRow>>((ref) {
  return ref.watch(databaseProvider).watchRules();
});

/// 编译后的规则集。hash 变化会让 SpanCache 自动失效。
final ruleSetProvider = Provider<RuleSet>((ref) {
  final rows = ref.watch(rawRulesProvider).valueOrNull ?? const [];
  const engine = RuleEngine();
  return engine.compile(rows.map(_rowToRule).toList());
});

HighlightRule _rowToRule(RuleRow r) => HighlightRule(
      id: r.id,
      name: r.name,
      kind: RuleKind.values.firstWhere(
        (k) => k.name == r.kind,
        orElse: () => RuleKind.regex,
      ),
      pattern: r.pattern,
      caseSensitive: r.caseSensitive,
      colorValue: r.colorValue,
      bgColorValue: r.bgColorValue,
      bgOpacity: r.bgOpacity,
      bold: r.bold,
      italic: r.italic,
      underline: r.underline,
      priority: r.priority,
      scope: r.scopeCsv
          .split(',')
          .map((s) => RuleScope.values.firstWhere(
                (v) => v.name == s.trim(),
                orElse: () => RuleScope.novel,
              ))
          .toSet(),
      enabled: r.enabled,
      sortOrder: r.sortOrder,
      hlc: r.hlc,
      updatedBy: r.updatedBy,
      deleted: r.deleted,
    );

/// 书籍缓存目录（封面、分页缓存等）
final appCacheDirProvider = FutureProvider<String>((ref) async {
  final d = await getApplicationDocumentsDirectory();
  final dir = p.join(d.path, 'cache');
  return dir;
});

// ─────────────────────────── 书架动作（导入 / 删除 / 分组） ───────────────────────────

/// 不引 uuid 包（少一个依赖），用 CSPRNG 直接拼 v4。
String newUuidV4() {
  final rnd = math.Random.secure();
  final b = List<int>.generate(16, (_) => rnd.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40; // version 4
  b[8] = (b[8] & 0x3f) | 0x80; // variant 10
  String hex(int from, int to) =>
      b.sublist(from, to).map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
}

class ImportResult {
  ImportResult({required this.bookId, required this.title, required this.duplicate});

  final String bookId;
  final String title;

  /// 同 sha256 的书已在书架上 —— 这次只是更新元数据 / 复活墓碑，不新增条目。
  final bool duplicate;
}

/// 书架的写操作集中在这里，UI 只调用、不直接拼 SQL。
///
/// 统一路径：**改库 → 写 outbox → markDirty()**（本地偏好类字段例外，见各方法注释）。
class LibraryActions {
  LibraryActions(this._ref);

  final Ref _ref;

  /// 导入一本书。
  ///
  /// 流程：probe（只抽元数据+封面，不解析正文）→ blob 入库（按 sha256 去重）
  /// → 封面字节落盘为 `cover_path` → 写 books 行 + outbox。
  ///
  /// **幂等**：同 sha256 已存在时复用原 bookId（顺带复活墓碑、刷新元数据），
  /// 不会出现两张一样的书卡。
  Future<ImportResult> importBook(String sourcePath) async {
    final db = _ref.read(databaseProvider);
    final core = _ref.read(nativeCoreProvider);
    final blobs = _ref.read(blobStoreProvider);
    final clock = await _ref.read(hlcClockProvider.future);
    final deviceId = await _ref.read(deviceIdProvider.future);

    final probe = await core.probeBook(sourcePath);
    final sha = probe.sha256.isNotEmpty ? probe.sha256 : await core.sha256File(sourcePath);

    final existing = await db.findBookBySha256(sha);
    final bookId = existing?.id ?? newUuidV4();

    // 原文件进 blob 仓库（内容寻址，多个条目可共享同一份文件）
    final localPath = await blobs.pathFor(sha) ?? await blobs.importFile(sourcePath, sha);

    // 封面：字节 → 缓存文件 → cover_path（M2 决策①）。
    // 不把字节存进 SQLite —— 漫画封面动辄几 MB，塞进库会让每次 watch 查询都变慢。
    String? coverPath = existing?.coverPath;
    String? coverHash = existing?.coverHash;
    final bytes = probe.coverBytes;
    if (bytes != null && bytes.isNotEmpty) {
      coverHash = sha256.convert(bytes).toString();
      final cacheDir = await _ref.read(appCacheDirProvider.future);
      final dir = Directory(p.join(cacheDir, 'covers'));
      if (!await dir.exists()) await dir.create(recursive: true);
      final ext = _coverExt(probe.coverMime);
      final f = File(p.join(dir.path, '$coverHash$ext'));
      if (!await f.exists()) await f.writeAsBytes(bytes, flush: true);
      coverPath = f.path;
    }

    final title = probe.title.trim().isNotEmpty
        ? probe.title.trim()
        : p.basenameWithoutExtension(sourcePath);
    final author = probe.authors.where((a) => a.trim().isNotEmpty).join('、');
    final fileSize =
        probe.fileSize > 0 ? probe.fileSize : await File(sourcePath).length();
    final now = DateTime.now().toUtc();
    final hlc = clock.tick();

    final row = BooksCompanion.insert(
      id: bookId,
      sha256: sha,
      format: probe.format.name,
      title: title,
      subtitle: probe.subtitle,
      author: author.isEmpty ? null : author,
      publisher: probe.publisher,
      language: probe.language,
      series: probe.series,
      seriesIndex: probe.seriesIndex,
      description: probe.description,
      tagsJson: jsonEncode(probe.tags),
      localPath: localPath,
      coverPath: coverPath,
      coverHash: coverHash,
      coverSource: 0,
      fileSize: fileSize,
      totalChars: probe.totalChars,
      addedAt: existing?.addedAt ?? now,
      updatedAt: now,
      hlc: hlc.encode(),
      updatedBy: deviceId,
      deleted: false, // 复活墓碑：用户重新导入就是要它回来
    );

    await db.upsertBookRow(
      row,
      hlc: hlc.encode(),
      payloadJson: jsonEncode({
        'id': bookId,
        'sha256': sha,
        'format': probe.format.name,
        'title': title,
        'subtitle': probe.subtitle,
        'author': author.isEmpty ? null : author,
        'publisher': probe.publisher,
        'language': probe.language,
        'series': probe.series,
        'seriesIndex': probe.seriesIndex,
        'description': probe.description,
        'tagsJson': jsonEncode(probe.tags),
        'coverHash': coverHash,
        'fileSize': fileSize,
        'totalChars': probe.totalChars,
        'addedAt': (existing?.addedAt ?? now).toIso8601String(),
        'updatedAt': now.toIso8601String(),
        'deleted': false,
        'hlc': hlc.encode(),
        'updatedBy': deviceId,
      }),
    );

    _ref.read(syncTriggerProvider.notifier).markDirty();
    return ImportResult(bookId: bookId, title: title, duplicate: existing != null);
  }

  /// 删除书籍：墓碑 + outbox。**不删 blob**（同 sha256 可能被别的条目共享，
  /// 且远端还要靠它做增量校验）。
  Future<void> deleteBook(String bookId) async {
    final db = _ref.read(databaseProvider);
    final clock = await _ref.read(hlcClockProvider.future);
    final deviceId = await _ref.read(deviceIdProvider.future);
    await db.tombstoneBook(
      bookId: bookId,
      hlc: clock.tick().encode(),
      deviceId: deviceId,
    );
    _ref.read(syncTriggerProvider.notifier).markDirty();
  }

  Future<String> createCollection(String name) async {
    final db = _ref.read(databaseProvider);
    final clock = await _ref.read(hlcClockProvider.future);
    final deviceId = await _ref.read(deviceIdProvider.future);
    final id = newUuidV4();
    final hlc = clock.tick();
    final maxOrder = (await db.watchCollections().first).length;

    await db.into(db.collections).insertOnConflictUpdate(
          CollectionsCompanion.insert(
            id: id,
            name: name,
            sortOrder: maxOrder,
            hlc: hlc.encode(),
            updatedBy: deviceId,
          ),
        );
    await db.into(db.outbox).insert(OutboxCompanion.insert(
          entityType: 'collection',
          entityId: id,
          op: 'upsert',
          payloadJson: jsonEncode({
            'id': id,
            'name': name,
            'sortOrder': maxOrder,
            'deleted': false,
            'hlc': hlc.encode(),
            'updatedBy': deviceId,
          }),
          hlc: hlc.encode(),
        ));
    _ref.read(syncTriggerProvider.notifier).markDirty();
    return id;
  }

  /// 分组顺序调整。collection 是同步实体，所以写 outbox。
  Future<void> reorderCollections(List<String> orderedIds) async {
    final db = _ref.read(databaseProvider);
    final clock = await _ref.read(hlcClockProvider.future);
    final deviceId = await _ref.read(deviceIdProvider.future);

    for (var i = 0; i < orderedIds.length; i++) {
      final id = orderedIds[i];
      final hlc = clock.tick();
      await (db.update(db.collections)..where((t) => t.id.equals(id))).write(
        CollectionsCompanion(
          sortOrder: Value(i),
          hlc: Value(hlc.encode()),
          updatedBy: Value(deviceId),
        ),
      );
      await db.into(db.outbox).insert(OutboxCompanion.insert(
            entityType: 'collection',
            entityId: id,
            op: 'upsert',
            payloadJson: jsonEncode({
              'id': id,
              'sortOrder': i,
              'hlc': hlc.encode(),
              'updatedBy': deviceId,
            }),
            hlc: hlc.encode(),
          ));
    }
    _ref.read(syncTriggerProvider.notifier).markDirty();
  }

  /// 删除分组（墓碑 + 级联移除成员关系），并触发同步。
  Future<void> deleteCollection(String id) async {
    final db = _ref.read(databaseProvider);
    final clock = await _ref.read(hlcClockProvider.future);
    final deviceId = await _ref.read(deviceIdProvider.future);
    final hlc = clock.tick();
    await db.deleteCollection(collectionId: id, hlc: hlc.encode(), deviceId: deviceId);
    _ref.read(syncTriggerProvider.notifier).markDirty();
  }

  /// 把书加入 / 移出分组。移出用 `removed=true` 软删，同样是防"复活"。
  Future<void> setMembership({
    required String bookId,
    required String collectionId,
    required bool member,
  }) async {
    final db = _ref.read(databaseProvider);
    final clock = await _ref.read(hlcClockProvider.future);
    final deviceId = await _ref.read(deviceIdProvider.future);
    final id = '$bookId::$collectionId';
    final hlc = clock.tick();

    await db.into(db.memberships).insertOnConflictUpdate(
          MembershipsCompanion.insert(
            id: id,
            bookId: bookId,
            collectionId: collectionId,
            removed: !member,
            hlc: hlc.encode(),
            updatedBy: deviceId,
          ),
        );
    await db.into(db.outbox).insert(OutboxCompanion.insert(
          entityType: 'membership',
          entityId: id,
          op: 'upsert',
          payloadJson: jsonEncode({
            'id': id,
            'bookId': bookId,
            'collectionId': collectionId,
            'removed': !member,
            'hlc': hlc.encode(),
            'updatedBy': deviceId,
          }),
          hlc: hlc.encode(),
        ));
    _ref.read(syncTriggerProvider.notifier).markDirty();
  }

  /// 首启播种内置高亮规则（T6）。
  ///
  /// 三个细节决定它不会打架：
  /// 1. 只在 `rules` 表**一行都没有**（含墓碑）且没播种过标记时执行；
  /// 2. 播种行的 hlc 用 [Hlc.zero]，任何远端改动/删除都能压过它 ——
  ///    否则新设备一开机就会把别的设备删掉的预设"复活"；
  /// 3. **不写 outbox**：播种是本地默认值，不该作为"变更"推给别人。
  Future<void> seedDefaultRulesIfEmpty() async {
    final db = _ref.read(databaseProvider);
    if (await db.getState(_rulesSeededKey) == '1') return;

    final existing = await db.select(db.rules).get(); // 含墓碑
    if (existing.isEmpty) {
      final deviceId = await _ref.read(deviceIdProvider.future);
      final zero = Hlc.zero.encode();
      for (final r in RulePresets.all) {
        await db.into(db.rules).insertOnConflictUpdate(RulesCompanion.insert(
              id: r.id,
              name: r.name,
              kind: r.kind.name,
              pattern: r.pattern,
              caseSensitive: r.caseSensitive,
              colorValue: r.colorValue,
              bgColorValue: r.bgColorValue,
              bgOpacity: r.bgOpacity,
              bold: r.bold,
              italic: r.italic,
              underline: r.underline,
              priority: r.priority,
              scopeCsv: r.scope.map((s) => s.name).join(','),
              enabled: r.enabled,
              sortOrder: r.sortOrder,
              hlc: zero,
              updatedBy: deviceId,
            ));
      }
    }
    await db.setState(_rulesSeededKey, '1');
  }

  static const _rulesSeededKey = 'pref.rulesSeeded';

  static String _coverExt(String? mime) {
    switch ((mime ?? '').toLowerCase()) {
      case 'image/png':
        return '.png';
      case 'image/webp':
        return '.webp';
      case 'image/gif':
        return '.gif';
      default:
        return '.jpg';
    }
  }
}

final libraryActionsProvider = Provider<LibraryActions>((ref) => LibraryActions(ref));
