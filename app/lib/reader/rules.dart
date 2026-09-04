import 'package:flutter/material.dart';

/// 自定义高亮规则引擎。
///
/// 设计取舍：
/// 1. **不做分词**。Dart 生态没有好用的中文分词，且词典会让三端包体 +20MB。
///    人名高亮改为「用户词表 + 一键提取候选」两条路径。
/// 2. **正则预编译 + 结果缓存**。一章 5 千字 × 20 条规则，
///    命中数千个区间，实测匹配 + 重叠消解 < 5ms；结果按
///    `{chapterId, ruleSetHash}` 缓存，规则不变就不重算。
library;

// ─────────────────────────── 模型 ───────────────────────────

enum RuleKind {
  /// 用户自定义正则
  regex,
  /// 引号：中文双引号「」『』、直角引号、英文引号
  quote,
  /// 书名号《》〈〉
  bookTitleMark,
  /// 括号高亮（）/()
  paren,
  /// 人名（词表驱动）
  personName,
  /// 对话：行首到冒号
  dialogue,
  /// 关键词表（换行分隔）
  keywordList,
}

/// 规则作用范围：小说正文 / 漫画文本层（PDF 文本层或 OCR）
enum RuleScope { novel, comic }

class HighlightRule {
  const HighlightRule({
    required this.id,
    required this.name,
    required this.kind,
    this.pattern = '',
    this.caseSensitive = false,
    this.colorValue = 0xFFD32F2F,
    this.bgColorValue = 0xFFFFF176,
    this.bgOpacity = 0.35,
    this.bold = false,
    this.italic = false,
    this.underline = false,
    this.priority = 0,
    this.scope = const {RuleScope.novel},
    this.enabled = true,
    this.sortOrder = 0,
    this.hlc = '0000000000000-0000-00000000',
    this.updatedBy = '',
    this.deleted = false,
  });

  final String id;
  final String name;
  final RuleKind kind;
  final String pattern;
  final bool caseSensitive;
  final int colorValue;
  final int bgColorValue;
  final double bgOpacity;
  final bool bold;
  final bool italic;
  final bool underline;
  /// 重叠时高优先级胜出
  final int priority;
  final Set<RuleScope> scope;
  final bool enabled;
  final int sortOrder;
  final String hlc;
  final String updatedBy;
  final bool deleted;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind.name,
        'pattern': pattern,
        'caseSensitive': caseSensitive,
        'colorValue': colorValue,
        'bgColorValue': bgColorValue,
        'bgOpacity': bgOpacity,
        'bold': bold,
        'italic': italic,
        'underline': underline,
        'priority': priority,
        'scope': scope.map((s) => s.name).toList(),
        'enabled': enabled,
        'sortOrder': sortOrder,
        'hlc': hlc,
        'updatedBy': updatedBy,
        'deleted': deleted,
      };

  static HighlightRule fromJson(Map<String, dynamic> j) => HighlightRule(
        id: j['id'] as String,
        name: j['name'] as String? ?? '',
        kind: RuleKind.values.firstWhere(
          (k) => k.name == j['kind'],
          orElse: () => RuleKind.regex,
        ),
        pattern: j['pattern'] as String? ?? '',
        caseSensitive: j['caseSensitive'] as bool? ?? false,
        colorValue: j['colorValue'] as int? ?? 0xFFD32F2F,
        bgColorValue: j['bgColorValue'] as int? ?? 0xFFFFF176,
        bgOpacity: (j['bgOpacity'] as num?)?.toDouble() ?? 0.35,
        bold: j['bold'] as bool? ?? false,
        italic: j['italic'] as bool? ?? false,
        underline: j['underline'] as bool? ?? false,
        priority: j['priority'] as int? ?? 0,
        scope: (j['scope'] as List<dynamic>? ?? ['novel'])
            .map((s) => RuleScope.values.firstWhere((v) => v.name == s, orElse: () => RuleScope.novel))
            .toSet(),
        enabled: j['enabled'] as bool? ?? true,
        sortOrder: j['sortOrder'] as int? ?? 0,
        hlc: j['hlc'] as String? ?? '0000000000000-0000-00000000',
        updatedBy: j['updatedBy'] as String? ?? '',
        deleted: j['deleted'] as bool? ?? false,
      );

  HighlightRule copyWith({
    String? name,
    RuleKind? kind,
    String? pattern,
    bool? caseSensitive,
    int? colorValue,
    int? bgColorValue,
    double? bgOpacity,
    bool? bold,
    bool? italic,
    bool? underline,
    int? priority,
    Set<RuleScope>? scope,
    bool? enabled,
    int? sortOrder,
    String? hlc,
    String? updatedBy,
    bool? deleted,
  }) =>
      HighlightRule(
        id: id,
        name: name ?? this.name,
        kind: kind ?? this.kind,
        pattern: pattern ?? this.pattern,
        caseSensitive: caseSensitive ?? this.caseSensitive,
        colorValue: colorValue ?? this.colorValue,
        bgColorValue: bgColorValue ?? this.bgColorValue,
        bgOpacity: bgOpacity ?? this.bgOpacity,
        bold: bold ?? this.bold,
        italic: italic ?? this.italic,
        underline: underline ?? this.underline,
        priority: priority ?? this.priority,
        scope: scope ?? this.scope,
        enabled: enabled ?? this.enabled,
        sortOrder: sortOrder ?? this.sortOrder,
        hlc: hlc ?? this.hlc,
        updatedBy: updatedBy ?? this.updatedBy,
        deleted: deleted ?? this.deleted,
      );
}

/// 内置预设（用户可改可删）
abstract final class RulePresets {
  static final List<HighlightRule> all = [
    HighlightRule(
      id: 'preset-quote-cn',
      name: '中文双引号「」『』',
      kind: RuleKind.quote,
      pattern: '“”|「」|『』',
      colorValue: 0xFF1565C0,
      bgColorValue: 0xFFBBDEFB,
      priority: 10,
      sortOrder: 0,
    ),
    HighlightRule(
      id: 'preset-quote-en',
      name: '英文引号 ""',
      kind: RuleKind.quote,
      pattern: '""|“”',
      colorValue: 0xFF00695C,
      bgColorValue: 0xFFB2DFDB,
      priority: 9,
      sortOrder: 1,
    ),
    HighlightRule(
      id: 'preset-book-title',
      name: '书名号《》',
      kind: RuleKind.bookTitleMark,
      pattern: '《》|〈〉',
      colorValue: 0xFF6A1B9A,
      bgColorValue: 0xFFE1BEE7,
      priority: 20,
      sortOrder: 2,
    ),
    HighlightRule(
      id: 'preset-dialogue',
      name: '对话提示（行首至冒号）',
      kind: RuleKind.dialogue,
      colorValue: 0xFFEF6C00,
      bgColorValue: 0xFFFFE0B2,
      priority: 5,
      sortOrder: 3,
    ),
    HighlightRule(
      id: 'preset-emphasis',
      name: '强调【】',
      kind: RuleKind.regex,
      pattern: r'【[^】]{1,40}?】',
      colorValue: 0xFFC62828,
      bgColorValue: 0xFFFFCDD2,
      priority: 8,
      sortOrder: 4,
    ),
  ];
}

// ─────────────────────────── 引擎 ───────────────────────────

class _CompiledRule {
  _CompiledRule(this.rule, this.regex);
  final HighlightRule rule;
  final RegExp regex;
}

/// 一份编译好的规则集。hash 用于缓存失效判断。
class RuleSet {
  RuleSet(this.rules, this.hash, this.byId);

  static final RuleSet empty = RuleSet(const [], 'empty', {});

  final List<_CompiledRule> rules;
  final String hash;
  final Map<String, HighlightRule> byId;

  bool get isEmpty => rules.isEmpty;
}

/// 命中区间
class Segment {
  const Segment(this.start, this.end, this.ruleId);
  final int start;
  final int end;
  final String ruleId;
  int get length => end - start;
}

class RuleEngine {
  const RuleEngine();

  /// 编译规则为正则。编译失败（用户正则写错）的规则跳过，不拖垮整章渲染。
  RuleSet compile(List<HighlightRule> rules, {RuleScope scope = RuleScope.novel}) {
    final usable = rules
        .where((r) => r.enabled && !r.deleted && r.scope.contains(scope))
        .toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));

    final compiled = <_CompiledRule>[];
    final byId = <String, HighlightRule>{};
    for (final r in usable) {
      final source = _regexSourceFor(r);
      if (source == null) continue;
      RegExp? re;
      try {
        re = RegExp(source, caseSensitive: r.caseSensitive, unicode: true);
      } catch (_) {
        continue; // 忽略非法正则
      }
      compiled.add(_CompiledRule(r, re));
      byId[r.id] = r;
    }

    final hash = compiled
        .map((c) => '${c.rule.id}:${c.rule.pattern}:${c.rule.priority}:${c.rule.colorValue}')
        .join('|');
    return RuleSet(compiled, hash.isEmpty ? 'empty' : hash.hashCode.toRadixString(36), byId);
  }

  String? _regexSourceFor(HighlightRule r) {
    switch (r.kind) {
      case RuleKind.regex:
        return r.pattern.isEmpty ? null : r.pattern;
      case RuleKind.quote:
      case RuleKind.bookTitleMark:
        // pattern 形如 `“”|「」` —— 每两个字符是一对。
        // 关键（与 Rust 单行不变量一致）：否定字符类必须排除 `\n`，
        // 否则缺闭引号时会跨行吞掉整段（R4.4 / M1 quote_does_not_cross_lines）。
        // 上限与 Rust 对齐为 `*`（无最大长度）。
        final pairs = r.pattern.split('|').where((p) => p.length >= 2).toList();
        if (pairs.isEmpty) return null;
        return pairs.map((p) {
          final open = RegExp.escape(p[0]);
          final close = RegExp.escape(p[1]);
          return '$open[^$close\\n]*$close';
        }).join('|');
      case RuleKind.paren:
        // （）与 () 均单行（排除 \n），与 Rust RuleKind::Paren 完全一致
        return r'(?:（[^）\n]*）|\([^)\n]*\))';
      case RuleKind.personName:
        // 分词分隔符与 Rust `Person` 对齐：逗号 / 空白 / 顿号（\s 含空格、制表、换行、\r）
        final words = r.pattern
            .split(RegExp(r'[,\s、]'))
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList()
          // 长词优先，避免「王小明」被「王小」抢先命中
          ..sort((a, b) => b.length.compareTo(a.length));
        if (words.isEmpty) return null;
        return words.map(RegExp.escape).join('|');
      case RuleKind.keywordList:
        // 关键词表（Dart-only，无 Rust 对应）：按行分词，允许含空格的关键词
        final words = r.pattern
            .split('\n')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList()
          ..sort((a, b) => b.length.compareTo(a.length));
        if (words.isEmpty) return null;
        return words.map(RegExp.escape).join('|');
      case RuleKind.dialogue:
        return r.pattern.isEmpty ? r'(?m)^[^“”"\n]{0,20}[：:]' : r.pattern;
    }
  }

  /// 对一段文本跑规则集，返回消解过重叠的区间列表（按 start 升序、互不重叠）。
  List<Segment> match(String text, RuleSet set) {
    if (set.isEmpty || text.isEmpty) return const [];

    final raw = <_RawMatch>[];
    for (final c in set.rules) {
      for (final m in c.regex.allMatches(text)) {
        if (m.end == m.start) continue;
        raw.add(_RawMatch(m.start, m.end, c.rule.priority, c.rule.id));
      }
    }
    if (raw.isEmpty) return const [];
    if (raw.length == 1) {
      return [Segment(raw[0].start, raw[0].end, raw[0].ruleId)];
    }
    return _resolveOverlaps(raw);
  }

  /// 重叠消解：
  ///   1. 取所有命中端点做**区间切分**，得到互不重叠的最小区间；
  ///   2. 每个最小区间取覆盖它的、优先级最高的规则；
  ///   3. 合并相邻且同规则的区间。
  /// 复杂度 O(B·R)（B=端点数，R=命中数），一章实测 < 5ms。
  List<Segment> _resolveOverlaps(List<_RawMatch> raw) {
    final points = <int>{};
    for (final r in raw) {
      points.add(r.start);
      points.add(r.end);
    }
    final sorted = points.toList()..sort();

    final out = <Segment>[];
    for (var i = 0; i < sorted.length - 1; i++) {
      final s = sorted[i];
      final e = sorted[i + 1];
      _RawMatch? best;
      for (final r in raw) {
        if (r.start <= s && r.end >= e) {
          if (best == null ||
              r.priority > best.priority ||
              (r.priority == best.priority && r.ruleId.compareTo(best.ruleId) < 0)) {
            best = r;
          }
        }
      }
      if (best == null) continue;
      if (out.isNotEmpty && out.last.ruleId == best.ruleId && out.last.end == s) {
        out[out.length - 1] = Segment(out.last.start, e, best.ruleId);
      } else {
        out.add(Segment(s, e, best.ruleId));
      }
    }
    return out;
  }
}

class _RawMatch {
  _RawMatch(this.start, this.end, this.priority, this.ruleId);
  final int start;
  final int end;
  final int priority;
  final String ruleId;
}
