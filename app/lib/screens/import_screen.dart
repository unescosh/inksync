import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../state/providers.dart';

/// 支持导入的扩展名。和 Rust `BookFormat::from_path` 保持一致，
/// 多一个少一个都会出现"选得进、解析不了"的尴尬。
const kSupportedBookExts = <String>{
  'epub',
  'txt',
  'mobi',
  'azw',
  'azw3',
  'kf8',
  'pdf',
  'cbz',
  'cbr',
};

/// 导入页。
///
/// 三个刻意的设计决策：
/// 1. **串行导入**。解析 + sha256 + 落盘都是 CPU/IO 密集的，并发跑只会让
///    低配 Android 机和 UOS 虚拟机卡成幻灯片，还容易 OOM（漫画封面几 MB）。
/// 2. **单文件失败不中断整批**。导入 200 本漫画时因为一本损坏 CBZ 全盘回滚，
///    是最让人恼火的行为。每条任务独立记状态，失败的留在列表里可重试。
/// 3. **去重结果要显式告诉用户**。同 sha256 的书不会新增条目（内容寻址），
///    但用户看到"导入了 10 本，书架只多了 3 本"会以为是 bug，所以分开计数。
class ImportScreen extends ConsumerStatefulWidget {
  const ImportScreen({super.key});

  @override
  ConsumerState<ImportScreen> createState() => _ImportScreenState();
}

enum _TaskState { pending, running, done, duplicate, failed }

class _ImportTask {
  _ImportTask(this.path);

  final String path;
  _TaskState state = _TaskState.pending;
  String? message;

  String get name => p.basename(path);
}

class _ImportScreenState extends ConsumerState<ImportScreen> {
  final List<_ImportTask> _tasks = [];
  bool _running = false;

  /// file_selector 的目录选择在 Android 上没有实现（SAF 的目录树是另一套 API），
  /// 所以文件夹导入只在桌面端露出。
  bool get _canPickFolder => !kIsWeb && (Platform.isWindows || Platform.isLinux);

  int _count(_TaskState s) => _tasks.where((t) => t.state == s).length;

  @override
  Widget build(BuildContext context) {
    final pending = _count(_TaskState.pending) + _count(_TaskState.running);
    final ok = _count(_TaskState.done);
    final dup = _count(_TaskState.duplicate);
    final failed = _count(_TaskState.failed);

    return Scaffold(
      appBar: AppBar(
        title: const Text('导入书籍'),
        actions: [
          if (_tasks.isNotEmpty && !_running)
            IconButton(
              tooltip: '清空列表',
              icon: const Icon(Icons.clear_all),
              onPressed: () => setState(_tasks.clear),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _running ? null : _pickFiles,
                    icon: const Icon(Icons.insert_drive_file_outlined),
                    label: const Text('选择文件'),
                  ),
                ),
                if (_canPickFolder) ...[
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _running ? null : _pickFolder,
                      icon: const Icon(Icons.folder_open),
                      label: const Text('选择文件夹'),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '支持 ${kSupportedBookExts.map((e) => '.$e').join(' / ')}'
                '${_canPickFolder ? '；选择文件夹会递归扫描子目录' : ''}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (_running) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: _tasks.isEmpty
                ? const Center(child: Text('还没有待导入的文件'))
                : ListView.builder(
                    itemCount: _tasks.length,
                    itemBuilder: (context, i) => _TaskTile(
                      task: _tasks[i],
                      onRetry: _running ? null : () => _retry(_tasks[i]),
                    ),
                  ),
          ),
        ],
      ),
      bottomNavigationBar: _tasks.isEmpty
          ? null
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        [
                          if (pending > 0) '待处理 $pending',
                          if (ok > 0) '新增 $ok',
                          if (dup > 0) '已存在 $dup',
                          if (failed > 0) '失败 $failed',
                        ].join(' · '),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ),
                    TextButton(
                      onPressed: _running ? null : () => Navigator.of(context).pop(),
                      child: const Text('完成'),
                    ),
                  ],
                ),
              ),
            ),
    );
  }

  // ─────────────────────────── 选择来源 ───────────────────────────

  Future<void> _pickFiles() async {
    // Android 的 SAF 只认 MIME，.cbz / .azw3 在多数机型上映射不到有效 MIME，
    // 强行过滤会导致"漫画文件在选择器里是灰的"。所以 Android 不过滤，
    // 选完之后再按扩展名校验一遍。
    final isAndroid = !kIsWeb && Platform.isAndroid;
    final groups = isAndroid
        ? const <XTypeGroup>[]
        : const [
            XTypeGroup(
              label: '电子书 / 漫画',
              extensions: ['epub', 'txt', 'mobi', 'azw', 'azw3', 'kf8', 'pdf', 'cbz', 'cbr'],
            ),
          ];

    final List<XFile> files;
    try {
      files = await openFiles(acceptedTypeGroups: groups);
    } catch (e) {
      _snack('打开文件选择器失败：$e');
      return;
    }
    if (files.isEmpty) return;
    _enqueue(files.map((f) => f.path));
  }

  Future<void> _pickFolder() async {
    final String? dir;
    try {
      dir = await getDirectoryPath();
    } catch (e) {
      _snack('打开文件夹选择器失败：$e');
      return;
    }
    if (dir == null) return;

    final found = <String>[];
    try {
      await for (final e in Directory(dir).list(recursive: true, followLinks: false)) {
        if (e is File && _isSupported(e.path)) found.add(e.path);
      }
    } catch (e) {
      _snack('扫描文件夹失败：$e');
      return;
    }
    if (found.isEmpty) {
      _snack('该文件夹里没有找到支持的电子书文件');
      return;
    }
    found.sort(_naturalCompare);
    _enqueue(found);
  }

  static bool _isSupported(String path) =>
      kSupportedBookExts.contains(p.extension(path).replaceFirst('.', '').toLowerCase());

  /// 漫画目录里常见 `第1话 / 第2话 / 第10话`，纯字典序会把 10 排到 2 前面。
  static int _naturalCompare(String a, String b) {
    final ra = RegExp(r'\d+|\D+');
    final ta = ra.allMatches(a).map((m) => m[0]!).toList();
    final tb = ra.allMatches(b).map((m) => m[0]!).toList();
    for (var i = 0; i < ta.length && i < tb.length; i++) {
      final na = int.tryParse(ta[i]);
      final nb = int.tryParse(tb[i]);
      final c = (na != null && nb != null) ? na.compareTo(nb) : ta[i].compareTo(tb[i]);
      if (c != 0) return c;
    }
    return ta.length.compareTo(tb.length);
  }

  void _enqueue(Iterable<String> paths) {
    final known = _tasks.map((t) => t.path).toSet();
    final added = <_ImportTask>[];
    var skipped = 0;
    for (final path in paths) {
      if (known.contains(path)) continue;
      if (!_isSupported(path)) {
        skipped++;
        continue;
      }
      known.add(path);
      added.add(_ImportTask(path));
    }
    if (added.isEmpty) {
      if (skipped > 0) _snack('跳过 $skipped 个不支持的文件');
      return;
    }
    setState(() => _tasks.addAll(added));
    if (skipped > 0) _snack('已加入 ${added.length} 个文件，跳过 $skipped 个不支持的格式');
    _run();
  }

  void _retry(_ImportTask t) {
    setState(() {
      t.state = _TaskState.pending;
      t.message = null;
    });
    _run();
  }

  // ─────────────────────────── 执行 ───────────────────────────

  Future<void> _run() async {
    if (_running) return;
    setState(() => _running = true);
    final actions = ref.read(libraryActionsProvider);

    // 用下标遍历：跑的过程中用户可能继续往列表里追加文件
    for (var i = 0; i < _tasks.length; i++) {
      final t = _tasks[i];
      if (t.state != _TaskState.pending) continue;
      if (!mounted) return;
      setState(() => t.state = _TaskState.running);
      try {
        final r = await actions.importBook(t.path);
        if (!mounted) return;
        setState(() {
          t.state = r.duplicate ? _TaskState.duplicate : _TaskState.done;
          t.message = r.title;
        });
      } catch (e) {
        if (!mounted) return;
        setState(() {
          t.state = _TaskState.failed;
          t.message = '$e';
        });
      }
    }
    if (mounted) setState(() => _running = false);
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({required this.task, this.onRetry});

  final _ImportTask task;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    late final Widget leading;
    String? subtitle = task.message;

    switch (task.state) {
      case _TaskState.pending:
        leading = const Icon(Icons.schedule, size: 20);
        subtitle ??= '等待中';
      case _TaskState.running:
        leading = const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
        subtitle = '解析中…';
      case _TaskState.done:
        leading = Icon(Icons.check_circle, size: 20, color: scheme.primary);
        subtitle = '已加入书架${task.message == null ? '' : '：${task.message}'}';
      case _TaskState.duplicate:
        leading = Icon(Icons.content_copy, size: 20, color: scheme.tertiary);
        subtitle = '书架上已有同一文件，已刷新元数据';
      case _TaskState.failed:
        leading = Icon(Icons.error, size: 20, color: scheme.error);
    }

    return ListTile(
      dense: true,
      leading: leading,
      title: Text(task.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: task.state == _TaskState.failed
                  ? TextStyle(color: scheme.error)
                  : null,
            ),
      trailing: task.state == _TaskState.failed && onRetry != null
          ? IconButton(
              tooltip: '重试',
              icon: const Icon(Icons.refresh),
              onPressed: onRetry,
            )
          : null,
    );
  }
}
