import 'dart:typed_data';

/// 原生解析核心的 Dart 侧接口。
///
/// 真正的实现由 `flutter_rust_bridge` 生成的绑定注入（`CallbackNativeCore`），
/// 这样本文件不依赖生成产物、永远可编译；
/// 万一 UOS 是非 x86 架构需要换成 Qt UI，Rust 核心（含解析与同步）可 100% 复用。

enum BookFormatDart { epub, txt, mobi, azw3, pdf, cbz, cbr, unknown }

class RawChapter {
  RawChapter({
    required this.index,
    required this.title,
    required this.xhtml,
    required this.plain,
    this.charStart = 0,
    this.spineHref,
  });

  final int index;
  final String title;

  /// 归一化 XHTML，只含 `p / h1-h6 / blockquote / em / strong / br / hr / img`
  final String xhtml;

  /// 纯文本（搜索、进度估算）
  final String plain;

  /// 该章在「所有章节 plain 顺序拼接」视图中的起始字符偏移（来自 Rust `char_start`）。
  /// 进度恢复用于精确章节定位，漫画/图片书无意义填 0。
  final int charStart;

  /// spine 内路径（EPUB 为 OPF 相对路径；TXT/MOBI 文本书为 null）。
  final String? spineHref;
}

class ParsedBook {
  ParsedBook({
    required this.format,
    required this.title,
    required this.authors,
    required this.chapters,
    required this.sha256,
    this.subtitle,
    this.publisher,
    this.language,
    this.description,
    this.series,
    this.seriesIndex,
    this.tags = const [],
    this.totalChars = 0,
    this.fileSize = 0,
    this.coverBytes,
    this.coverMime,
    this.pages,
    this.isImageBook = false,
  });

  final BookFormatDart format;
  final String title;
  final List<String> authors;
  final List<RawChapter> chapters;
  final String sha256;

  // ── 导入时写进 books 表的元数据 ──
  final String? subtitle;
  final String? publisher;
  final String? language;
  final String? description;
  final String? series;
  final double? seriesIndex;
  final List<String> tags;

  /// 全书字符数（Rust `total_chars`），用于进度百分比与"字数"展示。
  final int totalChars;

  /// 原文件字节数（Rust `file_size`），书架按大小排序用。
  final int fileSize;

  final Uint8List? coverBytes;
  final String? coverMime;

  /// 漫画页序（zip 内路径 / 页码）；文本格式为 null
  final List<String>? pages;

  /// 是否图片书（漫画 / 扫描 PDF / 图片型 EPUB / MOBI 图片书）。
  /// 来自 Rust `is_image_book`，决定阅读器走分页浏览还是文本流。
  /// `isComic` 仅作格式判断辅助（cbz/cbr/pdf），不覆盖图片型 EPUB/MOBI。
  final bool isImageBook;

  bool get isComic => format == BookFormatDart.cbz ||
      format == BookFormatDart.cbr ||
      format == BookFormatDart.pdf;
}

abstract class NativeCore {
  /// 解析整本书（阅读器用）。**不含封面字节** —— 封面在导入时已落盘。
  Future<ParsedBook> parseBook(String path);

  /// 只抽元数据 + 封面（导入用，避免为了拿书名解析整本大书）。**含封面字节**。
  Future<ParsedBook> probeBook(String path);

  /// 从 EPUB/CBZ 容器内读取图片（渲染章节里的插图、漫画页）
  Future<Uint8List?> readInternalImage(String path, String entry);

  /// 读取 MOBI/AZW3 图片书的一页，`record` 对应 `pages` 里的 `pdb:<index>`。
  Future<Uint8List?> readMobiImage(String path, int record);

  Future<String> sha256File(String path);
}

class UnimplementedNativeCore implements NativeCore {
  @override
  Future<ParsedBook> parseBook(String path) =>
      throw UnsupportedError('未注入原生核心，请在 main() 里通过 CallbackNativeCore 注入');

  @override
  Future<ParsedBook> probeBook(String path) =>
      throw UnsupportedError('未注入原生核心，请在 main() 里通过 CallbackNativeCore 注入');

  @override
  Future<Uint8List?> readInternalImage(String path, String entry) => throw UnsupportedError('未注入原生核心');

  @override
  Future<Uint8List?> readMobiImage(String path, int record) => throw UnsupportedError('未注入原生核心');

  @override
  Future<String> sha256File(String path) => throw UnsupportedError('未注入原生核心');
}

typedef ParseBookFn = Future<Map<String, dynamic>> Function(String path);
typedef ReadImageFn = Future<Uint8List?> Function(String path, String entry);
typedef MobiImageFn = Future<Uint8List?> Function(String path, int record);
typedef Sha256Fn = Future<String> Function(String path);

/// 注入式实现：把 flutter_rust_bridge 生成的函数传进来即可。
///
/// **不依赖生成类的字段名** —— Rust 侧 `parse_book_json` / `probe_book_json`
/// 返回 JSON 字符串，这里只认 `core/src/api.rs` 里 serde 契约定义的键。
/// frb 升级导致生成类改名时，只需改 main.dart 里那两行函数名。
///
/// 用法（在 main() 里）：
/// ```dart
/// final core = CallbackNativeCore(
///   parse: (p) async => jsonDecode(await InksyncCore.parseBookJson(path: p)) as Map<String, dynamic>,
///   probe: (p) async => jsonDecode(await InksyncCore.probeBookJson(path: p)) as Map<String, dynamic>,
///   image: (p, e) async => Uint8List.fromList(await InksyncCore.readInternalImage(path: p, entry: e)),
///   mobi:  (p, r) async => Uint8List.fromList(await InksyncCore.readMobiImage(path: p, record: r)),
///   hash:  (p) async => await InksyncCore.sha256File(path: p),
/// );
/// ```
class CallbackNativeCore implements NativeCore {
  CallbackNativeCore({
    required this.parse,
    this.probe,
    this.image,
    this.mobi,
    this.hash,
  });

  final ParseBookFn parse;
  final ParseBookFn? probe;
  final ReadImageFn? image;
  final MobiImageFn? mobi;
  final Sha256Fn? hash;

  @override
  Future<ParsedBook> parseBook(String path) async => _fromJson(await parse(path));

  /// 没注入 probe 时退化为 parse（能用，只是慢一点：多解析了正文）。
  @override
  Future<ParsedBook> probeBook(String path) async =>
      _fromJson(await (probe ?? parse)(path));

  static ParsedBook _fromJson(Map<String, dynamic> m) {
    final meta = (m['meta'] as Map?)?.cast<String, dynamic>() ?? const {};
    final chapters = (m['chapters'] as List<dynamic>? ?? const [])
        .map((c) => RawChapter(
              index: (c['index'] as num?)?.toInt() ?? 0,
              title: c['title'] as String? ?? '',
              xhtml: c['xhtml'] as String? ?? '',
              plain: c['plain'] as String? ?? '',
              charStart: (c['charStart'] as num?)?.toInt() ?? 0,
              spineHref: c['spineHref'] as String?,
            ))
        .toList();

    // parse_book_json 里 cover.data 恒为空数组（封面在导入时已落盘），
    // 只有 probe_book_json 才带字节 —— 空数组要还原成 null，别塞个 0 长度 Uint8List。
    final cover = (m['cover'] as Map?)?.cast<String, dynamic>();
    final coverData = (cover?['data'] as List?)?.cast<int>();
    final hasCoverBytes = coverData != null && coverData.isNotEmpty;

    return ParsedBook(
      format: BookFormatDart.values.firstWhere(
        (f) => f.name == (m['format'] as String? ?? 'unknown'),
        orElse: () => BookFormatDart.unknown,
      ),
      title: meta['title'] as String? ?? '',
      authors: (meta['authors'] as List<dynamic>? ?? const [])
          .map((a) => a.toString())
          .toList(),
      subtitle: _blankToNull(meta['subtitle'] as String?),
      publisher: _blankToNull(meta['publisher'] as String?),
      language: _blankToNull(meta['language'] as String?),
      description: _blankToNull(meta['description'] as String?),
      series: _blankToNull(meta['series'] as String?),
      seriesIndex: (meta['seriesIndex'] as num?)?.toDouble(),
      tags: (meta['tags'] as List<dynamic>? ?? const [])
          .map((t) => t.toString())
          .where((t) => t.isNotEmpty)
          .toList(),
      chapters: chapters,
      sha256: m['sha256'] as String? ?? '',
      totalChars: (m['totalChars'] as num?)?.toInt() ?? 0,
      fileSize: (m['fileSize'] as num?)?.toInt() ?? 0,
      coverBytes: hasCoverBytes ? Uint8List.fromList(coverData) : null,
      coverMime: cover?['mime'] as String?,
      pages: (m['pages'] as List<dynamic>?)?.map((e) => e.toString()).toList(),
      isImageBook: m['isImageBook'] as bool? ?? false,
    );
  }

  static String? _blankToNull(String? s) =>
      (s == null || s.trim().isEmpty) ? null : s;

  @override
  Future<Uint8List?> readInternalImage(String path, String entry) =>
      image == null ? throw UnsupportedError('未注入 image') : image!(path, entry);

  @override
  Future<Uint8List?> readMobiImage(String path, int record) =>
      mobi == null ? throw UnsupportedError('未注入 mobi') : mobi!(path, record);

  @override
  Future<String> sha256File(String path) =>
      hash == null ? throw UnsupportedError('未注入 hash') : hash!(path);
}
