import 'package:flutter/material.dart';

import 'content.dart';
import 'rules.dart';

/// 把 [ContentBlock] 渲染成带自定义高亮的 [InlineSpan]。
///
/// 规则匹配发生在**每个 TextNode 叶子**上（而不是整章拼成一个大字符串），
/// 这样 `<em>` / `<strong>` 的样式边界不会被规则切碎，
/// 也保证高亮区间不会跨块（书名号不会跨段落匹配）。
class HighlightRenderer {
  const HighlightRenderer({required this.engine, required this.ruleSet});

  final RuleEngine engine;
  final RuleSet ruleSet;

  bool get enabled => !ruleSet.isEmpty;

  List<InlineSpan> buildBlock(
    ContentBlock block,
    TextStyle base, {
    required InlineSpan Function(String src) imageSpan,
  }) {
    return _walk(block.inlines, base, imageSpan);
  }

  List<InlineSpan> _walk(
    List<InlineNode> nodes,
    TextStyle base,
    InlineSpan Function(String src) imageSpan,
  ) {
    final out = <InlineSpan>[];
    for (final n in nodes) {
      switch (n) {
        case TextNode(:final text):
          out.addAll(_textSpans(text, base));
        case BreakNode():
          out.add(const TextSpan(text: '\n'));
        case ImageNode(:final src):
          out.add(imageSpan(src));
        case StyleNode(:final bold, :final italic, :final children):
          out.addAll(
            _walk(
              children,
              base.copyWith(
                fontWeight: bold ? FontWeight.bold : base.fontWeight,
                fontStyle: italic ? FontStyle.italic : base.fontStyle,
              ),
              imageSpan,
            ),
          );
      }
    }
    return out;
  }

  List<InlineSpan> _textSpans(String text, TextStyle base) {
    final segments = engine.match(text, ruleSet);
    if (segments.isEmpty) {
      return [TextSpan(text: text, style: base)];
    }

    final out = <InlineSpan>[];
    var cursor = 0;
    for (final s in segments) {
      if (s.start > cursor) {
        out.add(TextSpan(text: text.substring(cursor, s.start), style: base));
      }
      final rule = ruleSet.byId[s.ruleId];
      out.add(
        TextSpan(
          text: text.substring(s.start, s.end),
          style: base.merge(_styleOf(rule, base)),
        ),
      );
      cursor = s.end;
    }
    if (cursor < text.length) {
      out.add(TextSpan(text: text.substring(cursor), style: base));
    }
    return out;
  }

  TextStyle _styleOf(HighlightRule? rule, TextStyle base) {
    if (rule == null) return base;
    return TextStyle(
      color: Color(rule.colorValue),
      fontWeight: rule.bold ? FontWeight.w700 : base.fontWeight,
      fontStyle: rule.italic ? FontStyle.italic : base.fontStyle,
      decoration: rule.underline ? TextDecoration.underline : base.decoration,
      // 直接用 backgroundColor 最简单且跨端一致；
      // 若要圆角底色，可改用 base.copyWith(background: Paint()..color=...)，
      // 但三端 Skia 版本差异下圆角绘制需额外自绘，这里刻意保持简单。
      backgroundColor: Color(rule.bgColorValue).withOpacity(rule.bgOpacity),
    );
  }
}

/// 章节级结果缓存。
/// key = `${bookId}/${chapterIndex}@${ruleSetHash}`，规则、字号、宽度任一变化即失效。
class SpanCache {
  SpanCache({this.maxEntries = 30});

  final int maxEntries;
  final Map<String, List<ContentBlock>> _blocks = {};
  final List<String> _lru = [];

  List<ContentBlock>? get(String key) {
    final v = _blocks[key];
    if (v != null) {
      _lru
        ..remove(key)
        ..add(key);
    }
    return v;
  }

  void put(String key, List<ContentBlock> value) {
    _blocks[key] = value;
    _lru
      ..remove(key)
      ..add(key);
    while (_lru.length > maxEntries) {
      _blocks.remove(_lru.removeAt(0));
    }
  }

  void invalidate({String? bookId}) {
    if (bookId == null) {
      _blocks.clear();
      _lru.clear();
      return;
    }
    final keys = _blocks.keys.where((k) => k.startsWith('$bookId/')).toList();
    for (final k in keys) {
      _blocks.remove(k);
      _lru.remove(k);
    }
  }
}
