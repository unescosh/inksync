import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/native_core.dart';
import '../data/database.dart';
import '../reader/content.dart';
import '../reader/highlight.dart';
import '../reader/rules.dart';
import '../state/providers.dart';
import 'package:pdfrx/pdfrx.dart';

/// 阅读器。
///
/// 内容管线：
///   原始文件 → Rust 核心解析 → RawChapter.xhtml（归一化）
///   → ContentParser → ContentBlock[]
///   → RuleEngine 打标 → HighlightRenderer → InlineSpan → RichText
///
/// 三端一致性的关键：**不走 WebView**。
/// Windows 是 WebView2、UOS 是 WebKitGTK(2.28)、Android 是系统 WebView，
/// 三者 CSS 支持差异巨大，走 WebView 必然出现"同一本书三端长得不一样"。
class ReaderScreen extends ConsumerStatefulWidget {
  const ReaderScreen({super.key, required this.bookId});

  final String bookId;

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  final ScrollController _scroll = ScrollController();
  final SpanCache _cache = SpanCache();
  Timer? _saveTimer;

  BookRow? _row;
  ParsedBook? _book;
  List<ContentBlock>? _blocks;
  int _chapter = 0;
  int _page = 0;
  PageController? _pageController;
  bool _loading = true;
  String? _error;
  String? _localPath;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    _pageController?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final db = ref.read(databaseProvider);
      final row = await (db.select(db.books)
            ..where((t) => t.id.equals(widget.bookId)))
          .getSingleOrNull();
      if (row == null) throw Exception('书籍不存在');

      final path = row.localPath ?? await ref.read(blobStoreProvider).pathFor(row.sha256);
      if (path == null) throw Exception('书籍文件尚未同步完成');

      // 大书解析放在后台 isolate 外也可以：Rust 解析本身在自己的线程池，
      // 不占用 Dart 主线程，所以这里直接 await 即可。
      final parsed = await ref.read(nativeCoreProvider).parseBook(path);

      // 还原进度
      final pg = await (db.select(db.progresses)
            ..where((t) => t.bookId.equals(widget.bookId)))
          .getSingleOrNull();
      var chapter = 0;
      var fraction = 0.0;
      if (pg != null) {
        final loc = jsonDecode(pg.locatorJson) as Map<String, dynamic>;
        if (parsed.isImageBook) {
          // 图片书：按 page_index 还原
          _page = (loc['page'] as num?)?.toInt() ?? 0;
          final n = parsed.pages?.length ?? 0;
          fraction = n <= 1 ? 0.0 : (_page / (n - 1)).clamp(0.0, 1.0);
        } else if (parsed.chapters.isNotEmpty) {
          // 文本书：优先用 Rust char_start 精确还原章节与章内偏移
          final char = (loc['char'] as num?)?.toInt();
          if (char != null) {
            var idx = 0;
            for (var i = 0; i < parsed.chapters.length; i++) {
              if (parsed.chapters[i].charStart <= char) idx = i;
            }
            chapter = idx.clamp(0, parsed.chapters.length - 1);
            final start = parsed.chapters[chapter].charStart;
            final len = parsed.chapters[chapter].plain.length;
            fraction = len <= 0 ? 0.0 : ((char - start) / len).clamp(0.0, 1.0);
          } else {
            chapter = ((loc['chapter'] as num?)?.toInt() ?? 0)
                .clamp(0, parsed.chapters.length - 1);
            fraction = (loc['fraction'] as num?)?.toDouble() ?? 0.0;
          }
        }
      }

      setState(() {
        _row = row;
        _localPath = path;
        _book = parsed;
        _chapter = chapter;
        _loading = false;
        _error = null;
      });

      // 图片书没有文本章节（chapters 可能为空），走不到 ContentParser 那条管线。
      if (!parsed.isImageBook) {
        await _prepareChapter(scrollTo: fraction);
      }
    } catch (e) {
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  Future<void> _prepareChapter({double? scrollTo}) async {
    final book = _book;
    if (book == null || book.chapters.isEmpty) return;
    _chapter = _chapter.clamp(0, book.chapters.length - 1);
    final ch = book.chapters[_chapter];
    final ruleSet = ref.read(ruleSetProvider);
    final key = '${widget.bookId}/$_chapter@${ruleSet.hash}';

    final cached = _cache.get(key);
    final blocks = cached ?? ContentParser.parse(ch.xhtml);
    if (cached == null) _cache.put(key, blocks);

    setState(() => _blocks = blocks);

    if (scrollTo != null && scrollTo > 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_scroll.hasClients) return;
        _scroll.jumpTo(_scroll.position.maxScrollExtent * scrollTo.clamp(0.0, 1.0));
      });
    }
  }

  void _onScroll() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _saveProgress);
  }

  /// 保存进度。
  ///
  /// 文本书：除了精确的 chapter + 滚动比例，还额外写 **anchor 指纹**（当前视口第一段文字），
  /// 当对端本地文件版本与写入方不同（重新导入 / 字体不同 / 屏幕宽度不同）时，
  /// 用 anchor 在 ±5% 窗口内做模糊重定位。图片书：按 `page_index` 存。
  Future<void> _saveProgress() async {
    final book = _book;
    final row = _row;
    if (book == null || row == null) return;

    final db = ref.read(databaseProvider);
    final clock = await ref.read(hlcClockProvider.future);
    final deviceId = await ref.read(deviceIdProvider.future);
    final hlc = clock.tick();

    final payload = <String, dynamic>{};
    double percent;
    int charOffset;
    String anchorBefore;

    if (book.isImageBook) {
      // 图片书：按 page_index 记录
      final pages = book.pages ?? const [];
      final total = pages.length;
      percent = total <= 1 ? (_page == 0 ? 0.0 : 1.0) : (_page / (total - 1)).clamp(0.0, 1.0);
      charOffset = _page;
      anchorBefore = '';
      payload['locatorJson'] = jsonEncode({
        'v': 1,
        'kind': book.format.name,
        'page': _page,
        'fraction': percent,
      });
    } else {
      // 文本书：chapter + 滚动比例 + 全局字符偏移 + anchor 指纹
      if (!_scroll.hasClients) return;
      final max = _scroll.position.maxScrollExtent;
      final fraction = max <= 0 ? 0.0 : (_scroll.offset / max).clamp(0.0, 1.0);

      var beforeChars = 0;
      for (var i = 0; i < _chapter && i < book.chapters.length; i++) {
        beforeChars += book.chapters[i].plain.length;
      }
      final chapterChars = _chapter < book.chapters.length
          ? book.chapters[_chapter].plain.length
          : 0;
      charOffset = beforeChars + (chapterChars * fraction).round();
      final total = book.chapters.fold<int>(0, (s, c) => s + c.plain.length);
      percent = total == 0 ? 0.0 : (charOffset / total).clamp(0.0, 1.0);

      final blocks = _blocks ?? const <ContentBlock>[];
      final visibleText = blocks.isNotEmpty ? blocks.first.plainText : '';
      anchorBefore = visibleText.length > 32 ? visibleText.substring(0, 32) : visibleText;

      payload['locatorJson'] = jsonEncode({
        'v': 1,
        'kind': book.format.name,
        'chapter': _chapter,
        'fraction': fraction,
        'char': charOffset,
      });
    }

    payload['percent'] = percent;
    payload['charOffset'] = charOffset;
    payload['anchorBefore'] = anchorBefore;
    payload['anchorAfter'] = '';
    payload['forced'] = false; // 拖动进度条 / 目录跳转时置 true，避免被另一端的"更远进度"盖掉
    payload['updatedAt'] = DateTime.now().toUtc().toIso8601String();
    payload['hlc'] = hlc.encode();
    payload['updatedBy'] = deviceId;
    payload['bookId'] = widget.bookId;

    await db
        .into(db.progresses)
        .insertOnConflictUpdate(ProgressesCompanion.insert(
          bookId: widget.bookId,
          locatorJson: payload['locatorJson'] as String,
          percent: percent,
          charOffset: charOffset,
          anchorBefore: anchorBefore,
          forced: false,
          hlc: hlc.encode(),
          updatedBy: deviceId,
          updatedAt: DateTime.now().toUtc(),
        ));

    await db.into(db.outbox).insert(OutboxCompanion.insert(
          entityType: 'progress',
          entityId: widget.bookId,
          op: 'upsert',
          payloadJson: jsonEncode(payload),
          hlc: hlc.encode(),
        ));

    ref.read(syncTriggerProvider.notifier).markDirty();
  }

  /// 图片书跳页。PageController 只在 _buildComic 里创建，可能还没挂上。
  Future<void> _gotoPage(int index) async {
    final book = _book;
    if (book == null) return;
    final total = book.pages?.length ?? 0;
    if (total == 0) return;
    final target = index.clamp(0, total - 1);
    if (target == _page) return;
    setState(() => _page = target);
    final c = _pageController;
    if (c != null && c.hasClients) c.jumpToPage(target);
    await _saveProgress();
  }

  Future<void> _gotoChapter(int index) async {
    final book = _book;
    if (book == null) return;
    setState(() {
      _chapter = index.clamp(0, book.chapters.length - 1);
      _blocks = null;
    });
    await _prepareChapter();
    if (_scroll.hasClients) _scroll.jumpTo(0);
    await _saveProgress();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(),
        body: Center(child: Text(_error!)),
      );
    }
    final book = _book!;

    final pageCount = book.pages?.length ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: Text(book.chapters.isEmpty
            ? book.title
            : book.chapters[_chapter].title),
        actions: [
          if (book.chapters.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.list),
              onPressed: _showToc,
            ),
          IconButton(
            icon: const Icon(Icons.palette),
            tooltip: '高亮规则',
            onPressed: () => Navigator.of(context).pushNamed('/rules'),
          ),
        ],
      ),
      body: book.isImageBook ? _buildComic(book) : _buildText(),
      bottomNavigationBar: book.isImageBook
          ? (pageCount <= 1
              ? null
              : SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Slider(
                            value: _page.clamp(0, pageCount - 1).toDouble(),
                            min: 0,
                            max: (pageCount - 1).toDouble(),
                            divisions: pageCount - 1,
                            label: '第 ${_page + 1} 页',
                            onChanged: (v) => _gotoPage(v.round()),
                          ),
                        ),
                        Text('${_page + 1}/$pageCount'),
                      ],
                    ),
                  ),
                ))
          : SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: _chapter.toDouble(),
                        min: 0,
                        max: (book.chapters.length - 1).clamp(0, 1e9).toDouble(),
                        divisions: book.chapters.length > 1 ? book.chapters.length - 1 : null,
                        label: '第 ${_chapter + 1} 章',
                        onChanged: (v) => _gotoChapter(v.round()),
                      ),
                    ),
                    Text('${_chapter + 1}/${book.chapters.length}'),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildText() {
    final blocks = _blocks;
    if (blocks == null) return const Center(child: CircularProgressIndicator());
    final ruleSet = ref.watch(ruleSetProvider);
    final renderer = HighlightRenderer(engine: const RuleEngine(), ruleSet: ruleSet);
    final base = Theme.of(context).textTheme.bodyLarge!.copyWith(
          height: 1.8,
          fontSize: ref.watch(fontSizeProvider),
          fontFamily: 'SourceHanSerif',
        );

    return Scrollbar(
      controller: _scroll,
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 48),
        itemCount: blocks.length,
        itemBuilder: (context, i) {
          final b = blocks[i];
          final style = switch (b.kind) {
            BlockKind.heading => base.copyWith(
                fontSize: base.fontSize! + (6 - b.level).clamp(1, 4).toDouble() * 2.0,
                fontWeight: FontWeight.w700,
              ),
            BlockKind.quote => base.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
                fontStyle: FontStyle.italic,
              ),
            BlockKind.separator => base,
            BlockKind.paragraph => base,
          };
          if (b.kind == BlockKind.separator) {
            return const Divider();
          }
          return Padding(
            padding: EdgeInsets.only(
              top: b.kind == BlockKind.heading ? 18 : 0,
              bottom: 10,
            ),
            child: RichText(
              text: TextSpan(
                style: style,
                children: renderer.buildBlock(
                  b,
                  style,
                  imageSpan: (src) => WidgetSpan(
                    alignment: PlaceholderAlignment.middle,
                    child: _InlineImage(bookPath: _localPath!, entry: src),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 漫画模式：CBZ / PDF / 图片型 EPUB / MOBI 图片书走分页浏览，按 `page_index` 存进度。
  Widget _buildComic(ParsedBook book) {
    final pages = book.pages ?? const [];
    if (pages.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(24),
          child: Text('该书没有可用的页面', textAlign: TextAlign.center),
        ),
      );
    }

    // PDF 漫画书：页序是「页码」（`book.pages` 形如 `["0","1",...]`），不是 zip 内路径，
    // 不能进 `_InlineImage` 的 zip 通道（否则 `readInternalImage` 打开 zip 失败 → 裂图）。
    // 这里直接用 pdfrx 按文件路径打开、按页渲染，复用外层进度滑块
    // （`pageCount` 来自 `book.pages` 长度，与 `_gotoPage`/`_saveProgress` 完全兼容）。
    if (book.format == BookFormatDart.pdf) {
      final controller = _pageController ??= PageController(
        initialPage: _page.clamp(0, pages.length - 1),
      );
      return _PdfBook(
        path: _localPath!,
        controller: controller,
        onPageChanged: (i) {
          setState(() => _page = i);
          _saveProgress();
        },
      );
    }

    final controller = _pageController ??= PageController(
      initialPage: _page.clamp(0, (pages.length - 1).clamp(0, 1 << 30)),
    );
    return PageView.builder(
      controller: controller,
      itemCount: pages.length,
      onPageChanged: (i) {
        setState(() => _page = i);
        _saveProgress();
      },
      itemBuilder: (context, i) => _InlineImage(
        bookPath: _localPath!,
        entry: pages[i],
        fit: BoxFit.contain,
      ),
    );
  }

  void _showToc() {
    final book = _book!;
    showModalBottomSheet<void>(
      context: context,
      builder: (_) => ListView.builder(
        itemCount: book.chapters.length,
        itemBuilder: (context, i) => ListTile(
          selected: i == _chapter,
          title: Text(
            book.chapters[i].title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () {
            Navigator.pop(context);
            _gotoChapter(i);
          },
        ),
      ),
    );
  }
}

/// PDF 漫画书分页渲染。
///
/// PDF 的页序是「页码」（`book.pages` 形如 `["0","1",...]`），不是 zip 内路径，
/// 所以不能用 `_InlineImage`（它走 `readInternalImage` 的 zip 通道）。这里直接用
/// pdfrx 按文件路径打开、按页渲染，复用外层进度滑块（`pageCount` 来自 `book.pages`
/// 长度，与 `_gotoPage`/`_saveProgress` 完全兼容）。
///
/// 构建环境要求：Windows 需开 Developer Mode（pdfrx 用符号链接）、UOS 需带 PDFium
/// 共享库——这些是打包环境限制，不影响此 widget 逻辑。
class _PdfBook extends StatelessWidget {
  const _PdfBook({
    required this.path,
    required this.controller,
    required this.onPageChanged,
  });

  final String path;
  final PageController controller;
  final void Function(int page) onPageChanged;

  @override
  Widget build(BuildContext context) {
    return PdfDocumentViewBuilder.file(
      path,
      builder: (context, document) {
        if (document == null) {
          return const Center(child: CircularProgressIndicator());
        }
        return PageView.builder(
          controller: controller,
          itemCount: document.pages.length,
          onPageChanged: onPageChanged,
          itemBuilder: (context, i) => PdfPageView(
            document: document,
            pageNumber: i + 1,
            alignment: Alignment.center,
          ),
        );
      },
    );
  }
}

/// 从 EPUB/CBZ 容器内按需取图；MOBI 图片书用 `pdb:<record>` 寻址，走另一条通道。
/// 用 `cacheWidth` 限制解码尺寸 —— 漫画页动辄 3000px，不限制必然 OOM。
class _InlineImage extends ConsumerStatefulWidget {
  const _InlineImage({
    required this.bookPath,
    required this.entry,
    this.fit = BoxFit.cover,
  });

  final String bookPath;
  final String entry;
  final BoxFit fit;

  @override
  ConsumerState<_InlineImage> createState() => _InlineImageState();
}

class _InlineImageState extends ConsumerState<_InlineImage> {
  /// MOBI 图片书的页地址形如 `pdb:12`，指 PalmDOC record 序号，不是 zip 内路径。
  static const _pdbPrefix = 'pdb:';

  Future<Uint8List?>? _future;
  String? _loadedEntry;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loadedEntry == widget.entry && _future != null) return;
    _loadedEntry = widget.entry;
    _future = _load(widget.entry);
  }

  @override
  void didUpdateWidget(_InlineImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // PageView 复用 State，entry 变了必须重新取图，否则整本书都停在第一页。
    if (oldWidget.entry != widget.entry || oldWidget.bookPath != widget.bookPath) {
      _loadedEntry = widget.entry;
      setState(() => _future = _load(widget.entry));
    }
  }

  Future<Uint8List?> _load(String entry) {
    final core = ref.read(nativeCoreProvider);
    if (entry.startsWith(_pdbPrefix)) {
      final record = int.tryParse(entry.substring(_pdbPrefix.length));
      if (record == null) return Future.value(null);
      return core.readMobiImage(widget.bookPath, record);
    }
    return core.readInternalImage(widget.bookPath, entry);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const SizedBox(
            height: 40,
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        final bytes = snap.data;
        if (bytes == null || bytes.isEmpty) {
          return const SizedBox(
            height: 40,
            child: Center(child: Icon(Icons.broken_image_outlined)),
          );
        }
        return Image.memory(
          bytes,
          fit: widget.fit,
          cacheWidth: 1600,
          gaplessPlayback: true,
        );
      },
    );
  }
}

final fontSizeProvider = StateProvider<double>((ref) => 17.0);
