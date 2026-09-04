// 跨端同步集成测试：用内存版 mock WebDAV + 内存 SQLite，端到端验证
// 首同步、各实体 upsert/delete 往返、以及并发冲突留痕。
//
// 重点回归：docs/08 里修的 7 处（C1 首同步 404、H1 合并缺字段置空、
// H2 标签 schema、H3 进度缺 bookId、H4 规则删除、H5 规则 scope、L1 定时器）。
//
// 跑法：app 目录下 `flutter test`（CI 已配，且已装 sqlite3 原生库）。

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

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
    final dir = _norm(path);
    final prefix = dir.endsWith('/') ? dir : '$dir/';
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

// ───────────────────────────── 辅助 ─────────────────────────────

/// 不碰真实磁盘：测试里的书 sha256 都为空，SyncEngine._transferBlobs 会直接跳过。
class FakeBlobStore extends BlobStore {
  const FakeBlobStore();
  @override
  Future<String?> pathFor(String sha256) async => null;
  @override
  Future<String> importFile(String sourcePath, String sha256) async => sourcePath;
}

SyncEngine makeEngine(AppDatabase db, WebDavClient client, String deviceId) => SyncEngine(
      db: db,
      client: client,
      deviceId: deviceId,
      clock: HlcClock(deviceId),
      blobs: const FakeBlobStore(),
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
        sha256: const Value(''),
        format: 'epub',
        title: 'X',
        subtitle: const Value('原副标题'),
        addedAt: Value(DateTime.parse(_t)),
        updatedAt: Value(DateTime.parse(_t)),
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
      sha256: const Value(''),
      format: 'epub',
      title: '测试书',
      tagsJson: Value(jsonEncode(['t1', 't2'])),
      addedAt: Value(DateTime.parse(_t)),
      updatedAt: Value(DateTime.parse(_t)),
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
      locatorJson: const Value('{}'),
      percent: const Value(0.5),
      updatedAt: Value(DateTime.parse(_t)),
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
      sha256: const Value(''),
      format: 'epub',
      title: '待删书',
      addedAt: Value(DateTime.parse(_t)),
      updatedAt: Value(DateTime.parse(_t)),
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
      id: bookId, sha256: const Value(''), format: 'epub', title: '在分组里的书',
      addedAt: Value(DateTime.parse(_t)), updatedAt: Value(DateTime.parse(_t)),
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
        sha256: const Value(''),
        format: 'epub',
        title: 'base',
        addedAt: Value(DateTime.parse(_t)),
        updatedAt: Value(DateTime.parse(_t)),
        hlc: hBase.encode(),
        updatedBy: '00000000',
      ));
      await db.setState('base.book.$bookId', jsonEncode({'title': 'base', 'hlc': hBase.encode(), 'updatedBy': '00000000'}));
    }

    // A 改成 A版，B 改成 B版（都入 outbox）
    await a.into(a.books).insertOnConflictUpdate(BooksCompanion.insert(
      id: bookId,
      sha256: const Value(''),
      format: 'epub',
      title: 'A版',
      addedAt: Value(DateTime.parse(_t)),
      updatedAt: Value(DateTime.parse(_t)),
      hlc: hA.encode(),
      updatedBy: 'aaaaaaaa',
    ));
    await enqueueRaw(a, 'book', bookId, 'upsert',
        {'id': bookId, 'sha256': '', 'format': 'epub', 'title': 'A版', 'hlc': hA.encode(), 'updatedBy': 'aaaaaaaa'}, hA.encode());
    await b.into(b.books).insertOnConflictUpdate(BooksCompanion.insert(
      id: bookId,
      sha256: const Value(''),
      format: 'epub',
      title: 'B版',
      addedAt: Value(DateTime.parse(_t)),
      updatedAt: Value(DateTime.parse(_t)),
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
}
