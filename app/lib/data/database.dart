import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3_flutter_libs/sqlite3_flutter_libs.dart';

import '../core/hlc.dart';

// UI 层要用 `Value(...)` 之类的少数 drift 符号，但屏幕代码不能直接
// `import 'package:drift/drift.dart'` —— drift 的 `Column` / `Table` 会和
// material 的 `Column` / `Table` 撞名，一用就是 ambiguous import 报错。
// 所以在这里定向再导出，屏幕只 import 本文件。
export 'package:drift/drift.dart'
    show Value, OrderingTerm, OrderingMode, Expression, CustomExpression;

part 'database.g.dart';

// ─────────────────────────── 表定义 ───────────────────────────
//
// 约定：每张业务表都带 {hlc, updatedBy, deleted, baseJson} 四个同步字段。
//   hlc      混合逻辑时钟，冲突裁决的唯一依据
//   updatedBy 产生这条记录的设备 ID
//   deleted  墓碑标记（软删除，防止离线端"复活"已删数据）
//   baseJson 上次同步成功时的快照，用于字段级三方合并

@DataClassName('BookRow')
class Books extends Table {
  TextColumn get id => text()(); // uuid v4
  TextColumn get sha256 => text()(); // 内容寻址，blob 去重的键
  TextColumn get format => text()(); // epub|txt|mobi|azw3|pdf|cbz
  TextColumn get title => text()();
  TextColumn get subtitle => text().nullable()();
  TextColumn get author => text().nullable()();
  TextColumn get publisher => text().nullable()();
  TextColumn get language => text().nullable()();
  TextColumn get series => text().nullable()();
  RealColumn get seriesIndex => real().nullable()();
  TextColumn get description => text().nullable()();
  TextColumn get tagsJson => text().withDefault(const Constant('[]'))();
  TextColumn get localPath => text().nullable()(); // 本地 blob 路径
  TextColumn get coverPath => text().nullable()();
  TextColumn get coverHash => text().nullable()();
  IntColumn get coverSource => integer().withDefault(const Constant(0))(); // 0内嵌 1自定义 2生成
  IntColumn get fileSize => integer().withDefault(const Constant(0))();
  IntColumn get totalChars => integer().withDefault(const Constant(0))();
  DateTimeColumn get addedAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  /// 全局手动拖拽顺序（未选中任何分组时的顺序）。
  /// **本地偏好，不参与同步**（见 docs/02 §6）：三端屏幕差异大，
  /// 强制同步手动顺序只会两边都别扭。分组内顺序则存在
  /// `memberships.sortOrder`，那是 membership 实体的一部分，会同步。
  IntColumn get customOrder => integer().withDefault(const Constant(0))();

  // 同步字段
  TextColumn get hlc => text()();
  TextColumn get updatedBy => text()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  TextColumn get baseJson => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('ProgressRow')
class Progresses extends Table {
  TextColumn get bookId => text()();
  TextColumn get locatorJson => text()(); // 见 docs/01 的 Locator 结构
  RealColumn get percent => real().withDefault(const Constant(0))();
  IntColumn get charOffset => integer().withDefault(const Constant(0))();
  TextColumn get anchorBefore => text().nullable()(); // 模糊重定位指纹
  TextColumn get anchorAfter => text().nullable()();
  BoolColumn get forced => boolean().withDefault(const Constant(false))();
  DateTimeColumn get updatedAt => dateTime()();

  TextColumn get hlc => text()();
  TextColumn get updatedBy => text()();
  TextColumn get baseJson => text().nullable()();

  @override
  Set<Column> get primaryKey => {bookId};
}

@DataClassName('CollectionRow')
class Collections extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  IntColumn get colorValue => integer().nullable()();
  TextColumn get emoji => text().nullable()();

  TextColumn get hlc => text()();
  TextColumn get updatedBy => text()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  TextColumn get baseJson => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// 分组成员关系。id = `${bookId}::${collectionId}`，保证 upsert 幂等。
@DataClassName('MembershipRow')
class Memberships extends Table {
  TextColumn get id => text()();
  TextColumn get bookId => text()();
  TextColumn get collectionId => text()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  BoolColumn get removed => boolean().withDefault(const Constant(false))();

  TextColumn get hlc => text()();
  TextColumn get updatedBy => text()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('RuleRow')
class Rules extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get kind => text()(); // regex|quote|bookTitleMark|personName|dialogue|keywordList
  TextColumn get pattern => text()();
  BoolColumn get caseSensitive => boolean().withDefault(const Constant(false))();
  IntColumn get colorValue => integer()();
  IntColumn get bgColorValue => integer()();
  RealColumn get bgOpacity => real().withDefault(const Constant(0.35))();
  BoolColumn get bold => boolean().withDefault(const Constant(false))();
  BoolColumn get italic => boolean().withDefault(const Constant(false))();
  BoolColumn get underline => boolean().withDefault(const Constant(false))();
  IntColumn get priority => integer().withDefault(const Constant(0))();
  TextColumn get scopeCsv => text().withDefault(const Constant('novel'))();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  TextColumn get hlc => text()();
  TextColumn get updatedBy => text()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

/// 待推送队列 —— 同步的**唯一事实来源**。所有业务写操作都顺带写一条。
@DataClassName('OutboxRow')
class Outbox extends Table {
  IntColumn get seq => integer().autoIncrement()();
  TextColumn get entityType => text()(); // book|progress|rule|collection|membership
  TextColumn get entityId => text()();
  TextColumn get op => text()(); // upsert|delete
  TextColumn get payloadJson => text()();
  TextColumn get hlc => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
}

/// 键值形态的同步状态：lastAppliedHlc / manifestEtag / deviceId ...
class SyncStates extends Table {
  TextColumn get key => text()();
  TextColumn get value => text().nullable()();

  @override
  Set<Column> get primaryKey => {key};
}

/// 冲突留痕。**绝不静默覆盖**：被裁决掉的值都进这里，用户可在同步中心找回。
@DataClassName('ConflictRow')
class ConflictLog extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get entityType => text()();
  TextColumn get entityId => text()();
  TextColumn get field => text()();
  TextColumn get localValue => text()();
  TextColumn get remoteValue => text()();
  TextColumn get winner => text()(); // local|remote
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  BoolColumn get dismissed => boolean().withDefault(const Constant(false))();
}

/// 阅读批注（读书笔记）。
///
/// 与书籍/进度一样走同步：本地新增/删除都写 outbox，`SyncEngine` 用同样的三方合并
/// 流水线把批注跨端同步（批注是个人财产，但三端都想看到自己写的笔记，故同步而非本地偏好）。
///
/// 定位：文本书用 `(chapter, charOffset)` 全书字符偏移；图片书（漫画/PDF）`chapter` 无意义，
/// `charOffset` 直接存 page index。阅读器点笔记可跳回原处。
@DataClassName('AnnotationRow')
class Annotations extends Table {
  TextColumn get id => text()();
  TextColumn get bookId => text()();
  IntColumn get chapter => integer().withDefault(const Constant(0))();
  IntColumn get charOffset => integer().withDefault(const Constant(0))();
  TextColumn get quote => text().nullable()(); // 被批注的原文片段（展示用，可空）
  TextColumn get note => text()(); // 用户笔记正文
  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  // 同步字段
  TextColumn get hlc => text()();
  TextColumn get updatedBy => text()();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();
  TextColumn get baseJson => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(
  tables: [
    Books,
    Progresses,
    Collections,
    Memberships,
    Rules,
    Outbox,
    SyncStates,
    ConflictLog,
    Annotations,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_open());

  AppDatabase.forTesting(super.e);

  @override
  int get schemaVersion => 2;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onCreate: (m) async => await m.createAll(),
        onUpgrade: (m, from, to) async {
          // v2：新增批注表 Annotations。
          if (from < 2) {
            await m.createTable(annotations);
          }
        },
        beforeOpen: (details) async {
          await customStatement('PRAGMA foreign_keys = ON');
          // 同步依赖"按 hlc 扫描未推送记录"，这个索引是热点
          await customStatement('CREATE INDEX IF NOT EXISTS idx_outbox_hlc ON outbox(hlc)');
          await customStatement('CREATE INDEX IF NOT EXISTS idx_books_hlc ON books(hlc)');
          await customStatement(
            'CREATE INDEX IF NOT EXISTS idx_annotations_book ON annotations(book_id)',
          );
        },
      );

  static QueryExecutor _open() {
    return LazyDatabase(() async {
      final dir = await getApplicationDocumentsDirectory();
      final file = p.join(dir.path, 'inksync.sqlite');
      // Android 上确保 sqlite3 动态库可用；Windows/Linux 使用系统或打包的 sqlite
      if (await _isAndroid()) {
        await applyWorkaroundToOpenSqlite3OnOldAndroidVersions();
      }
      return NativeDatabase.createInBackground(File(file));
    });
  }

  static Future<bool> _isAndroid() async {
    // 简化判断：Platform 检查放在调用方更合适，这里用异常兜底
    try {
      return p.style == p.Style.posix &&
          (await getApplicationDocumentsDirectory()).path.startsWith('/data');
    } catch (_) {
      return false;
    }
  }

  // ─────────────── 同步状态读写 ───────────────

  Future<String?> getState(String key) async {
    final row = await (select(syncStates)..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> setState(String key, String? value) => into(syncStates).insertOnConflictUpdate(
        SyncStatesCompanion.insert(key: key, value: Value(value)),
      );

  Future<Hlc> get lastAppliedHlc async {
    final v = await getState('lastAppliedHlc');
    return v == null ? Hlc.zero : Hlc.parse(v);
  }

  // ─────────────── 书架查询（排序 / 分组） ───────────────

  /// 书架主查询。注意：**排序与分组是本地偏好，不参与同步**（见 docs/02 §6）。
  ///
  /// 为什么必须 join `memberships` + `collections`：
  ///  · `GroupKey.collection`（按分组）要读 `collectionName`，不 join 就永远是"未分组"；
  ///  · `SortKey.manual` 的 ORDER BY 落在 `memberships.sort_order` 上，
  ///    表不在 join 里会直接 SQL 报错（no such column）。
  ///
  /// 一本书可属于多个分组 → join 会产生重复行。这里按 book.id **去重保留第一行**
  /// （排序里追加了 `collections.sort_order` 作末位裁决，保证"第一行"稳定），
  /// 因此一本多分组的书只显示在其排序最前的那个分组下。这是 M2 的已知取舍。
  Stream<List<BookWithProgress>> watchLibrary({
    SortSpec sort = const SortSpec(SortKey.lastReadAt, descending: true),
    String? keyword,
    String? collectionId,
    bool includeDeleted = false,
  }) {
    // 选中分组时，join 条件里就把分组过滤掉，配合下面的 isNotNull 起到 INNER JOIN 效果
    Expression<bool> membershipOn = memberships.bookId.equalsExp(books.id) &
        memberships.removed.equals(false);
    if (collectionId != null) {
      membershipOn = membershipOn & memberships.collectionId.equals(collectionId);
    }

    final query = select(books).join([
      leftOuterJoin(progresses, progresses.bookId.equalsExp(books.id)),
      leftOuterJoin(memberships, membershipOn),
      leftOuterJoin(
        collections,
        collections.id.equalsExp(memberships.collectionId) &
            collections.deleted.equals(false),
      ),
    ]);

    if (!includeDeleted) {
      query.where(books.deleted.equals(false));
    }
    if (keyword != null && keyword.isNotEmpty) {
      final like = '%$keyword%';
      query.where(books.title.like(like) | books.author.like(like) | books.series.like(like));
    }
    if (collectionId != null) {
      query.where(memberships.id.isNotNull());
    }

    query.orderBy([
      ...sort.orderingsFor(inCollection: collectionId != null),
      // 去重时"第一行"的稳定裁决：分组顺序 → 书 id
      OrderingTerm(expression: CustomExpression('collections.sort_order'), mode: OrderingMode.asc),
      OrderingTerm(expression: books.id, mode: OrderingMode.asc),
    ]);

    return query.watch().map((rows) {
      final out = <String, BookWithProgress>{}; // LinkedHashMap，保序
      for (final r in rows) {
        final b = r.readTable(books);
        if (out.containsKey(b.id)) continue;
        final m = r.readTableOrNull(memberships);
        out[b.id] = BookWithProgress(
          book: b,
          progress: r.readTableOrNull(progresses),
          collectionName: r.readTableOrNull(collections)?.name,
          collectionId: m?.collectionId,
          membershipId: m?.id,
        );
      }
      return out.values.toList();
    });
  }

  // ─────────────── 书籍写入（导入 / 删除） ───────────────

  /// 导入一本书：写 books 行 + outbox。**幂等**：同 sha256 已存在则复活并更新元数据，
  /// 不产生第二条书架条目（内容寻址的意义就在这里）。
  ///
  /// 返回 bookId。`alreadyExisted` 由调用方通过 [findBookBySha256] 预先判断。
  Future<void> upsertBookRow(BooksCompanion row, {required String payloadJson, required String hlc}) async {
    await into(books).insertOnConflictUpdate(row);
    await into(outbox).insert(OutboxCompanion.insert(
      entityType: 'book',
      entityId: row.id.value,
      op: 'upsert',
      payloadJson: payloadJson,
      hlc: hlc,
    ));
  }

  Future<BookRow?> findBookBySha256(String sha256) =>
      (select(books)..where((t) => t.sha256.equals(sha256))).getSingleOrNull();

  /// 删除书籍：**墓碑软删除**，绝不物理删行。
  /// 物理删了以后，离线端一同步就会把这本书"复活"（它那边还是活的、hlc 更小也照样重建）。
  Future<void> tombstoneBook({
    required String bookId,
    required String hlc,
    required String deviceId,
  }) async {
    await (update(books)..where((t) => t.id.equals(bookId))).write(
      BooksCompanion(
        deleted: const Value(true),
        hlc: Value(hlc),
        updatedBy: Value(deviceId),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
    await into(outbox).insert(OutboxCompanion.insert(
      entityType: 'book',
      entityId: bookId,
      op: 'delete',
      payloadJson: jsonEncode({
        'id': bookId,
        'deleted': true,
        'hlc': hlc,
        'updatedBy': deviceId,
      }),
      hlc: hlc,
    ));
  }

  /// 删除分组：**墓碑软删除**，并级联把分组内成员关系置为 `removed=true`。
  ///
  /// 级联的原因：如果不处理成员关系，其它设备上的 membership 会悬空（指向一个已删分组），
  /// 而 `watchBookCollectionIds` 只看 `removed=false`、不看分组是否删除 —— 结果"加入分组"
  /// 面板又会把这本书当成还在该分组里，甚至把它"复活"回书架视图。
  Future<void> deleteCollection({
    required String collectionId,
    required String hlc,
    required String deviceId,
  }) async {
    await (update(collections)..where((t) => t.id.equals(collectionId))).write(
      CollectionsCompanion(
        deleted: const Value(true),
        hlc: Value(hlc),
        updatedBy: Value(deviceId),
      ),
    );

    // 级联：分组内所有成员关系置 removed=true（并写 outbox，使其跨端同步）
    final members = await (select(memberships)
          ..where((t) => t.collectionId.equals(collectionId)))
        .get();
    for (final m in members) {
      await into(memberships).insertOnConflictUpdate(MembershipsCompanion.insert(
        id: m.id,
        bookId: m.bookId,
        collectionId: m.collectionId,
        removed: const Value(true),
        hlc: hlc,
        updatedBy: deviceId,
      ));
      await into(outbox).insert(OutboxCompanion.insert(
        entityType: 'membership',
        entityId: m.id,
        op: 'upsert',
        payloadJson: jsonEncode({
          'id': m.id,
          'bookId': m.bookId,
          'collectionId': m.collectionId,
          'removed': true,
          'hlc': hlc,
          'updatedBy': deviceId,
        }),
        hlc: hlc,
      ));
    }

    // 分组自身的墓碑（deleted:true），让其它设备把它从分组列表里去掉
    await into(outbox).insert(OutboxCompanion.insert(
      entityType: 'collection',
      entityId: collectionId,
      op: 'delete',
      payloadJson: jsonEncode({
        'id': collectionId,
        'deleted': true,
        'hlc': hlc,
        'updatedBy': deviceId,
      }),
      hlc: hlc,
    ));
  }

  /// 某本书当前所属的分组 id 集合（已 `removed` 的不算）。
  /// "加入分组"面板要靠它回显勾选状态。
  Stream<Set<String>> watchBookCollectionIds(String bookId) =>
      (select(memberships)
            ..where((t) => t.bookId.equals(bookId) & t.removed.equals(false)))
          .watch()
          .map((rows) => rows.map((r) => r.collectionId).toSet());

  Stream<List<CollectionRow>> watchCollections() =>
      (select(collections)
            ..where((t) => t.deleted.equals(false))
            ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
          .watch();

  Stream<List<RuleRow>> watchRules() =>
      (select(rules)
            ..where((t) => t.deleted.equals(false))
            ..orderBy([(t) => OrderingTerm.asc(t.sortOrder)]))
          .watch();

  /// 待推送队列的**全部**记录（按 seq 升序）。
  ///
  /// outbox 是本地变更的"唯一事实来源"：每次成功推送后由 [clearOutboxUpTo]
  /// 按 seq 整体清空，因此这里**绝不**再按 HLC 二次过滤。
  ///
  /// 旧实现用 `hlc > lastAppliedHlc` 过滤，但 `lastAppliedHlc` 会被拉取远端批次
  /// 推进到很大的实时 HLC（批次文件名 = 本端 `clock.tick()` 的实时戳）。一旦它超过
  /// 本端后产生的本地变更 HLC（例如固定测试 HLC、或本端时钟回拨场景），这些变更
  /// 就会被误判为"已同步"而永久丢弃——典型受害者就是墓碑删除，导致书籍/分组/
  /// 规则删除永远推不出去、跨端不同步。
  Future<List<OutboxRow>> pendingOutbox() async =>
      (select(outbox)..orderBy([(t) => OrderingTerm.asc(t.seq)])).get();

  Future<void> clearOutboxUpTo(int seq) =>
      (delete(outbox)..where((t) => t.seq.isSmallerOrEqualValue(seq))).go();

  Future<void> logConflict({
    required String entityType,
    required String entityId,
    required String field,
    required Object? localValue,
    required Object? remoteValue,
    required String winner,
  }) =>
      into(conflictLog).insert(
        ConflictLogCompanion.insert(
          entityType: entityType,
          entityId: entityId,
          field: field,
          localValue: jsonEncode(localValue),
          remoteValue: jsonEncode(remoteValue),
          winner: winner,
        ),
      );

  /// 某本书的批注列表，按全书字符偏移升序（图片书按 page index）。软删的不显示。
  Stream<List<AnnotationRow>> watchAnnotations(String bookId) =>
      (select(annotations)
            ..where((t) => t.bookId.equals(bookId) & t.deleted.equals(false))
            ..orderBy([(t) => OrderingTerm.asc(t.charOffset)]))
          .watch();

  /// 未处理的冲突列表（按时间倒序），同步中心展示用。「绝不静默覆盖」。
  Stream<List<ConflictRow>> watchConflicts() =>
      (select(conflictLog)
            ..where((t) => t.dismissed.equals(false))
            ..orderBy([(t) => OrderingTerm.desc(t.createdAt)]))
          .watch();

  /// 标记某条冲突为已处理（用户已查看/忽略），不再出现在同步中心。
  Future<void> dismissConflict(int id) =>
      (update(conflictLog)..where((t) => t.id.equals(id)))
          .write(const ConflictLogCompanion(dismissed: Value(true)));

  /// 待推送的本地变更数（outbox 行数），同步中心显示「还有 N 条待同步」。
  Stream<int> watchPendingOutboxCount() =>
      (select(outbox)..orderBy([(t) => OrderingTerm.asc(t.seq)]))
          .watch()
          .map((rows) => rows.length);

  /// 删除批注：墓碑软删（与书籍一致，离线端同步后也删），并写 outbox。
  Future<void> tombstoneAnnotation({
    required String id,
    required String hlc,
    required String deviceId,
  }) async {
    await (update(annotations)..where((t) => t.id.equals(id))).write(
      AnnotationsCompanion(
        deleted: const Value(true),
        hlc: Value(hlc),
        updatedBy: Value(deviceId),
        updatedAt: Value(DateTime.now().toUtc()),
      ),
    );
    await into(outbox).insert(OutboxCompanion.insert(
      entityType: 'annotation',
      entityId: id,
      op: 'delete',
      payloadJson: jsonEncode({
        'id': id,
        'deleted': true,
        'hlc': hlc,
        'updatedBy': deviceId,
      }),
      hlc: hlc,
    ));
  }
}

// ─────────────────────────── 排序 / 分组 ───────────────────────────

enum SortKey {
  title,
  author,
  addedAt,
  lastReadAt,
  progress,
  fileSize,
  series,
  /// 手动拖拽顺序（存在 memberships.sortOrder 或 books 的 customOrder）
  manual,
}

class SortSpec {
  const SortSpec(this.key, {this.descending = false, this.sortOrder = 0});

  final SortKey key;
  final bool descending;
  final int sortOrder;

  List<OrderingTerm> get orderings => orderingsFor();

  /// [inCollection] = 当前是否选中了某个分组。
  /// 手动排序在"分组内"用 `memberships.sort_order`，在"全部"用 `books.custom_order`。
  List<OrderingTerm> orderingsFor({bool inCollection = false}) {
    OrderingMode mode({bool asc = false}) =>
        (descending ^ asc) ? OrderingMode.desc : OrderingMode.asc;
    switch (key) {
      case SortKey.title:
        return [OrderingTerm(expression: CustomExpression('title COLLATE NOCASE'), mode: mode())];
      case SortKey.author:
        return [OrderingTerm(expression: CustomExpression('author COLLATE NOCASE'), mode: mode())];
      case SortKey.addedAt:
        return [OrderingTerm(expression: CustomExpression('added_at'), mode: mode())];
      case SortKey.lastReadAt:
        // 未读的排最后
        return [
          OrderingTerm(
            expression: CustomExpression('progresses.updated_at IS NULL'),
            mode: OrderingMode.asc,
          ),
          OrderingTerm(expression: CustomExpression('progresses.updated_at'), mode: mode()),
        ];
      case SortKey.progress:
        return [OrderingTerm(expression: CustomExpression('progresses.percent'), mode: mode())];
      case SortKey.fileSize:
        return [OrderingTerm(expression: CustomExpression('file_size'), mode: mode())];
      case SortKey.series:
        return [
          OrderingTerm(expression: CustomExpression('series COLLATE NOCASE'), mode: mode()),
          OrderingTerm(expression: CustomExpression('series_index'), mode: mode(asc: true)),
        ];
      case SortKey.manual:
        return [
          OrderingTerm(
            expression: CustomExpression(
              inCollection ? 'memberships.sort_order' : 'books.custom_order',
            ),
            mode: mode(asc: true),
          ),
        ];
    }
  }

  SortSpec copyWith({SortKey? key, bool? descending}) =>
      SortSpec(key ?? this.key, descending: descending ?? this.descending);
}

enum GroupKey { none, collection, author, series, format, readStatus }

class GroupSpec {
  const GroupSpec(this.key, {this.collapsed = const {}});

  final GroupKey key;
  final Set<String> collapsed;

  String groupLabelFor(BookWithProgress item) {
    switch (key) {
      case GroupKey.none:
        return '';
      case GroupKey.collection:
        return item.collectionName ?? '未分组';
      case GroupKey.author:
        return (item.book.author?.trim().isNotEmpty ?? false) ? item.book.author! : '未知作者';
      case GroupKey.series:
        return (item.book.series?.trim().isNotEmpty ?? false) ? item.book.series! : '单本';
      case GroupKey.format:
        return item.book.format.toUpperCase();
      case GroupKey.readStatus:
        final pct = item.progress?.percent ?? 0;
        if (pct <= 0) return '未读';
        if (pct >= 0.99) return '已读完';
        return '在读';
    }
  }
}

class BookWithProgress {
  BookWithProgress({
    required this.book,
    this.progress,
    this.collectionName,
    this.collectionId,
    this.membershipId,
  });

  final BookRow book;
  final ProgressRow? progress;
  final String? collectionName;

  /// 该书在当前视图下命中的分组（未分组为 null）。拖拽排序要用。
  final String? collectionId;
  final String? membershipId;

  double get percent => progress?.percent ?? 0;
  bool get finished => percent >= 0.99;
}

class SyncStateKeys {
  static const lastAppliedHlc = 'lastAppliedHlc';
  static const manifestEtag = 'manifestEtag';
  static const deviceId = 'deviceId';
  static const lastSyncAt = 'lastSyncAt';
  /// '1' = 上次传输有失败/未完成的文件，下次即便「无变更」也要重试传输。
  static const pendingTransfers = 'pendingTransfers';
  static const sortSpec = 'pref.sortSpec'; // 本地偏好，不同步
  static const groupSpec = 'pref.groupSpec';
}
