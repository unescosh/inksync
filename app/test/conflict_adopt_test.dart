// PM#2「采用此值」单测：验证采纳冲突某侧时，被覆盖值能正确写回对应列
// （含类型还原：字符串 / 整型 / 布尔），并写入 outbox 推送其它端、标记留痕已处理。
//
// 跑法：app 目录下 `flutter test`（内存 SQLite，无需原生文件）。

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:inksync/core/hlc.dart';
import 'package:inksync/data/database.dart';

void main() {
  group('adoptConflict（PM#2 采用此值）', () {
    late AppDatabase db;

    setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
    tearDown(() => db.close());

    Future<int> _logConflict({
      required String entityType,
      required String entityId,
      required String field,
      required Object local,
      required Object remote,
      required String winner,
    }) =>
        db.into(db.conflictLog).insert(
              ConflictLogCompanion.insert(
                entityType: entityType,
                entityId: entityId,
                field: field,
                localValue: jsonEncode(local),
                remoteValue: jsonEncode(remote),
                winner: winner,
              ),
            );

    test('采纳本地字符串值：写回 title 并写入 outbox、标记已处理', () async {
      const bookId = 'b1';
      await db.into(db.books).insert(
            BooksCompanion.insert(
              id: bookId,
              sha256: 's1',
              format: 'txt',
              title: '原始标题',
              addedAt: DateTime.now().toUtc(),
              updatedAt: DateTime.now().toUtc(),
              hlc: Hlc.zero.encode(),
              updatedBy: 'dev0',
            ),
          );

      final cid = await _logConflict(
        entityType: 'book',
        entityId: bookId,
        field: 'title',
        local: '本地标题',
        remote: '远端标题',
        winner: 'remote',
      );

      await db.adoptConflict(
        id: cid,
        side: 'local',
        hlc: Hlc.zero.encode(),
        deviceId: 'dev1',
      );

      final book = (await db.select(db.books).get()).first;
      expect(book.title, '本地标题');

      final out = await db.select(db.outbox).get();
      expect(out.length, 1);
      expect(out.first.entityType, 'book');
      expect(out.first.entityId, bookId);
      final payload = jsonDecode(out.first.payloadJson) as Map<String, dynamic>;
      expect(payload['title'], '本地标题');

      final conflict = (await db.select(db.conflictLog).get()).first;
      expect(conflict.dismissed, isTrue);
    });

    test('采纳远端整型值：fileSize 类型还原正确', () async {
      const bookId = 'b2';
      await db.into(db.books).insert(
            BooksCompanion.insert(
              id: bookId,
              sha256: 's2',
              format: 'epub',
              title: 't',
              addedAt: DateTime.now().toUtc(),
              updatedAt: DateTime.now().toUtc(),
              hlc: Hlc.zero.encode(),
              updatedBy: 'dev0',
            ),
          );

      final cid = await _logConflict(
        entityType: 'book',
        entityId: bookId,
        field: 'fileSize',
        local: 100,
        remote: 200,
        winner: 'local',
      );

      await db.adoptConflict(
        id: cid,
        side: 'remote',
        hlc: Hlc.zero.encode(),
        deviceId: 'dev1',
      );

      final book = (await db.select(db.books).get()).first;
      expect(book.fileSize, 200);
    });

    test('采纳远端布尔值：deleted 类型还原正确', () async {
      const bookId = 'b3';
      await db.into(db.books).insert(
            BooksCompanion.insert(
              id: bookId,
              sha256: 's3',
              format: 'txt',
              title: 't3',
              addedAt: DateTime.now().toUtc(),
              updatedAt: DateTime.now().toUtc(),
              hlc: Hlc.zero.encode(),
              updatedBy: 'dev0',
            ),
          );

      final cid = await _logConflict(
        entityType: 'book',
        entityId: bookId,
        field: 'deleted',
        local: false,
        remote: true,
        winner: 'local',
      );

      await db.adoptConflict(
        id: cid,
        side: 'remote',
        hlc: Hlc.zero.encode(),
        deviceId: 'dev1',
      );

      final book = (await db.select(db.books).get()).first;
      expect(book.deleted, isTrue);
    });
  });
}
