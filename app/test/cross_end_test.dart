// 跨端同步集成测试：用内存版 mock WebDAV + 内存 SQLite，端到端验证
// 首同步、各实体 upsert/delete 往返、以及并发冲突留痕。
//
// 重点回归：docs/08 里修的 7 处（C1 首同步 404、H1 合并缺字段置空、
// H2 标签 schema、H3 进度缺 bookId、H4 规则删除、H5 规则 scope、L1 定时器）。
//
// 跑法：app 目录下 `flutter test`（CI 已配，且已装 sqlite3 原生库）。

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:inksync/core/hlc.dart';
import 'package:inksync/data/database.dart';
import 'package:inksync/sync/sync_engine.dart';
import 'package:inksync/sync/webdav_client.dart';

// ───────────────────────────── mock WebDAV ─────────────────────────────

class _MockFile {
  _MockFile(this.bytes, this.etag);
  final Uint8List bytes;
  String etag;
}

/// 远端文件系统（内容寻址 + ETag 乐观锁），全部在内存里。
class MockWebDavClient extends WebDavClient {
  MockWebDavClient()
      : super(const WebDavConfig(baseUrl: 'https://mock/', username: '', password: ''));

  final Map<String, _MockFile> _store = {};
  int _seq = 0;
  String _newEtag() => '"mock-${(++_seq).toRadixString(36)}"';

  String _norm(String path) {
    var p = path;
    if (config.baseUrl.isNotEmpty && p.startsWith(config.baseUrl)) {
      p = p.substring(config.baseUrl.length);
    }
    if (p.startsWith('/')) p = p.substring(1);
    return p;
  }

  @override
  Future<void> mkcolAll(String path) async => Future.value(); // 内存里无需建目录

  @override
  Future<DavGetResult?> getIfChanged(String path, String? etag) async {
    final f = _store[_norm(path)];
    if (f == null) return null; // 404 → null（C1 修复：首同步不再抛异常）
    if (etag != null && f.etag == etag) return null; // 304 未变
    return DavGetResult(bytes: f.bytes, etag: f.etag);
  }

  @override
  Future<List<DavEntry>> propfind(String path, {int depth = 1}) async {
    final key = _norm(path);
    // 精确探测（exists() → depth 0，或按完整路径查单个资源）：真实 WebDAV 会返回
    // 该项自身。不特判的话，下面的前缀逻辑会把 '.../ab/<sha>' 当成目录前缀而永远
    // 查不到，导致 exists() 恒为 false —— 下载分支就永远不会触发。
    final self = _store[key];
    if (self != null) {
      return [
        DavEntry(
          path: key,
          name: key.split('/').last,
          isDir: false,
          etag: self.etag,
          size: self.bytes.length,
        ),
      ];
    }
    final prefix = key.endsWith('/') ? key : '$key/';
    final out = <DavEntry>[];
    for (final e in _store.entries) {
      if (!e.key.startsWith(prefix)) continue;
      final rel = e.key.substring(prefix.length);
      if (rel.isEmpty) continue;
      final isDir = rel.contains('/');
      out.add(DavEntry(
        path: e.key,
        name: rel.split('/').last,
        isDir: isDir,
        etag: e.value.etag,
        size: e.value.bytes.length,
      ));
    }
    return out;
  }

  @override
  Future<Uint8List> getBytes(String path, {void Function(int, int)? onProgress}) async {
    final f = _store[_norm(path)];
    if (f == null) throw WebDavException(404, '资源不存在: $path');
    return f.bytes;
  }

  @override
  Future<void> putAtomic(String path, List<int> body,
      {void Function(int, int)? onProgress}) async {
    _store[_norm(path)] = _MockFile(Uint8List.fromList(body), _newEtag());
  }

  @override
  Future<bool> putIfMatch(String path, List<int> body, String? etag) async {
    final k = _norm(path);
    final f = _store[k];
    if (etag != null && f != null && f.etag != etag) return false; // 412 冲突
    _store[k] = _MockFile(Uint8List.fromList(body), _newEtag());
    return true;
  }
}

/// P0 回归用：可让「拉取 changes 批次」这一环抛错，模拟网络抖动。
/// 关键是**可治愈**——failChanges 置回 false 后，同一份远端内容仍能被重新拉取，
/// 以此验证失败的批次不会被水位线永久跳过（否则就是静默丢数据）。
class _FlakyWebDavClient extends MockWebDavClient {
  bool failChanges = false;

  @override
  Future<Uint8List> getBytes(String path, {void Function(int, int)? onProgress}) async {
    if (failChanges && path.contains('/changes/')) {
      throw WebDavException(503, '模拟网络抖动');
    }
    return super.getBytes(path, onProgress: onProgress);
  }
}

// ───────────────────────────── 辅助 ─────────────────────────────

/// 不碰真实磁盘：测试里的书 sha256 都为空，SyncEngine._transferBlobs 会直接跳过。
class FakeBlobStore extends BlobStore {
  FakeBlobStore();
  @override
  Future<String?> pathFor(String sha256) async => null;
  @override
  Future<String> importFile(String sourcePath, String sha256) async => sourcePath;
}

/// 预置若干 sha256→绝对路径的种子 blob 仓库，模拟"无头 CLI 已把书文件写进本地仓库"。
/// pathFor 命中即返回种子路径，便于断言 reconcileLocalRepo 把 localPath 补回来。
class _SeededBlobStore extends BlobStore {
  _SeededBlobStore([this.files = const {}]);
  final Map<String, String> files;
  @override
  Future<String?> pathFor(String sha256) async => files[sha256];
  @override
  Future<String> importFile(String sourcePath, String sha256) async => sourcePath;
}

/// 封面仓库的内存版：把文件拷到临时目录并记账 hash→路径，便于断言"封面已落地"。
class FakeCoverStore extends CoverStore {
  FakeCoverStore([String? dir])
      : _dir = dir ?? Directory.systemTemp.createTempSync('cov-fake-').path;
  final String _dir;
  final Map<String, String> files = {}; // coverHash → 本地路径

  @override
  Future<String?> pathFor(String coverHash) async => files[coverHash];

  @override
  Future<String> importFile(String sourcePath, String coverHash, String ext) async {
    final dest = p.join(_dir, '$coverHash$ext');
    await File(sourcePath).copy(dest);
    files[coverHash] = dest;
    return dest;
  }
}

SyncEngine makeEngine(AppDatabase db, WebDavClient client, String deviceId,
        [BlobStore? blobs, CoverStore? covers]) =>
    SyncEngine(
      db: db,
      client: client,
      deviceId: deviceId,
      clock: HlcClock(deviceId),
      blobs: blobs ?? FakeBlobStore(),
      covers: covers ?? FakeCoverStore(),
      remoteRoot: 'inksync',
    );

Future<void> enqueueRaw(AppDatabase db, String entityType, String entityId, String op,
    Map<String, dynamic> map, String hlc) async {
  await db.into(db.outbox).insert(OutboxCompanion.insert(
        entityType: entityType,
        entityId: entityId,
        op: op,
        payloadJson: jsonEncode(map),
        hlc: hlc,
      ));
}

const _t = '2026-01-01T00:00:00Z';

// ───────────────────────────── 测试 ─────────────────────────────

void main() {
  test('C1: 首同步（远端无 manifest）成功且不报错', () async {
    final a = AppDatabase.forTesting(NativeDatabase.memory());
    final client = MockWebDavClient();
    final report = await makeEngine(a, client, 'aaaaaaaa').sync();
    expect(report.ok, isTrue, reason: '首同步不应失败');
    expect(report.errors, isEmpty);
    await a.close();
  });

  test('H1: 稀疏 upsert（只改部分字段）不会清空未改字段', () async {
    // 复现 docs/08 的 H1：outbox payload 只带 title、不带 subtitle 时，
    // 旧合并逻辑会把 subtitle 当成"对方置空"而清掉。修复后必须保留本地值。
    final a = AppDatabase.forTesting(NativeDatabase.memory());
    final b = AppDatabase.forTesting(NativeDatabase.memory());
    final client = MockWebDavClient();
    final h = Hlc(wallMs: 1000, counter: 0, node: 'aaaaaaaa');
    const bookId = 'h1-book';

    for (final db in [a, b]) {
      await db.into(db.books).insert(BooksCompanion.insert(
        id: bookId,
        sha256: '',
        format: 'epub',
        title: 'X',
        subtitle: const Value('原副标题'),
        addedAt: DateTime.parse(_t),
        updatedAt: DateTime.parse(_t),
        hlc: h.encode(),
        updatedBy: 'aaaaaaaa',
      ));
      await db.setState(
          'base.book.$bookId',
          jsonEncode({
            'id': bookId,
            'title': 'X',
            'subtitle': '原副标题',
            'hlc': h.encode(),
            'updatedBy': 'aaaaaaaa'
          }));
    }

    // A 只改 title，发稀疏 payload（不含 subtitle）—— H1 的触发条件
    final h2 = Hlc(wallMs: 2000, counter: 0, node: 'aaaaaaaa');
    await enqueueRaw(a, 'book', bookId, 'upsert',
        {'id': bookId, 'title': 'X2', 'hlc': h2.encode(), 'updatedBy': 'aaaaaaaa'}, h2.encode());

    await makeEngine(a, client, 'aaaaaaaa').sync();
    final repB = await makeEngine(b, client, 'bbbbbbbb').sync();
    expect(repB.ok, isTrue);

    final bBook = await (b.select(b.books)..where((t) => t.id.equals(bookId))).getSingle();
    expect(bBook.title, 'X2', reason: 'title 应更新为 X2');
    expect(bBook.subtitle, '原副标题',
        reason: 'H1: 稀疏 upsert 绝不能清空未改的 subtitle');

    await a.close();
    await b.close();
  });

  test('各实体 upsert 能跨端往返（book/collection/membership/progress/rule）', () async {
    final a = AppDatabase.forTesting(NativeDatabase.memory());
    final b = AppDatabase.forTesting(NativeDatabase.memory());
    final client = MockWebDavClient(); // 共享远端
    final h = Hlc(wallMs: 1000, counter: 0, node: 'aaaaaaaa');
    const bookId = 'book-1';
    const colId = 'col-1';
    final memId = '$bookId::$colId';
    const ruleId = 'rule-1';

    // —— A 端落地本地行 + 入 outbox（payload 用修复后的规范 schema）——
    await a.into(a.books).insert(BooksCompanion.insert(
      id: bookId,
      sha256: '',
      format: 'epub',
      title: '测试书',
      tagsJson: Value(jsonEncode(['t1', 't2'])),
      addedAt: DateTime.parse(_t),
      updatedAt: DateTime.parse(_t),
      hlc: h.encode(),
      updatedBy: 'aaaaaaaa',
    ));
    await enqueueRaw(a, 'book', bookId, 'upsert', {
      'id': bookId,
      'sha256': '',
      'format': 'epub',
      'title': '测试书',
      'tagsJson': jsonEncode(['t1', 't2']), // H2：必须用 tagsJson
      'hlc': h.encode(),
      'updatedBy': 'aaaaaaaa',
    }, h.encode());

    await a.into(a.collections).insert(CollectionsCompanion.insert(
      id: colId,
      name: '我的分组',
      hlc: h.encode(),
      updatedBy: 'aaaaaaaa',
    ));
    await enqueueRaw(a, 'collection', colId, 'upsert',
        {'id': colId, 'name': '我的分组', 'sortOrder': 0, 'deleted': false, 'hlc': h.encode(), 'updatedBy': 'aaaaaaaa'}, h.encode());

    await a.into(a.memberships).insert(MembershipsCompanion.insert(
      id: memId,
      bookId: bookId,
      collectionId: colId,
      hlc: h.encode(),
      updatedBy: 'aaaaaaaa',
    ));
    await enqueueRaw(a, 'membership', memId, 'upsert',
        {'id': memId, 'bookId': bookId, 'collectionId': colId, 'removed': false, 'hlc': h.encode(), 'updatedBy': 'aaaaaaaa'}, h.encode());

    await a.into(a.progresses).insert(ProgressesCompanion.insert(
      bookId: bookId,
      locatorJson: '{}',
      percent: const Value(0.5),
      updatedAt: DateTime.parse(_t),
      hlc: h.encode(),
      updatedBy: 'aaaaaaaa',
    ));
    await enqueueRaw(a, 'progress', bookId, 'upsert', {
      'bookId': bookId, // H3：必须带 bookId
      'locatorJson': '{}',
      'percent': 0.5,
      'charOffset': 0,
      'anchorBefore': null,
      'anchorAfter': '',
      'forced': false,
      'hlc': h.encode(),
      'updatedBy': 'aaaaaaaa',
    }, h.encode());

    await a.into(a.rules).insert(RulesCompanion.insert(
      id: ruleId,
      name: '高亮',
      kind: 'regex',
      pattern: 'foo',
      colorValue: 0xFFFF0000,
      bgColorValue: 0xFFFFFF00,
      scopeCsv: const Value('comic,novel'),
      hlc: h.encode(),
      updatedBy: 'aaaaaaaa',
    ));
    await enqueueRaw(a, 'rule', ruleId, 'upsert', {
      'id': ruleId,
      'name': '高亮',
      'kind': 'regex',
      'pattern': 'foo',
      'colorValue': 0xFFFF0000,
      'bgColorValue': 0xFFFFFF00,
      'bgOpacity': 0.35,
      'bold': false,
      'italic': false,
      'underline': false,
      'priority': 0,
      'scopeCsv': 'comic,novel', // H5：必须用 scopeCsv
      'enabled': true,
      'sortOrder': 0,
      'hlc': h.encode(),
      'updatedBy': 'aaaaaaaa',
      'deleted': false,
    }, h.encode());

    // —— A 推送，B 拉取 ——
    final repA = await makeEngine(a, client, 'aaaaaaaa').sync();
    expect(repA.ok, isTrue);
    final repB = await makeEngine(b, client, 'bbbbbbbb').sync();
    expect(repB.ok, isTrue);
    expect(repB.pulledChanges, greaterThan(0), reason: 'B 应拉到 A 的变更');

    // —— 断言 B 端每个实体都正确落地 ——
    final bBook = await (b.select(b.books)..where((t) => t.id.equals(bookId))).getSingle();
    expect(bBook.title, '测试书');
    expect(bBook.tagsJson, jsonEncode(['t1', 't2']), reason: 'H2: 标签应同步');

    final bCol = await (b.select(b.collections)..where((t) => t.id.equals(colId))).getSingle();
    expect(bCol.name, '我的分组'); // H1: 即便只发部分字段，name 也不应被清空

    final bMem = await (b.select(b.memberships)..where((t) => t.id.equals(memId))).getSingle();
    expect(bMem.removed, isFalse);

    final bProg = await (b.select(b.progresses)..where((t) => t.bookId.equals(bookId))).getSingle();
    expect(bProg.percent, 0.5, reason: 'H3: 进度应同步（bookId 不再缺失）');

    final bRule = await (b.select(b.rules)..where((t) => t.id.equals(ruleId))).getSingle();
    expect(bRule.scopeCsv, 'comic,novel', reason: 'H5: 作用域应同步');

    await a.close();
    await b.close();
  });

  test('删除能跨端同步（规则墓碑 + 书籍墓碑）', () async {
    final a = AppDatabase.forTesting(NativeDatabase.memory());
    final b = AppDatabase.forTesting(NativeDatabase.memory());
    final client = MockWebDavClient();
    final h = Hlc(wallMs: 1000, counter: 0, node: 'aaaaaaaa');
    const bookId = 'book-del';
    const ruleId = 'rule-del';

    // 先建好并同步过去
    await a.into(a.books).insert(BooksCompanion.insert(
      id: bookId,
      sha256: '',
      format: 'epub',
      title: '待删书',
      addedAt: DateTime.parse(_t),
      updatedAt: DateTime.parse(_t),
      hlc: h.encode(),
      updatedBy: 'aaaaaaaa',
    ));
    await enqueueRaw(a, 'book', bookId, 'upsert',
        {'id': bookId, 'sha256': '', 'format': 'epub', 'title': '待删书', 'hlc': h.encode(), 'updatedBy': 'aaaaaaaa'}, h.encode());
    await a.into(a.rules).insert(RulesCompanion.insert(
      id: ruleId,
      name: '待删规则',
      kind: 'regex',
      pattern: 'x',
      colorValue: 0xFF000000,
      bgColorValue: 0xFFFFFFFF,
      hlc: h.encode(),
      updatedBy: 'aaaaaaaa',
    ));
    await enqueueRaw(a, 'rule', ruleId, 'upsert',
        {'id': ruleId, 'name': '待删规则', 'kind': 'regex', 'pattern': 'x', 'colorValue': 0xFF000000, 'bgColorValue': 0xFFFFFFFF, 'scopeCsv': 'novel', 'hlc': h.encode(), 'updatedBy': 'aaaaaaaa', 'deleted': false}, h.encode());
    await makeEngine(a, client, 'aaaaaaaa').sync();
    await makeEngine(b, client, 'bbbbbbbb').sync();

    // —— A 删除（规则用 delete payload + deleted:true；书籍用墓碑）——
    final h2 = Hlc(wallMs: 2000, counter: 0, node: 'aaaaaaaa');
    await enqueueRaw(a, 'rule', ruleId, 'delete',
        {'id': ruleId, 'deleted': true, 'hlc': h2.encode(), 'updatedBy': 'aaaaaaaa'}, h2.encode()); // H4
    await a.tombstoneBook(bookId: bookId, hlc: h2.encode(), deviceId: 'aaaaaaaa');
    await makeEngine(a, client, 'aaaaaaaa').sync();
    final repB = await makeEngine(b, client, 'bbbbbbbb').sync();
    expect(repB.ok, isTrue);

    final bBook = await (b.select(b.books)..where((t) => t.id.equals(bookId))).getSingle();
    expect(bBook.deleted, isTrue, reason: '书籍墓碑应同步');
    final bRule = await (b.select(b.rules)..where((t) => t.id.equals(ruleId))).getSingleOrNull();
    expect(bRule?.deleted, isTrue, reason: 'H4: 规则删除 payload 带 deleted:true 才能被识别');

    await a.close();
    await b.close();
  });

  test('M1: 删除分组跨端同步（分组墓碑 + 成员关系级联移除）', () async {
    // 复现 docs/08 的 M1：分组删除此前没实现。现在 deleteCollection 应软删分组，
    // 并级联把分组内成员关系置 removed=true，两者都要跨端同步。
    final a = AppDatabase.forTesting(NativeDatabase.memory());
    final b = AppDatabase.forTesting(NativeDatabase.memory());
    final client = MockWebDavClient();
    final h = Hlc(wallMs: 1000, counter: 0, node: 'aaaaaaaa');
    const colId = 'col-del';
    const bookId = 'book-in-col';
    final memId = '$bookId::$colId';

    // 建分组 + 放一本书进去 + 同步到 B
    await a.into(a.collections).insert(CollectionsCompanion.insert(
      id: colId, name: '待删分组', hlc: h.encode(), updatedBy: 'aaaaaaaa'));
    await enqueueRaw(a, 'collection', colId, 'upsert',
        {'id': colId, 'name': '待删分组', 'sortOrder': 0, 'deleted': false, 'hlc': h.encode(), 'updatedBy': 'aaaaaaaa'}, h.encode());
    await a.into(a.books).insert(BooksCompanion.insert(
      id: bookId, sha256: '', format: 'epub', title: '在分组里的书',
      addedAt: DateTime.parse(_t), updatedAt: DateTime.parse(_t),
      hlc: h.encode(), updatedBy: 'aaaaaaaa'));
    await enqueueRaw(a, 'book', bookId, 'upsert',
        {'id': bookId, 'sha256': '', 'format': 'epub', 'title': '在分组里的书', 'hlc': h.encode(), 'updatedBy': 'aaaaaaaa'}, h.encode());
    await a.into(a.memberships).insert(MembershipsCompanion.insert(
      id: memId, bookId: bookId, collectionId: colId, hlc: h.encode(), updatedBy: 'aaaaaaaa'));
    await enqueueRaw(a, 'membership', memId, 'upsert',
        {'id': memId, 'bookId': bookId, 'collectionId': colId, 'removed': false, 'hlc': h.encode(), 'updatedBy': 'aaaaaaaa'}, h.encode());

    await makeEngine(a, client, 'aaaaaaaa').sync();
    await makeEngine(b, client, 'bbbbbbbb').sync();

    // A 删除分组（M1：墓碑 + 级联成员关系 removed）
    final h2 = Hlc(wallMs: 2000, counter: 0, node: 'aaaaaaaa');
    await a.deleteCollection(collectionId: colId, hlc: h2.encode(), deviceId: 'aaaaaaaa');
    final repA = await makeEngine(a, client, 'aaaaaaaa').sync();
    expect(repA.ok, isTrue);
    final repB = await makeEngine(b, client, 'bbbbbbbb').sync();
    expect(repB.ok, isTrue);

    final bCol = await (b.select(b.collections)..where((t) => t.id.equals(colId))).getSingleOrNull();
    expect(bCol?.deleted, isTrue, reason: 'M1: 分组墓碑应同步');
    final bMem = await (b.select(b.memberships)..where((t) => t.id.equals(memId))).getSingleOrNull();
    expect(bMem?.removed, isTrue, reason: 'M1: 分组删除应级联移除成员关系');

    await a.close();
    await b.close();
  });

  test('并发改同一字段 → 冲突留痕，终值由 HLC 决定', () async {
    final a = AppDatabase.forTesting(NativeDatabase.memory());
    final b = AppDatabase.forTesting(NativeDatabase.memory());
    final client = MockWebDavClient();
    const bookId = 'book-conf';
    final hBase = Hlc(wallMs: 1, counter: 0, node: '00000000');
    final hA = Hlc(wallMs: 1000, counter: 0, node: 'aaaaaaaa');
    final hB = Hlc(wallMs: 2000, counter: 0, node: 'bbbbbbbb'); // hB > hA

    // 两端从同一 base 出发，并写入 base 快照（让三方合并能识别分叉）
    for (final db in [a, b]) {
      await db.into(db.books).insert(BooksCompanion.insert(
        id: bookId,
        sha256: '',
        format: 'epub',
        title: 'base',
        addedAt: DateTime.parse(_t),
        updatedAt: DateTime.parse(_t),
        hlc: hBase.encode(),
        updatedBy: '00000000',
      ));
      await db.setState('base.book.$bookId', jsonEncode({'title': 'base', 'hlc': hBase.encode(), 'updatedBy': '00000000'}));
    }

    // A 改成 A版，B 改成 B版（都入 outbox）
    await a.into(a.books).insertOnConflictUpdate(BooksCompanion.insert(
      id: bookId,
      sha256: '',
      format: 'epub',
      title: 'A版',
      addedAt: DateTime.parse(_t),
      updatedAt: DateTime.parse(_t),
      hlc: hA.encode(),
      updatedBy: 'aaaaaaaa',
    ));
    await enqueueRaw(a, 'book', bookId, 'upsert',
        {'id': bookId, 'sha256': '', 'format': 'epub', 'title': 'A版', 'hlc': hA.encode(), 'updatedBy': 'aaaaaaaa'}, hA.encode());
    await b.into(b.books).insertOnConflictUpdate(BooksCompanion.insert(
      id: bookId,
      sha256: '',
      format: 'epub',
      title: 'B版',
      addedAt: DateTime.parse(_t),
      updatedAt: DateTime.parse(_t),
      hlc: hB.encode(),
      updatedBy: 'bbbbbbbb',
    ));
    await enqueueRaw(b, 'book', bookId, 'upsert',
        {'id': bookId, 'sha256': '', 'format': 'epub', 'title': 'B版', 'hlc': hB.encode(), 'updatedBy': 'bbbbbbbb'}, hB.encode());

    final repA1 = await makeEngine(a, client, 'aaaaaaaa').sync(); // A 推 A版
    final repB = await makeEngine(b, client, 'bbbbbbbb').sync(); // B 拉 A版(忽略，更旧) + 推 B版
    final repA2 = await makeEngine(a, client, 'aaaaaaaa').sync(); // A 拉 B版(冲突，B版胜)

    final aBook = await (a.select(a.books)..where((t) => t.id.equals(bookId))).getSingle();
    final bBook = await (b.select(b.books)..where((t) => t.id.equals(bookId))).getSingle();
    expect(aBook.title, 'B版', reason: '终值取 HLC 更新的 B版');
    expect(bBook.title, 'B版');
    expect(repA1.conflicts + repB.conflicts + repA2.conflicts, greaterThan(0), reason: '应记录冲突');
    final log = await (a.select(a.conflictLog)).get();
    expect(log, isNotEmpty, reason: '冲突应留痕到 conflictLog');

    await a.close();
    await b.close();
  });

  test('封面图片随书跨端传输（内容寻址 + sha256 校验 + 回填 coverPath）', () async {
    // 下载分支会调用 path_provider 的 getTemporaryDirectory()，需要先初始化 Flutter 绑定
    // （其它用例的书 sha256 为空、在触达 getTemporaryDirectory 前就跳过了传输，故无需绑定）。
    TestWidgetsFlutterBinding.ensureInitialized();

    // 复现封面同步缺口：A 有封面文件、B 只有 coverHash（元数据已同步，字节未传），
    // 验证一次同步后 B 能下载到封面、sha256 与 A 一致，且 book.coverPath 被回填。
    final a = AppDatabase.forTesting(NativeDatabase.memory());
    final b = AppDatabase.forTesting(NativeDatabase.memory());
    final client = MockWebDavClient();

    // 造一张封面（JPEG 头，让格式探测返回 .jpg）
    final coverBytes = Uint8List.fromList([
      0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46,
      ...List.generate(200, (i) => i & 0xFF),
    ]);
    final coverHash = sha256.convert(coverBytes).toString();

    final aCoverDir = await Directory.systemTemp.createTemp('cov-a-');
    final aCoverFile = File(p.join(aCoverDir.path, '$coverHash.jpg'));
    await aCoverFile.writeAsBytes(coverBytes, flush: true);
    final aStore = FakeCoverStore(aCoverDir.path)..files[coverHash] = aCoverFile.path;
    final bStore = FakeCoverStore(); // B 端初始无封面

    const bookId = 'book-cover';
    final h = Hlc(wallMs: 1000, counter: 0, node: 'aaaaaaaa');
    await a.into(a.books).insert(BooksCompanion.insert(
      id: bookId,
      sha256: '',
      format: 'epub',
      title: '有封面的书',
      coverHash: Value(coverHash),
      coverSource: const Value(0),
      addedAt: DateTime.parse(_t),
      updatedAt: DateTime.parse(_t),
      hlc: h.encode(),
      updatedBy: 'aaaaaaaa',
    ));
    await enqueueRaw(a, 'book', bookId, 'upsert', {
      'id': bookId,
      'sha256': '',
      'format': 'epub',
      'title': '有封面的书',
      'coverHash': coverHash, // 元数据（含 coverHash）随 book payload 同步
      'hlc': h.encode(),
      'updatedBy': 'aaaaaaaa',
    }, h.encode());

    // A 推（上传封面）→ B 拉（下载封面）
    final repA = await makeEngine(a, client, 'aaaaaaaa', FakeBlobStore(), aStore).sync();
    expect(repA.ok, isTrue, reason: 'A 端同步不应失败: ${repA.errors}');
    expect(repA.uploadedCovers, 1, reason: 'A 应上传 1 张封面');

    final repB = await makeEngine(b, client, 'bbbbbbbb', FakeBlobStore(), bStore).sync();
    expect(repB.ok, isTrue, reason: 'B 端同步不应失败: ${repB.errors}');
    expect(repB.downloadedCovers, 1, reason: 'B 应下载 1 张封面');

    // B 端：封面路径被回填，且仓库里能按 hash 取到
    final bBook = await (b.select(b.books)..where((t) => t.id.equals(bookId))).getSingle();
    expect(bBook.coverPath, isNotEmpty, reason: 'B 端 coverPath 应被回填');
    expect(bStore.files.containsKey(coverHash), isTrue,
        reason: 'B 端封面仓库应含该 hash');

    // 校验：B 落地封面的字节与 A 原图一致（sha256 一致）
    final landed = await File(bBook.coverPath!).readAsBytes();
    expect(sha256.convert(landed).toString(), coverHash,
        reason: 'B 端封面 sha256 应与原图一致');

    // 重复同步应幂等：远端已有封面，不再重复上传/下载
    final repA2 = await makeEngine(a, client, 'aaaaaaaa', FakeBlobStore(), aStore).sync();
    final repB2 = await makeEngine(b, client, 'bbbbbbbb', FakeBlobStore(), bStore).sync();
    expect(repA2.uploadedCovers, 0, reason: '幂等：A 不应重复上传');
    expect(repB2.downloadedCovers, 0, reason: '幂等：B 不应重复下载');

    await a.close();
    await b.close();
  });

  test('T8: 无头 pull 落地的 blobs/covers 经 reconcileLocalRepo 补齐 localPath/coverPath', () async {
    // 复现无头备份线（docs/09）的收尾缺口：CLI `pull` 直接把书文件与封面写进
    // <appDocDir>/blobs/... 与 <appDocDir>/cache/covers/...，但 App 主库的
    // localPath/coverPath 仍是空的缓存列。reconcileLocalRepo 应逐行用
    // pathFor 兜底查找并回写，让书架 UI 显示"已下载"。
    TestWidgetsFlutterBinding.ensureInitialized();

    final a = AppDatabase.forTesting(NativeDatabase.memory());
    final client = MockWebDavClient();

    // 造"书文件"与"封面文件"，模拟无头 CLI 已把它们写进本地仓库（文件真实存在）
    final bookBytes = Uint8List.fromList([
      0x50, 0x4B, 0x03, 0x04, ...List.generate(100, (i) => i & 0xFF),
    ]);
    final bookSha = sha256.convert(bookBytes).toString();
    final blobDir = await Directory.systemTemp.createTemp('blob-rec-');
    final bookFile = File(p.join(blobDir.path, bookSha));
    await bookFile.writeAsBytes(bookBytes, flush: true);

    final coverBytes = Uint8List.fromList([
      0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46,
      ...List.generate(200, (i) => i & 0xFF),
    ]);
    final coverHash = sha256.convert(coverBytes).toString();
    final coverDir = await Directory.systemTemp.createTemp('cov-rec-');
    final coverFile = File(p.join(coverDir.path, '$coverHash.jpg'));
    await coverFile.writeAsBytes(coverBytes, flush: true);

    // 无头备份写入的仓库：pathFor 能返回这些已落地的文件（与 DefaultBlobStore 对齐）
    final blobs = _SeededBlobStore({bookSha: bookFile.path});
    final covers = FakeCoverStore(coverDir.path)..files[coverHash] = coverFile.path;

    const bookId = 'book-headless';
    final h = Hlc(wallMs: 1000, counter: 0, node: 'aaaaaaaa');
    await a.into(a.books).insert(BooksCompanion.insert(
      id: bookId,
      sha256: bookSha, // 内容寻址键，非空
      format: 'epub',
      title: '无头备份拉回的书',
      coverHash: Value(coverHash),
      // 关键：localPath / coverPath 故意留空，模拟 App 主库尚未对齐
      addedAt: DateTime.parse(_t),
      updatedAt: DateTime.parse(_t),
      hlc: h.encode(),
      updatedBy: 'aaaaaaaa',
    ));

    // 直接调 reconcileLocalRepo（不经完整 sync，纯测对齐逻辑）
    final engine = makeEngine(a, client, 'aaaaaaaa', blobs, covers);
    await engine.reconcileLocalRepo();

    final row = await (a.select(a.books)..where((t) => t.id.equals(bookId))).getSingle();
    expect(row.localPath, bookFile.path, reason: 'T8: localPath 应被回写为书文件绝对路径');
    expect(File(row.localPath!).existsSync(), isTrue, reason: 'T8: 回写的书文件应真实存在');
    expect(row.coverPath, coverFile.path, reason: 'T8: coverPath 应被回写为封面绝对路径');
    expect(File(row.coverPath!).existsSync(), isTrue, reason: 'T8: 回写的封面文件应真实存在');

    // 重复调用幂等：不抛错、路径不变、不重复写入
    await engine.reconcileLocalRepo();
    final row2 = await (a.select(a.books)..where((t) => t.id.equals(bookId))).getSingle();
    expect(row2.localPath, row.localPath, reason: 'T8: 重复 reconcile 应幂等');
    expect(row2.coverPath, row.coverPath, reason: 'T8: 重复 reconcile 应幂等');

    // 顺带验证：完整 sync() 的 5c 步也会走到同一逻辑（不报错、路径保持）
    final rep = await engine.sync();
    expect(rep.ok, isTrue, reason: 'T8: 含 reconcile 的完整 sync 不应失败: ${rep.errors}');
    final row3 = await (a.select(a.books)..where((t) => t.id.equals(bookId))).getSingle();
    expect(row3.localPath, bookFile.path);
    expect(row3.coverPath, coverFile.path);

    await a.close();
  });

  test('批注能跨端同步（新增 + 墓碑删除）', () async {
    // 验证 annotation 作为同步实体：A 加批注（带原文引用 + 定位偏移）→ B 拉到；
    // A 删除（墓碑软删）→ B 同步到 deleted=true。与书籍/进度同一条 outbox 流水线。
    final a = AppDatabase.forTesting(NativeDatabase.memory());
    final b = AppDatabase.forTesting(NativeDatabase.memory());
    final client = MockWebDavClient();
    final h = Hlc(wallMs: 1000, counter: 0, node: 'aaaaaaaa');
    const bookId = 'book-anno';
    const annoId = 'anno-1';

    // —— A 端加批注（chapters=2 的偏移定位 + 80 字内的原文引用）——
    await a.into(a.annotations).insert(AnnotationsCompanion.insert(
      id: annoId,
      bookId: bookId,
      chapter: const Value(2),
      charOffset: const Value(1234),
      quote: const Value('此处伏笔'),
      note: '作者早有暗示',
      createdAt: DateTime.parse(_t),
      updatedAt: DateTime.parse(_t),
      hlc: h.encode(),
      updatedBy: 'aaaaaaaa',
    ));
    await enqueueRaw(a, 'annotation', annoId, 'upsert', {
      'id': annoId,
      'bookId': bookId,
      'chapter': 2,
      'charOffset': 1234,
      'quote': '此处伏笔',
      'note': '作者早有暗示',
      'createdAt': DateTime.parse(_t).toIso8601String(),
      'updatedAt': DateTime.parse(_t).toIso8601String(),
      'hlc': h.encode(),
      'updatedBy': 'aaaaaaaa',
      'deleted': false,
    }, h.encode());

    // —— A 推，B 拉 ——
    final repA = await makeEngine(a, client, 'aaaaaaaa').sync();
    expect(repA.ok, isTrue);
    final repB = await makeEngine(b, client, 'bbbbbbbb').sync();
    expect(repB.ok, isTrue);
    expect(repB.pulledChanges, greaterThan(0), reason: 'B 应拉到 A 的批注');

    final bAnno = await (b.select(b.annotations)
        ..where((t) => t.id.equals(annoId)))
        .getSingle();
    expect(bAnno.bookId, bookId);
    expect(bAnno.charOffset, 1234, reason: '定位偏移应同步');
    expect(bAnno.quote, '此处伏笔', reason: '原文引用应同步');
    expect(bAnno.note, '作者早有暗示', reason: '笔记正文应同步');
    expect(bAnno.deleted, isFalse);

    // —— A 删除（墓碑软删）→ B 同步删除标记 ——
    final h2 = Hlc(wallMs: 2000, counter: 0, node: 'aaaaaaaa');
    await a.tombstoneAnnotation(
        id: annoId, hlc: h2.encode(), deviceId: 'aaaaaaaa');
    await makeEngine(a, client, 'aaaaaaaa').sync();
    final repB2 = await makeEngine(b, client, 'bbbbbbbb').sync();
    expect(repB2.ok, isTrue);

    final bAnno2 = await (b.select(b.annotations)
        ..where((t) => t.id.equals(annoId)))
        .getSingle();
    expect(bAnno2.deleted, isTrue, reason: '批注墓碑应跨端同步');

    await a.close();
    await b.close();
  });

  test('T10: 分组重命名跨端同步且保留其它字段（稀疏 payload 不清字段）', () async {
    // 验证 LibraryActions.renameCollection 的稀疏 payload（只带 name）经三方合并后，
    // 对端本地的 sortOrder/emoji 等未改字段不被清掉（merge.dart mergeEntity 的行为）。
    final a = AppDatabase.forTesting(NativeDatabase.memory());
    final b = AppDatabase.forTesting(NativeDatabase.memory());
    final client = MockWebDavClient();
    final h = Hlc(wallMs: 1000, counter: 0, node: 'aaaaaaaa');
    const colId = 'col-rename';

    // 两端基线同一 id 的分组；B 端额外带 sortOrder=5 + emoji，用来验证不被清掉
    for (final db in [a, b]) {
      final isB = db == b;
      await db.into(db.collections).insert(CollectionsCompanion.insert(
        id: colId,
        name: '旧名字',
        sortOrder: Value(isB ? 5 : 0),
        emoji: Value(isB ? '📚' : null),
        hlc: h.encode(),
        updatedBy: 'aaaaaaaa',
      ));
      await db.setState(
          'base.collection.$colId',
          jsonEncode({
            'id': colId,
            'name': '旧名字',
            'sortOrder': isB ? 5 : 0,
            'emoji': isB ? '📚' : null,
            'hlc': h.encode(),
            'updatedBy': 'aaaaaaaa'
          }));
    }

    // A 重命名（只发 name 的稀疏 outbox，与 LibraryActions.renameCollection 同款）
    final h2 = Hlc(wallMs: 2000, counter: 0, node: 'aaaaaaaa');
    await (a.update(a.collections)..where((t) => t.id.equals(colId))).write(
      CollectionsCompanion(
        name: const Value('新名字'),
        hlc: Value(h2.encode()),
        updatedBy: const Value('aaaaaaaa'),
      ),
    );
    await enqueueRaw(a, 'collection', colId, 'upsert',
        {'id': colId, 'name': '新名字', 'hlc': h2.encode(), 'updatedBy': 'aaaaaaaa'}, h2.encode());

    await makeEngine(a, client, 'aaaaaaaa').sync();
    final repB = await makeEngine(b, client, 'bbbbbbbb').sync();
    expect(repB.ok, isTrue);

    final bCol = await (b.select(b.collections)
        ..where((t) => t.id.equals(colId)))
        .getSingle();
    expect(bCol.name, '新名字', reason: '分组名应跨端更新');
    expect(bCol.sortOrder, 5, reason: 'T10: 稀疏重命名不应清掉 B 端的 sortOrder');
    expect(bCol.emoji, '📚', reason: 'T10: 稀疏重命名不应清掉 B 端的 emoji');

    await a.close();
    await b.close();
  });

  test('T11: 同步中心数据层（冲突可查/dismiss 后隐藏/pending 计数）', () async {
    // 验证 SyncCenterScreen 依赖的查询：watchConflicts 只返回未处理项、
    // dismissConflict 把条目移出列表、watchPendingOutboxCount 反映 outbox 行数。
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    await db.logConflict(
      entityType: 'book',
      entityId: 'b1',
      field: 'title',
      localValue: 'A版',
      remoteValue: 'B版',
      winner: 'remote',
    );
    await db.logConflict(
      entityType: 'rule',
      entityId: 'r1',
      field: 'pattern',
      localValue: 'x',
      remoteValue: 'y',
      winner: 'local',
    );
    await db.into(db.outbox).insert(OutboxCompanion.insert(
      entityType: 'book',
      entityId: 'b1',
      op: 'upsert',
      payloadJson: '{}',
      hlc: '0001',
    ));
    await db.into(db.outbox).insert(OutboxCompanion.insert(
      entityType: 'progress',
      entityId: 'b1',
      op: 'upsert',
      payloadJson: '{}',
      hlc: '0002',
    ));

    final conflicts = await db.watchConflicts().first;
    expect(conflicts.length, 2, reason: '应查到 2 条未处理冲突');
    final pending = await db.watchPendingOutboxCount().first;
    expect(pending, 2, reason: '应有 2 条待推送');

    await db.dismissConflict(conflicts.first.id);
    final remaining = await db.watchConflicts().first;
    expect(remaining.length, 1, reason: 'dismiss 后只剩 1 条冲突');

    await db.close();
  });

  test('P0: 远端批次应用失败不推进水位线（失败批次下次重试，不丢数据）', () async {
    // 回归守卫：旧实现把 lastAppliedHlc 推进到「目录里最新批次」而非「本端已成功
    // 应用的批次」，于是失败的批次下次被 `h > lastApplied` 过滤掉 → 永久丢失。
    final a = AppDatabase.forTesting(NativeDatabase.memory());
    final b = AppDatabase.forTesting(NativeDatabase.memory());
    final client = _FlakyWebDavClient();

    // A 端造一本书并推上去
    const bookId = 'book-p0';
    final h = Hlc(wallMs: 2000, counter: 0, node: 'aaaaaaaa');
    await a.into(a.books).insert(BooksCompanion.insert(
          id: bookId,
          sha256: '',
          format: 'epub',
          title: 'P0 书',
          addedAt: DateTime.parse(_t),
          updatedAt: DateTime.parse(_t),
          hlc: h.encode(),
          updatedBy: 'aaaaaaaa',
        ));
    await enqueueRaw(a, 'book', bookId, 'upsert', {
      'id': bookId,
      'sha256': '',
      'format': 'epub',
      'title': 'P0 书',
      'hlc': h.encode(),
      'updatedBy': 'aaaaaaaa',
    }, h.encode());
    await makeEngine(a, client, 'aaaaaaaa', FakeBlobStore(), FakeCoverStore()).sync();

    // B 端第一次同步：拉批次时网络抖动 → 该批次应用失败
    client.failChanges = true;
    final rep1 =
        await makeEngine(b, client, 'bbbbbbbb', FakeBlobStore(), FakeCoverStore()).sync();
    expect(rep1.errors, isNotEmpty, reason: '拉取失败应记账');
    // 注意：这里不能用 `isNull` / `isNotNull` —— drift 与 matcher 都导出了这两个
    // 名字，在同一文件里会产生 ambiguous_import。
    final missing =
        await (b.select(b.books)..where((t) => t.id.equals(bookId))).getSingleOrNull();
    expect(missing == null, true, reason: '批次没应用成功，书不该出现');
    // 关键断言：水位线必须仍停在起点（未推进）。
    // 否则下次 h.compareTo(lastApplied) > 0 会把它过滤掉 → 永久丢数据。
    expect(
      (await b.lastAppliedHlc).encode(),
      Hlc.zero.encode(),
      reason: '失败的批次不能算作已应用',
    );

    // 恢复后再同步：同一批次应被重新拉取并成功应用
    client.failChanges = false;
    final rep2 =
        await makeEngine(b, client, 'bbbbbbbb', FakeBlobStore(), FakeCoverStore()).sync();
    expect(rep2.errors, isEmpty, reason: '恢复后应无错误');
    final got = await (b.select(b.books)..where((t) => t.id.equals(bookId))).getSingleOrNull();
    expect(got != null, true, reason: '失败的批次必须能重试成功，而不是永久丢失');
    expect(got!.title, 'P0 书');
  });
}
