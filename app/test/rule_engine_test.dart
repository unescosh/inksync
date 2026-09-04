import 'package:flutter_test/flutter_test.dart';
import 'package:inksync/reader/rules.dart';

/// Dart 高亮引擎与 Rust `core::highlight::apply_rules` 的等价断言（R4.4）。
///
/// 用例直接复刻 `core/src/highlight.rs` 中的 Rust fixture，用于锁死双端一致性：
/// 同一段文本 + 同一组规则，Dart `RuleEngine.match` 与 Rust `apply_rules` 必须
/// 产出逐字节相同的区间。仅覆盖两端共有的 5 类规则
/// （regex / quote / bookTitle / paren / person），与 M2 计划 T7 一致。
void main() {
  final engine = RuleEngine();

  RuleSet compileRules(List<HighlightRule> rules) =>
      engine.compile(rules, scope: RuleScope.novel);

  test('区间切分 + 最高优先级（对应 Rust parity_interval_split_with_dart）', () {
    // quote(a,pri1) 命中 [0,10)；booktitle(b,pri2) 命中《cd》[3,7)
    final rules = [
      HighlightRule(id: 'a', name: 'q', kind: RuleKind.quote, pattern: '“”|「」|『』', priority: 1),
      HighlightRule(id: 'b', name: 'bt', kind: RuleKind.bookTitleMark, pattern: '《》', priority: 2),
    ];
    final segs = engine.match('“ab《cd》ef”', compileRules(rules));
    // 高优先 b 赢重叠区 [3,7)
    expect(segs.any((s) => s.ruleId == 'b' && s.start == 3 && s.end == 7), isTrue);
    // 低优先 a 在不重叠区保留为两段 [0,3) 与 [7,10)
    final q = segs.where((s) => s.ruleId == 'a').toList();
    expect(q.length, 2);
    expect(q.any((s) => s.start == 0 && s.end == 3), isTrue);
    expect(q.any((s) => s.start == 7 && s.end == 10), isTrue);
  });

  test('高优先赢重叠区、低优先保留不重叠前缀/后缀（higher_priority_wins_overlap_region）', () {
    // “《围城》是好书”：quote 命中 [0,9)，booktitle《围城》[1,5)
    final rules = [
      HighlightRule(id: 'q', name: 'q', kind: RuleKind.quote, pattern: '“”|「」|『』', priority: 0),
      HighlightRule(id: 'b', name: 'b', kind: RuleKind.bookTitleMark, pattern: '《》', priority: 10),
    ];
    final segs = engine.match('“《围城》是好书”', compileRules(rules));
    expect(segs.any((s) => s.ruleId == 'b' && s.start == 1 && s.end == 5), isTrue);
    final q = segs.where((s) => s.ruleId == 'q').toList();
    expect(q.length, 2, reason: '低优先在不重叠区应保留为两段');
    expect(q.any((s) => s.start == 0 && s.end == 1), isTrue);
    expect(q.any((s) => s.start == 5 && s.end == 9), isTrue);
  });

  test('缺闭引号不跨行（quote_does_not_cross_lines，与 Rust 单行不变量一致）', () {
    final rules = [
      HighlightRule(id: 'q', name: 'q', kind: RuleKind.quote, pattern: '“”|「」|『』', priority: 0),
    ];
    final set = compileRules(rules);
    final out = engine.match('他说：“这是第一行\n这是第二行收尾', set);
    expect(out, isEmpty, reason: '缺闭引号时不应跨行匹配');
    // 单行内成对的 “...” 应正常命中
    final out2 = engine.match('他说“短句”结束', set);
    expect(out2.length, 1);
    expect(out2.first.ruleId, 'q');
  });

  test('相邻 quote 与 paren 均保留（paren 规则存在且单行）', () {
    final rules = [
      HighlightRule(id: 'q', name: 'q', kind: RuleKind.quote, pattern: '“”|「」|『』', priority: 0),
      HighlightRule(id: 'p', name: 'p', kind: RuleKind.paren, priority: 0),
    ];
    final segs = engine.match('他说（题记）“原文引用”收尾', compileRules(rules));
    expect(segs.any((s) => s.ruleId == 'q'), isTrue);
    expect(segs.any((s) => s.ruleId == 'p'), isTrue);
  });

  test('person 人名精确匹配且相邻不合并', () {
    final rules = [
      HighlightRule(id: 'p', name: 'p', kind: RuleKind.personName, pattern: '张三,李四', priority: 0),
    ];
    final segs = engine.match('张三和李四一起去', compileRules(rules));
    expect(segs.length, 2);
    expect(segs.every((s) => s.ruleId == 'p'), isTrue);
  });
}
