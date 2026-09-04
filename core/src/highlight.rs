use serde::{Deserialize, Serialize};

use crate::model::{HighlightRule, RuleKind};

/// 单条命中的区间（字符偏移，UTF-8 字节无关，按 `char` 计）。
/// 渲染交给 Dart 侧（RichText 按 `ruleId`/`color` 上色）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MatchRange {
    pub start: usize,
    pub end: usize,
    pub rule_id: String,
    pub color: String,
}

/// 把规则套到一段纯文本上，返回命中的、已做完重叠消解的区间列表。
///
/// 语义：**逐叶子匹配**（调用方负责把段落/行拆成独立文本传入，不跨段）；
/// 重叠时高优先级胜，平级取较前起点；互不重叠的低优先级区间仍保留。
pub fn apply_rules(text: &str, rules: &[HighlightRule]) -> Vec<MatchRange> {
    // 收集所有命中（逐叶子匹配，不跨段），记录起点/终点/优先级/规则。
    let mut cands: Vec<(usize, usize, i32, &HighlightRule)> = Vec::new();
    for rule in rules {
        if !rule.enabled {
            continue;
        }
        let Some(re) = build_regex(rule) else {
            continue;
        };
        for m in re.find_iter(text) {
            if m.start() < m.end() {
                // `regex` 给的是**字节**偏移；`MatchRange` 的 start/end 语义是「字符偏移，按 char 计」
                // （见本文件头文档），与 Dart `RuleEngine` 一致。多字节 UTF-8（中文引号 / 书名号）
                // 下字节 ≠ 字符，必须转换，否则同一段中文在两端高亮区间错位（R4.4 一致性被破坏）。
                let cs = text[..m.start()].chars().count();
                let ce = text[..m.end()].chars().count();
                cands.push((cs, ce, rule.priority, rule));
            }
        }
    }
    if cands.is_empty() {
        return Vec::new();
    }

    // 区间切分 + 最高优先级：把重叠区切成最小子区间，每个子区间取覆盖它的、
    // 优先级最高的规则；平级按 rule_id 升序。与 Dart `RuleEngine._resolveOverlaps`
    // 逐字节一致，是双端高亮一致（R4.4）的规范算法。
    let mut points: Vec<usize> = cands.iter().flat_map(|(s, e, _, _)| [*s, *e]).collect();
    points.sort_unstable();
    points.dedup();

    let mut out: Vec<(usize, usize, &HighlightRule)> = Vec::new();
    for w in points.windows(2) {
        let (s, e) = (w[0], w[1]);
        let mut best: Option<(i32, &str, &HighlightRule)> = None;
        for (cs, ce, pri, rule) in &cands {
            if *cs <= s && *ce >= e {
                match best {
                    None => best = Some((*pri, rule.id.as_str(), *rule)),
                    Some((bpri, bid, _)) => {
                        if *pri > bpri || (*pri == bpri && rule.id.as_str() < bid) {
                            best = Some((*pri, rule.id.as_str(), *rule));
                        }
                    }
                }
            }
        }
        let Some((_, _, rule)) = best else { continue };
        if let Some(last) = out.last_mut() {
            if last.1 == s && last.2.id.as_str() == rule.id.as_str() {
                last.1 = e;
                continue;
            }
        }
        out.push((s, e, rule));
    }

    out.into_iter()
        .map(|(s, e, rule)| MatchRange {
            start: s,
            end: e,
            rule_id: rule.id.clone(),
            color: rule.color.clone(),
        })
        .collect()
}

/// 按规则种类生成正则源。
fn build_regex(rule: &HighlightRule) -> Option<regex::Regex> {
    let src = match rule.kind {
        RuleKind::Regex => rule.pattern.clone(),
        // 中文弯引号与 ASCII 双引号；全部**单行**（排除 \n），避免缺失闭引号时跨段吞掉整章。
        // 设计上高亮是"逐叶子匹配、不跨段"，跨行引用本就不该匹配。
        RuleKind::Quote => r#"(?:"[^"\n]*"|“[^”\n]*”|「[^」\n]*」|『[^』\n]*』)"#.to_string(),
        RuleKind::BookTitle => r"《[^》\n]*》".to_string(),
        RuleKind::Paren => r"(?:（[^）\n]*）|\([^)\n]*\))".to_string(),
        RuleKind::Person => {
            let names: Vec<String> = rule
                .pattern
                .split(|c| c == ',' || c == '、' || c == '\n' || c == '\r' || c == ' ' || c == '\t')
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(regex::escape)
                .collect();
            if names.is_empty() {
                return None;
            }
            names.join("|")
        }
    };
    regex::Regex::new(&src).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rule(id: &str, kind: RuleKind, pattern: &str, priority: i32) -> HighlightRule {
        HighlightRule {
            id: id.to_string(),
            name: id.to_string(),
            kind,
            pattern: pattern.to_string(),
            color: "#ff0000".to_string(),
            priority,
            enabled: true,
        }
    }

    #[test]
    fn book_title_matches() {
        let rs = [rule("bt", RuleKind::BookTitle, "", 0)];
        let out = apply_rules("他读了《三体》和《流浪地球》两本书", &rs);
        assert_eq!(out.len(), 2);
        assert_eq!(&out[0].rule_id, "bt");
    }

    #[test]
    fn person_list_compiles() {
        let rs = [rule("p", RuleKind::Person, "张三,李四、王五", 0)];
        let out = apply_rules("张三和李四去了王五家", &rs);
        assert_eq!(out.len(), 3);
    }

    #[test]
    fn higher_priority_wins_overlap_region() {
        // 区间切分语义：高优先在重叠区胜出，低优先在不重叠的前缀/后缀仍保留。
        // “《围城》是好书”：quote 命中 [0,10)，booktitle 命中《围城》[2,6)。
    let low = rule("q", RuleKind::Quote, "", 0);
    let high = rule("b", RuleKind::BookTitle, "", 10);
    let out = apply_rules("“《围城》是好书”", &[low, high]);
    assert!(out.iter().any(|m| m.rule_id == "b" && m.start == 1 && m.end == 5));
    let q: Vec<_> = out.iter().filter(|m| m.rule_id == "q").collect();
    assert_eq!(q.len(), 2, "低优先在不重叠区应保留为两段");
    assert!(q.iter().any(|m| m.start == 0 && m.end == 1));
    assert!(q.iter().any(|m| m.start == 5 && m.end == 9));
    }

    #[test]
    fn parity_interval_split_with_dart() {
        // 与 Dart RuleEngine._resolveOverlaps 同语义的对照用例，锁死双端一致性（R4.4）。
        // quote(a,pri1) 命中 [0,10)；booktitle(b,pri2) 命中《cd》[3,7)。
        let a = rule("a", RuleKind::Quote, "", 1);
        let b = rule("b", RuleKind::BookTitle, "", 2);
        let out = apply_rules("“ab《cd》ef”", &[a, b]);
        assert!(
            out.iter().any(|m| m.rule_id == "b" && m.start == 3 && m.end == 7),
            "高优先必须赢重叠区 [3,7)"
        );
        let q: Vec<_> = out.iter().filter(|m| m.rule_id == "a").collect();
        assert_eq!(q.len(), 2, "低优先在不重叠区应保留为两段");
        assert!(q.iter().any(|m| m.start == 0 && m.end == 3));
        assert!(q.iter().any(|m| m.start == 7 && m.end == 10));
    }

    #[test]
    fn disabled_rule_skipped() {
        let mut r = rule("x", RuleKind::Regex, "abc", 0);
        r.enabled = false;
        let out = apply_rules("abcdef", &[r]);
        assert!(out.is_empty());
    }

    #[test]
    fn quote_does_not_cross_lines() {
        let rs = [rule("q", RuleKind::Quote, "", 0)];
        // 缺闭引号（开引号在第 1 行，文末无成对闭引号）：单行正则要求同行成对，
        // 因此不应跨行吞掉整段 —— 这是 M1 修复的关键不变量。
        let out = apply_rules("他说：\"这是第一行\n这是第二行收尾", &rs);
        assert!(out.is_empty(), "缺闭引号时不应跨行匹配");

        // 单行内成对的 "..." 应正常命中
        let out2 = apply_rules("他说\"短句\"结束", &rs);
        assert_eq!(out2.len(), 1);
      assert_eq!(&out2[0].rule_id, "q");
      assert!(out2[0].start >= "他说".chars().count());
    }

    #[test]
    fn adjacent_paren_and_quote_both_kept() {
        // 相邻但不重叠的两条不同规则都应保留；重叠消解只丢重叠部分
        let q = rule("q", RuleKind::Quote, "", 0);
        let p = rule("p", RuleKind::Paren, "", 0);
        let out = apply_rules("他说（题记）“原文引用”收尾", &[q, p]);
        assert_eq!(out.len(), 2);
        assert!(out.iter().any(|m| m.rule_id == "q"));
        assert!(out.iter().any(|m| m.rule_id == "p"));
    }

    #[test]
    fn person_names_do_not_merge() {
        // 人名规则精确匹配，相邻两个名字不会被当一个吞掉
        let p = rule("p", RuleKind::Person, "张三,李四", 0);
        let out = apply_rules("张三和李四一起去", &[p]);
        assert_eq!(out.len(), 2);
        assert_eq!(out[0].rule_id, "p");
        assert_eq!(out[1].rule_id, "p");
    }
}
