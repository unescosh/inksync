import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../state/providers.dart';

/// 书架页：搜索 / 排序 / 分组 / 视图切换 / 拖拽排序。
///
/// 几个刻意的设计决策：
/// 1. 排序与分组是**本地偏好，不参与同步**。三端屏幕尺寸差异大，
///    手机上要单列网格、电脑上要三列 + 侧边栏分组，强制同步只会两边都难受。
/// 2. 手动排序（拖拽）只在满足全部条件时启用，否则显示原因提示，
///    避免用户"拖了没反应"或者"拖完顺序又跳回去"：
///      · sortKey == manual —— 否则刷新后按原排序键重排，拖了白拖；
///      · 未分组视图      —— 分组视图里每组只是全量列表的一个切片，
///        写回 0..n-1 会和别组的顺序值撞车，结果不确定；
///      · 没有搜索关键词  —— 同理，搜索结果是子集。
/// 3. 拖拽回调传**移动后的完整 id 顺序**而不是 (from, to) 下标，
///    因为 UI 下标和数据库行序不是一回事（见 SortController.reorderBooks 注释）。
class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});

  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen> {
  final _search = TextEditingController();
  String? _selectedCollectionId;
  bool _searching = false;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool get _isDesktop {
    final w = MediaQuery.maybeSizeOf(context)?.width ?? 0;
    return w >= 900;
  }

  /// 返回"为什么现在不能拖" —— null 表示可以拖。
  /// 只在用户已经选了手动排序时才有意义（否则不该弹提示烦人）。
  String? _reorderBlockReason(SortSpec sort, GroupSpec group) {
    if (sort.key != SortKey.manual) return null;
    if (group.key != GroupKey.none) {
      return '分组视图下不支持拖拽排序，请先把分组切到"不分组"';
    }
    if (_search.text.isNotEmpty) {
      return '搜索结果是全部书籍的子集，拖拽会打乱未显示的书，已暂时禁用';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final sort = ref.watch(sortSpecProvider);
    final group = ref.watch(groupSpecProvider);
    final booksAsync = ref.watch(libraryProvider(
      LibraryQuery(sort: sort, keyword: _search.text, collectionId: _selectedCollectionId),
    ));
    final collectionsAsync = ref.watch(collectionsProvider);
    final syncState = ref.watch(syncTriggerProvider);
    final syncing = syncState.isLoading;
    // 待备份改动数：书架常驻展示，让用户一眼看到"还有多少没同步"
    final pending = ref.watch(pendingOutboxCountProvider).valueOrNull ?? 0;
    // 上次同步是否出错（异常或 report 非空但 ok=false）—— AppBar 图标转红
    final syncError = syncState.hasError || (syncState.value?.ok == false);
    // 未配置同步服务器 → 首屏引导去设置
    final webdavCfg = ref.watch(webdavConfigProvider);
    final serverUnconfigured = webdavCfg.hasValue && webdavCfg.value == null;

    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _search,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: '搜索书名 / 作者 / 系列',
                  border: InputBorder.none,
                ),
                onChanged: (_) => setState(() {}),
              )
            : const Text('书架'),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close : Icons.search),
            onPressed: () => setState(() {
              _searching = !_searching;
              if (!_searching) _search.clear();
            }),
          ),
          _SortMenu(sort: sort, onChanged: ref.read(sortSpecProvider.notifier).apply),
          _GroupMenu(group: group, onChanged: ref.read(groupSpecProvider.notifier).apply),
          IconButton(
            icon: const Icon(Icons.brush_outlined),
            tooltip: '高亮规则',
            onPressed: () => Navigator.of(context).pushNamed('/rules'),
          ),
          IconButton(
            icon: Badge(
              label: Text('$pending'),
              isLabelVisible: pending > 0,
              child: syncing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Icon(
                      syncError ? Icons.sync_problem : Icons.sync,
                      color: syncError
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
            ),
            tooltip: syncing
                ? '同步中…'
                : (syncError ? '上次同步出错' : '立即同步'),
            onPressed: syncing ? null : ref.read(syncTriggerProvider.notifier).syncNow,
          ),
          IconButton(
            icon: const Icon(Icons.hub_outlined),
            tooltip: '同步中心',
            onPressed: () => Navigator.of(context).pushNamed('/sync-center'),
          ),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: '同步设置',
            onPressed: () => Navigator.of(context).pushNamed('/settings'),
          ),
        ],
      ),
      drawer: _isDesktop
          ? null
          : _CollectionsDrawer(
              collectionsAsync: collectionsAsync,
              selectedId: _selectedCollectionId,
              onSelect: (id) => setState(() => _selectedCollectionId = id),
            ),
      body: Column(
        children: [
          if (serverUnconfigured)
            _SyncSetupBanner(
              onOpen: () => Navigator.of(context).pushNamed('/settings'),
            ),
          Expanded(
            child: Row(
              children: [
                if (_isDesktop) ...[
            SizedBox(
              width: 220,
              child: _CollectionsPane(
                collectionsAsync: collectionsAsync,
                selectedId: _selectedCollectionId,
                onSelect: (id) => setState(() => _selectedCollectionId = id),
              ),
            ),
            const VerticalDivider(width: 1),
          ],
          Expanded(
            child: booksAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Center(child: Text('加载失败：$e')),
              data: (books) => _buildBooks(books, sort, group),
            ),
          ),
          ],
        ),
        ),
      ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => Navigator.of(context).pushNamed('/import'),
        tooltip: '导入书籍',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildBooks(List<BookWithProgress> books, SortSpec sort, GroupSpec group) {
    if (books.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.menu_book_outlined, size: 48),
            const SizedBox(height: 12),
            Text(_search.text.isEmpty ? '还没有书，点击右下角导入' : '没有匹配的书'),
          ],
        ),
      );
    }

    final blocked = _reorderBlockReason(sort, group);
    final canReorder = sort.key == SortKey.manual && blocked == null;
    final cross = _isDesktop ? 4 : 2;

    final Widget content;
    if (group.key == GroupKey.none) {
      content = _BookGrid(
        books: books,
        crossAxisCount: cross,
        canReorder: canReorder,
        onReorder: _applyReorder,
      );
    } else {
      final groups = _groupBooks(books, group);
      content = ListView(
        children: [
          for (final g in groups)
            _GroupSection(
              title: '${g.label}（${g.items.length}）',
              collapsed: group.collapsed.contains(g.label),
              onToggle: () => ref.read(groupSpecProvider.notifier).toggle(g.label),
              child: _BookGrid(
                books: g.items,
                crossAxisCount: cross,
                shrinkWrap: true,
              ),
            ),
        ],
      );
    }

    if (blocked == null) return content;
    return Column(
      children: [
        _ReorderHint(text: blocked),
        Expanded(child: content),
      ],
    );
  }

  void _applyReorder(List<String> orderedIds) {
    ref.read(sortSpecProvider.notifier).reorderBooks(
          collectionId: _selectedCollectionId,
          orderedBookIds: orderedIds,
        );
  }

  List<_Group> _groupBooks(List<BookWithProgress> books, GroupSpec spec) {
    final map = <String, List<BookWithProgress>>{};
    for (final b in books) {
      map.putIfAbsent(spec.groupLabelFor(b), () => []).add(b);
    }
    final keys = map.keys.toList()..sort();
    return [for (final k in keys) _Group(k, map[k]!)];
  }
}

class _Group {
  _Group(this.label, this.items);
  final String label;
  final List<BookWithProgress> items;
}

class _ReorderHint extends StatelessWidget {
  const _ReorderHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: scheme.onSurfaceVariant),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────── 排序 / 分组菜单 ───────────────────────────

class _SyncSetupBanner extends StatelessWidget {
  const _SyncSetupBanner({required this.onOpen});

  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.tertiaryContainer,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              Icon(Icons.cloud_off, size: 18, color: scheme.onTertiaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '尚未配置同步服务器，点此设置 WebDAV 后即可在三端备份与同步',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: scheme.onTertiaryContainer),
                ),
              ),
              const Icon(Icons.chevron_right),
            ],
          ),
        ),
      ),
    );
  }
}

class _SortMenu extends StatelessWidget {
  const _SortMenu({required this.sort, required this.onChanged});

  final SortSpec sort;
  final ValueChanged<SortSpec> onChanged;

  static const _labels = <SortKey, String>{
    SortKey.title: '书名',
    SortKey.author: '作者',
    SortKey.addedAt: '加入时间',
    SortKey.lastReadAt: '最近阅读',
    SortKey.progress: '阅读进度',
    SortKey.fileSize: '文件大小',
    SortKey.series: '系列',
    SortKey.manual: '手动排序（可拖拽）',
  };

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<SortKey>(
      icon: const Icon(Icons.sort),
      tooltip: '排序',
      onSelected: (k) => onChanged(SortSpec(
        k,
        // 再次点同一项 = 反转方向，这是列表类 UI 的通用肌肉记忆
        descending: k == sort.key ? !sort.descending : _defaultDesc(k),
      )),
      itemBuilder: (_) => [
        for (final e in _labels.entries)
          CheckedPopupMenuItem<SortKey>(
            value: e.key,
            checked: sort.key == e.key,
            child: Row(
              children: [
                Expanded(child: Text(e.value)),
                if (sort.key == e.key && e.key != SortKey.manual)
                  Icon(sort.descending ? Icons.arrow_downward : Icons.arrow_upward, size: 14),
              ],
            ),
          ),
      ],
    );
  }

  static bool _defaultDesc(SortKey k) =>
      k == SortKey.addedAt || k == SortKey.lastReadAt || k == SortKey.progress;
}

class _GroupMenu extends StatelessWidget {
  const _GroupMenu({required this.group, required this.onChanged});

  final GroupSpec group;
  final ValueChanged<GroupSpec> onChanged;

  static const _labels = <GroupKey, String>{
    GroupKey.none: '不分组',
    GroupKey.collection: '按分组',
    GroupKey.author: '按作者',
    GroupKey.series: '按系列',
    GroupKey.format: '按格式',
    GroupKey.readStatus: '按阅读状态',
  };

  @override
  Widget build(BuildContext context) => PopupMenuButton<GroupKey>(
        icon: const Icon(Icons.folder_open),
        tooltip: '分组',
        onSelected: (k) => onChanged(GroupSpec(k)),
        itemBuilder: (_) => [
          for (final e in _labels.entries)
            CheckedPopupMenuItem<GroupKey>(
              value: e.key,
              checked: group.key == e.key,
              child: Text(e.value),
            ),
        ],
      );
}

// ─────────────────────────── 分组面板 / 抽屉 ───────────────────────────

class _CollectionsPane extends ConsumerWidget {
  const _CollectionsPane({
    required this.collectionsAsync,
    required this.selectedId,
    required this.onSelect,
  });

  final AsyncValue<List<CollectionRow>> collectionsAsync;
  final String? selectedId;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        ListTile(
          leading: const Icon(Icons.library_books),
          title: const Text('全部'),
          selected: selectedId == null,
          onTap: () => onSelect(null),
        ),
        const Divider(height: 1),
        Expanded(
          child: collectionsAsync.when(
            loading: () => const SizedBox.shrink(),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(12),
              child: Text('$e'),
            ),
            data: (list) => list.isEmpty
                ? const Center(child: Text('还没有分组', style: TextStyle(fontSize: 12)))
                : ReorderableListView.builder(
                    itemCount: list.length,
                    // 分组是同步实体，顺序变更要写 outbox（见 LibraryActions）
                    onReorder: (from, to) {
                      final ids = [for (final c in list) c.id];
                      final moved = ids.removeAt(from);
                      ids.insert(from < to ? to - 1 : to, moved);
                      ref.read(libraryActionsProvider).reorderCollections(ids);
                    },
                    itemBuilder: (context, i) => ListTile(
                      key: ValueKey(list[i].id),
                      leading: list[i].emoji != null
                          ? Text(list[i].emoji!, style: const TextStyle(fontSize: 18))
                          : const Icon(Icons.folder),
                      title: Text(list[i].name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      selected: selectedId == list[i].id,
                      onTap: () => onSelect(list[i].id),
                      trailing: PopupMenuButton<String>(
                        icon: const Icon(Icons.more_vert, size: 20),
                        tooltip: '分组操作',
                        onSelected: (v) async {
                          if (v == 'rename') {
                            await _renameCollection(context, ref, list[i]);
                          } else if (v == 'delete') {
                            final ok = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('删除分组'),
                                content: Text('确定删除「${list[i].name}」？分组内的书不会删除，只是移出该分组。'),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.of(ctx).pop(false),
                                    child: const Text('取消'),
                                  ),
                                  FilledButton(
                                    onPressed: () => Navigator.of(ctx).pop(true),
                                    child: const Text('删除'),
                                  ),
                                ],
                              ),
                            );
                            if (ok == true) {
                              await ref.read(libraryActionsProvider).deleteCollection(list[i].id);
                              if (selectedId == list[i].id) onSelect(null);
                            }
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'rename', child: Text('重命名')),
                          PopupMenuItem(value: 'delete', child: Text('删除')),
                        ],
                      ),
                    ),
                  ),
          ),
        ),
        const Divider(height: 1),
        ListTile(
          dense: true,
          leading: const Icon(Icons.create_new_folder_outlined, size: 20),
          title: const Text('新建分组'),
          onTap: () => _createCollection(context, ref),
        ),
      ],
    );
  }
}

Future<void> _renameCollection(
  BuildContext context,
  WidgetRef ref,
  CollectionRow row,
) async {
  final controller = TextEditingController(text: row.name);
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('重命名分组'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: '分组名称'),
        onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
          child: const Text('保存'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (name == null || name.isEmpty || name == row.name) return;
  await ref.read(libraryActionsProvider).renameCollection(id: row.id, name: name);
}

Future<String?> _createCollection(BuildContext context, WidgetRef ref) async {
  final controller = TextEditingController();
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('新建分组'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: '分组名称'),
        onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
          child: const Text('创建'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (name == null || name.isEmpty) return null;
  return ref.read(libraryActionsProvider).createCollection(name);
}

class _CollectionsDrawer extends StatelessWidget {
  const _CollectionsDrawer({
    required this.collectionsAsync,
    required this.selectedId,
    required this.onSelect,
  });

  final AsyncValue<List<CollectionRow>> collectionsAsync;
  final String? selectedId;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) => Drawer(
        child: SafeArea(
          child: _CollectionsPane(
            collectionsAsync: collectionsAsync,
            selectedId: selectedId,
            onSelect: (id) {
              onSelect(id);
              Navigator.of(context).pop();
            },
          ),
        ),
      );
}

// ─────────────────────────── 书籍网格 ───────────────────────────

class _GroupSection extends StatelessWidget {
  const _GroupSection({
    required this.title,
    required this.collapsed,
    required this.onToggle,
    required this.child,
  });

  final String title;
  final bool collapsed;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: onToggle,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  Icon(collapsed ? Icons.expand_more : Icons.expand_less, size: 18),
                  const SizedBox(width: 6),
                  Text(title, style: Theme.of(context).textTheme.titleSmall),
                ],
              ),
            ),
          ),
          if (!collapsed) child,
        ],
      );
}

const _gridPadding = 12.0;
const _gridSpacing = 12.0;
const _gridAspect = 0.62;

class _BookGrid extends StatelessWidget {
  const _BookGrid({
    required this.books,
    required this.crossAxisCount,
    this.shrinkWrap = false,
    this.canReorder = false,
    this.onReorder,
  });

  final List<BookWithProgress> books;
  final int crossAxisCount;
  final bool shrinkWrap;
  final bool canReorder;

  /// 收到的是**移动后的完整 id 顺序**，不是 (from, to)。
  final void Function(List<String> orderedBookIds)? onReorder;

  @override
  Widget build(BuildContext context) {
    if (canReorder && onReorder != null) {
      return _ReorderableBookGrid(
        books: books,
        crossAxisCount: crossAxisCount,
        shrinkWrap: shrinkWrap,
        onReorder: onReorder!,
      );
    }
    return GridView.builder(
      shrinkWrap: shrinkWrap,
      physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
      padding: const EdgeInsets.all(_gridPadding),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: crossAxisCount,
        childAspectRatio: _gridAspect,
        crossAxisSpacing: _gridSpacing,
        mainAxisSpacing: _gridSpacing,
      ),
      itemCount: books.length,
      itemBuilder: (context, i) => _BookCard(item: books[i]),
    );
  }
}

/// 网格拖拽排序。
///
/// 为什么不用 `ReorderableListView`：它只能做**单列**。把 N 本书按行打包成
/// 一个 item 交给它，拖动交换的是"整行"，用户拖一本书会连带旁边几本一起走，
/// 这不是排序，是灾难。所以这里用 `Draggable` + `DragTarget` 做逐格重排。
///
/// 本地先乐观更新 `_items`（拖完立刻看到新顺序），再把完整 id 顺序回调出去写库；
/// 数据库流回来后如果 id 序列变了（比如别的设备同步进来新书）再重新对齐。
class _ReorderableBookGrid extends StatefulWidget {
  const _ReorderableBookGrid({
    required this.books,
    required this.crossAxisCount,
    required this.shrinkWrap,
    required this.onReorder,
  });

  final List<BookWithProgress> books;
  final int crossAxisCount;
  final bool shrinkWrap;
  final void Function(List<String> orderedBookIds) onReorder;

  @override
  State<_ReorderableBookGrid> createState() => _ReorderableBookGridState();
}

class _ReorderableBookGridState extends State<_ReorderableBookGrid> {
  late List<BookWithProgress> _items = List.of(widget.books);
  bool _dragging = false;

  @override
  void didUpdateWidget(_ReorderableBookGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 正在拖的时候别打断（数据库回流会把手里的卡片抽走）
    if (_dragging) return;
    if (!_sameIds(_items, widget.books)) {
      _items = List.of(widget.books);
    }
  }

  static bool _sameIds(List<BookWithProgress> a, List<BookWithProgress> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].book.id != b[i].book.id) return false;
    }
    return true;
  }

  void _drop(int from, int to) {
    if (from == to || from < 0 || from >= _items.length) return;
    setState(() {
      final moved = _items.removeAt(from);
      _items.insert(to.clamp(0, _items.length), moved);
      _dragging = false;
    });
    widget.onReorder([for (final b in _items) b.book.id]);
  }

  @override
  Widget build(BuildContext context) {
    final cross = widget.crossAxisCount;
    return LayoutBuilder(
      builder: (context, constraints) {
        final cellW =
            (constraints.maxWidth - _gridPadding * 2 - _gridSpacing * (cross - 1)) / cross;
        final cellH = cellW / _gridAspect;

        return GridView.builder(
          shrinkWrap: widget.shrinkWrap,
          physics: widget.shrinkWrap ? const NeverScrollableScrollPhysics() : null,
          padding: const EdgeInsets.all(_gridPadding),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cross,
            childAspectRatio: _gridAspect,
            crossAxisSpacing: _gridSpacing,
            mainAxisSpacing: _gridSpacing,
          ),
          itemCount: _items.length,
          itemBuilder: (context, i) => _ReorderCell(
            index: i,
            item: _items[i],
            width: cellW > 0 ? cellW : 120,
            height: cellH > 0 ? cellH : 200,
            onDragStart: () => _dragging = true,
            onDragCancel: () => setState(() => _dragging = false),
            onAccept: (from) => _drop(from, i),
          ),
        );
      },
    );
  }
}

class _ReorderCell extends StatelessWidget {
  const _ReorderCell({
    required this.index,
    required this.item,
    required this.width,
    required this.height,
    required this.onDragStart,
    required this.onDragCancel,
    required this.onAccept,
  });

  final int index;
  final BookWithProgress item;
  final double width;
  final double height;
  final VoidCallback onDragStart;
  final VoidCallback onDragCancel;
  final ValueChanged<int> onAccept;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return DragTarget<int>(
      onWillAcceptWithDetails: (d) => d.data != index,
      onAcceptWithDetails: (d) => onAccept(d.data),
      builder: (context, candidate, rejected) {
        final highlight = candidate.isNotEmpty;
        return LongPressDraggable<int>(
          data: index,
          onDragStarted: onDragStart,
          onDraggableCanceled: (_, __) => onDragCancel(),
          // feedback 渲染在 Overlay 里，脱离了原来的 Material 祖先，
          // 不套一层 Material 的话 Card 的阴影和裁剪会失效
          feedback: Material(
            type: MaterialType.transparency,
            child: SizedBox(
              width: width,
              height: height,
              child: Opacity(opacity: 0.9, child: _BookCard(item: item, reorderable: true)),
            ),
          ),
          childWhenDragging: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: scheme.outlineVariant, style: BorderStyle.solid),
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                width: 2,
                color: highlight ? scheme.primary : Colors.transparent,
              ),
            ),
            child: _BookCard(item: item, reorderable: true),
          ),
        );
      },
    );
  }
}

class _BookCard extends ConsumerWidget {
  const _BookCard({required this.item, this.reorderable = false});

  final BookWithProgress item;

  /// 处于拖拽模式：长按被 Draggable 占用了，操作入口只走右上角按钮。
  final bool reorderable;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final b = item.book;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          InkWell(
            onTap: () => Navigator.of(context).pushNamed('/reader', arguments: b.id),
            onLongPress: reorderable ? null : () => _showBookActions(context, ref),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: b.coverPath != null
                      ? Image.file(
                          File(b.coverPath!),
                          fit: BoxFit.cover,
                          // 关键：限制解码尺寸。漫画封面动辄 3000px，
                          // 不限制会在低配 Android 上直接 OOM
                          cacheWidth: 400,
                          errorBuilder: (_, __, ___) => const _NoCover(),
                        )
                      : const _NoCover(),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
                  child: Text(
                    b.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 4),
                  child: Text(
                    b.author ?? '未知作者',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: LinearProgressIndicator(
                    value: item.percent.clamp(0.0, 1.0).toDouble(),
                    minHeight: 3,
                  ),
                ),
              ],
            ),
          ),
          Positioned(
            top: 0,
            right: 0,
            child: IconButton(
              iconSize: 18,
              visualDensity: VisualDensity.compact,
              tooltip: '更多操作',
              style: IconButton.styleFrom(
                backgroundColor: Colors.black.withOpacity(0.35),
                foregroundColor: Colors.white,
              ),
              icon: const Icon(Icons.more_vert),
              onPressed: () => _showBookActions(context, ref),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _showBookActions(BuildContext context, WidgetRef ref) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(item.book.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(
                '${item.book.format.toUpperCase()} · '
                '${_humanSize(item.book.fileSize)} · '
                '${(item.percent * 100).toStringAsFixed(0)}%',
              ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.folder),
              title: const Text('加入分组'),
              onTap: () => Navigator.pop(ctx, 'collections'),
            ),
            ListTile(
              leading: const Icon(Icons.image),
              title: const Text('自定义封面'),
              subtitle: const Text('M3 实现'),
              enabled: false,
              onTap: () {},
            ),
            ListTile(
              leading: const Icon(Icons.edit),
              title: const Text('编辑信息'),
              subtitle: const Text('M3 实现'),
              enabled: false,
              onTap: () {},
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('删除（三端同步）'),
              onTap: () => Navigator.pop(ctx, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (!context.mounted || action == null) return;

    switch (action) {
      case 'collections':
        await _showCollectionPicker(context, ref, item.book.id);
      case 'delete':
        await _confirmDelete(context, ref);
    }
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这本书？'),
        content: Text(
          '「${item.book.title}」会从三端书架一起移除（墓碑同步，离线端上线后也会删掉）。\n'
          '原文件仍保留在本地仓库中，重新导入即可恢复，阅读进度不会丢。',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Theme.of(ctx).colorScheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await ref.read(libraryActionsProvider).deleteBook(item.book.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已删除「${item.book.title}」')),
      );
    }
  }

  static String _humanSize(int bytes) {
    if (bytes <= 0) return '未知大小';
    const units = ['B', 'KB', 'MB', 'GB'];
    var v = bytes.toDouble();
    var i = 0;
    while (v >= 1024 && i < units.length - 1) {
      v /= 1024;
      i++;
    }
    return '${v.toStringAsFixed(i == 0 ? 0 : 1)}${units[i]}';
  }
}

Future<void> _showCollectionPicker(BuildContext context, WidgetRef ref, String bookId) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _CollectionPickerSheet(bookId: bookId),
  );
}

class _CollectionPickerSheet extends ConsumerWidget {
  const _CollectionPickerSheet({required this.bookId});

  final String bookId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final collections = ref.watch(collectionsProvider);
    final mine = ref.watch(bookCollectionsProvider(bookId));

    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('加入分组'),
              ),
            ),
            const Divider(height: 1),
            Flexible(
              child: collections.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (e, _) => Padding(padding: const EdgeInsets.all(16), child: Text('$e')),
                data: (list) {
                  if (list.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('还没有分组，先新建一个'),
                    );
                  }
                  final selected = mine.valueOrNull ?? const <String>{};
                  return ListView.builder(
                    shrinkWrap: true,
                    itemCount: list.length,
                    itemBuilder: (context, i) {
                      final c = list[i];
                      return CheckboxListTile(
                        value: selected.contains(c.id),
                        title: Text(c.name),
                        onChanged: (v) => ref.read(libraryActionsProvider).setMembership(
                              bookId: bookId,
                              collectionId: c.id,
                              member: v ?? false,
                            ),
                      );
                    },
                  );
                },
              ),
            ),
            const Divider(height: 1),
            ListTile(
              dense: true,
              leading: const Icon(Icons.create_new_folder_outlined, size: 20),
              title: const Text('新建分组并加入'),
              onTap: () async {
                final id = await _createCollection(context, ref);
                if (id == null) return;
                await ref.read(libraryActionsProvider).setMembership(
                      bookId: bookId,
                      collectionId: id,
                      member: true,
                    );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _NoCover extends StatelessWidget {
  const _NoCover();

  @override
  Widget build(BuildContext context) => Container(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        child: const Center(child: Icon(Icons.menu_book, size: 40)),
      );
}
