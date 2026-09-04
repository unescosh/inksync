/// 极简 XHTML 解析器。
///
/// 输入是 Rust 核心 `formats::sanitize()` 的输出，**保证标签闭合且只含白名单标签**
/// （`p / h1-h6 / blockquote / em / strong / br / hr / img`），
/// 所以这里不需要处理任意 HTML 的容错，用一个轻量状态机即可，
/// 比引入完整 HTML 解析库快一个数量级。
library;

enum BlockKind { paragraph, heading, quote, separator }

sealed class InlineNode {}

class TextNode extends InlineNode {
  TextNode(this.text);
  final String text;
}

class ImageNode extends InlineNode {
  ImageNode(this.src);
  /// zip 内相对路径（EPUB）或页码索引（PDF）
  final String src;
}

class BreakNode extends InlineNode {}

class StyleNode extends InlineNode {
  StyleNode({required this.bold, required this.italic, required this.children});
  final bool bold;
  final bool italic;
  final List<InlineNode> children;
}

class ContentBlock {
  ContentBlock({
    required this.kind,
    this.level = 0,
    this.inlines = const <InlineNode>[],
  });

  final BlockKind kind;
  /// heading 层级 1~6；其余为 0
  final int level;
  final List<InlineNode> inlines;

  /// 块的纯文本（搜索、进度 anchor、字数统计都用它）
  String get plainText {
    final sb = StringBuffer();
    void walk(List<InlineNode> nodes) {
      for (final n in nodes) {
        switch (n) {
          case TextNode(:final text):
            sb.write(text);
          case BreakNode():
            sb.write('\n');
          case ImageNode():
            sb.write('[图片]');
          case StyleNode(:final children):
            walk(children);
        }
      }
    }

    walk(inlines);
    return sb.toString();
  }
}

class ContentParser {
  ContentParser._();

  static final RegExp _tag =
      RegExp(r'<(/?)([a-zA-Z0-9]+)([^>]*?)(/?)>', caseSensitive: false);
  static final RegExp _srcAttr = RegExp(r'src="([^"]*)"');
  static const _headings = <String>{'h1', 'h2', 'h3', 'h4', 'h5', 'h6'};

  static List<ContentBlock> parse(String xhtml) {
    final blocks = <ContentBlock>[];
    final frames = <_Frame>[];
    BlockKind kind = BlockKind.paragraph;
    var level = 0;
    var started = false;

    List<InlineNode> startBlock() {
      final list = <InlineNode>[];
      frames
        ..clear()
        ..add(_Frame.root(list));
      started = true;
      return list;
    }

    void ensureStarted() {
      if (!started) startBlock();
    }

    void flush() {
      if (!started) return;
      while (frames.length > 1) {
        _popFrame(frames);
      }
      final list = frames.last.children;
      if (list.isNotEmpty) {
        blocks.add(ContentBlock(kind: kind, level: level, inlines: list));
      }
      frames.clear();
      started = false;
    }

    var pos = 0;
    for (final m in _tag.allMatches(xhtml)) {
      if (m.start > pos) {
        final text = _decode(xhtml.substring(pos, m.start));
        if (text.isNotEmpty) {
          ensureStarted();
          frames.last.children.add(TextNode(text));
        }
      }
      pos = m.end;

      final closing = m.group(1) == '/';
      final tag = (m.group(2) ?? '').toLowerCase();
      final attrs = m.group(3) ?? '';

      if (closing) {
        if (_headings.contains(tag) || tag == 'p' || tag == 'blockquote') {
          flush();
        } else if ((tag == 'em' || tag == 'strong') && frames.length > 1) {
          _popFrame(frames);
        }
        continue;
      }

      switch (tag) {
        case 'p':
          flush();
          kind = BlockKind.paragraph;
          level = 0;
          startBlock();
        case 'blockquote':
          flush();
          kind = BlockKind.quote;
          level = 0;
          startBlock();
        case 'br':
          ensureStarted();
          frames.last.children.add(BreakNode());
        case 'hr':
          flush();
          blocks.add(ContentBlock(kind: BlockKind.separator));
        case 'img':
          final sm = _srcAttr.firstMatch(attrs);
          if (sm != null) {
            ensureStarted();
            frames.last.children.add(ImageNode(sm.group(1)!));
          }
        case 'em':
          ensureStarted();
          frames.add(_Frame(bold: false, italic: true));
        case 'strong':
          ensureStarted();
          frames.add(_Frame(bold: true, italic: false));
        default:
          if (_headings.contains(tag)) {
            flush();
            kind = BlockKind.heading;
            level = int.tryParse(tag.substring(1)) ?? 2;
            startBlock();
          }
      }
    }

    if (pos < xhtml.length) {
      final text = _decode(xhtml.substring(pos));
      if (text.isNotEmpty) {
        ensureStarted();
        frames.last.children.add(TextNode(text));
      }
    }
    flush();

    return blocks;
  }

  static void _popFrame(List<_Frame> frames) {
    final f = frames.removeLast();
    final parent = frames.last;
    if (f.bold || f.italic) {
      parent.children
          .add(StyleNode(bold: f.bold, italic: f.italic, children: f.children));
    } else {
      parent.children.addAll(f.children);
    }
  }

  static String _decode(String s) {
    if (!s.contains('&')) return s;
    return s
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&amp;', '&');
  }
}

class _Frame {
  _Frame({required this.bold, required this.italic}) : children = <InlineNode>[];

  _Frame.root(this.children) : bold = false, italic = false;

  final bool bold;
  final bool italic;
  final List<InlineNode> children;
}
