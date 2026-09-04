use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

use crate::sync::hlc::Hlc;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Winner {
    Local,
    Remote,
    Merged,
}

/// 一次字段级冲突的记录 —— **绝不静默覆盖**，全部落 `conflict_log` 供用户查看
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FieldConflict {
    pub field: String,
    pub local: Value,
    pub remote: Value,
    pub winner: Winner,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MergeResult {
    pub merged: Value,
    pub conflicts: Vec<FieldConflict>,
    pub winner: Winner,
}

/// 通用实体合并：**字段级三方合并（three-way merge）**。
///
/// 纯 LWW 的问题：两端基于同一个旧版本各自改了**不同字段**时，
/// 后同步的一方会把对方的修改整条覆盖掉。三方合并能保住两边。
///
/// - 只有一端改了 → 采用改动方；
/// - 两端都改了且值不同 → 按 HLC 判胜者（相等则比 node 字典序），
///   并把败者写进 `conflicts`，UI 上可"一键改用本端/远端"；
/// - 墓碑（deleted）：删除优先，除非另一侧的修改 HLC 更晚（说明删了之后又改过）。
pub fn merge_entity(
    local: &Value,
    remote: &Value,
    base: Option<&Value>,
    local_hlc: &Hlc,
    remote_hlc: &Hlc,
) -> MergeResult {
    // 墓碑优先
    let l_del = truthy(local.get("deleted"));
    let r_del = truthy(remote.get("deleted"));
    if l_del || r_del {
        let winner = if l_del && r_del {
            newer(local_hlc, remote_hlc)
        } else if l_del {
            if remote_hlc > local_hlc { Winner::Remote } else { Winner::Local }
        } else {
            if local_hlc > remote_hlc { Winner::Local } else { Winner::Remote }
        };
        let merged = match winner {
            Winner::Local => local.clone(),
            _ => remote.clone(),
        };
        return MergeResult { merged, conflicts: Vec::new(), winner };
    }

    let empty = Map::new();
    let l = local.as_object().unwrap_or(&empty);
    let r = remote.as_object().unwrap_or(&empty);
    let b: Option<&Map<String, Value>> = base.and_then(|v| v.as_object());

    let mut out: Map<String, Value> = Map::new();
    let mut conflicts = Vec::new();
    let mut any_remote = false;
    let mut any_local_kept = false;

    let mut keys: Vec<&String> = l.keys().chain(r.keys()).collect();
    keys.sort();
    keys.dedup();

    for k in keys {
        // 同步元字段不参与三方比较，最终统一取较新一侧
        if matches!(k.as_str(), "hlc" | "updatedBy" | "updatedAt" | "rev") {
            continue;
        }
        let lv = l.get(k);
        let rv = r.get(k);
        let bv = b.and_then(|m| m.get(k));

        let local_changed = lv != bv;
        let remote_changed = rv != bv;

        let chosen = match (local_changed, remote_changed) {
            (true, true) => {
                if lv == rv {
                    lv.or(rv).cloned().unwrap_or(Value::Null)
                } else {
                    let w = newer(local_hlc, remote_hlc);
                    conflicts.push(FieldConflict {
                        field: k.clone(),
                        local: lv.cloned().unwrap_or(Value::Null),
                        remote: rv.cloned().unwrap_or(Value::Null),
                        winner: w,
                    });
                    match w {
                        Winner::Local => {
                            any_local_kept = true;
                            lv.cloned().unwrap_or(Value::Null)
                        }
                        _ => {
                            any_remote = true;
                            rv.cloned().unwrap_or(Value::Null)
                        }
                    }
                }
            }
            (true, false) => {
                any_local_kept = true;
                lv.cloned().unwrap_or(Value::Null)
            }
            (false, true) => {
                any_remote = true;
                rv.cloned().unwrap_or(Value::Null)
            }
            (false, false) => lv.or(rv).cloned().unwrap_or(Value::Null),
        };
        out.insert(k.clone(), chosen);
    }

    let winner = if conflicts.is_empty() {
        if any_remote && any_local_kept {
            Winner::Merged
        } else if any_remote {
            Winner::Remote
        } else {
            Winner::Local
        }
    } else {
        Winner::Merged
    };

    // 元字段：取 HLC 较新的一侧
    let new_hlc = newer(local_hlc, remote_hlc);
    let meta_src = match new_hlc {
        Winner::Local => local,
        _ => remote,
    };
    for k in ["hlc", "updatedBy", "updatedAt", "rev"] {
        if let Some(v) = meta_src.get(k) {
            out.insert(k.to_string(), v.clone());
        }
    }

    MergeResult { merged: Value::Object(out), conflicts, winner }
}

/// 阅读进度：**不能用 LWW**。
///
/// - 两端都是自然阅读（forced=false）→ 取 `percent` 更大的（用户想接续最远进度）；
/// - 任一端是"强制跳转"（拖动进度条 / 目录跳转，forced=true）→ 按 HLC 取**最新意图**，
///   否则用户拖回第 1 章后，另一端一同步又把他弹回第 12 章。
pub fn merge_progress(local: &Value, remote: &Value, local_hlc: &Hlc, remote_hlc: &Hlc) -> MergeResult {
    let lf = truthy(local.get("forced"));
    let rf = truthy(remote.get("forced"));
    let lp = percent_of(local);
    let rp = percent_of(remote);

    let (winner, reason) = if lf || rf {
        // 有强制跳转：谁的意图更新谁说了算
        let w = if lf && rf {
            newer(local_hlc, remote_hlc)
        } else if lf {
            if remote_hlc > local_hlc { Winner::Remote } else { Winner::Local }
        } else {
            if local_hlc > remote_hlc { Winner::Local } else { Winner::Remote }
        };
        (w, "forced")
    } else if (lp - rp).abs() < f32::EPSILON {
        (newer(local_hlc, remote_hlc), "equal")
    } else if rp > lp {
        (Winner::Remote, "max")
    } else {
        (Winner::Local, "max")
    };

    let merged = match winner {
        Winner::Local => local.clone(),
        _ => remote.clone(),
    };

    // 强制跳转被采纳后要"消费掉" forced 标记，否则它会一直压制后续的自然阅读进度
    let mut merged = merged;
    if reason == "forced" {
        if let Some(obj) = merged.as_object_mut() {
            obj.insert("forced".to_string(), Value::Bool(false));
        }
    }

    MergeResult { merged, conflicts: Vec::new(), winner }
}

/// 分组成员关系：加入取并集，移除才删除。
/// 避免一端"把书加进分组"被另一端的旧快照抹掉。
pub fn merge_membership(local: &Value, remote: &Value, local_hlc: &Hlc, remote_hlc: &Hlc) -> MergeResult {
    let l_removed = truthy(local.get("removed"));
    let r_removed = truthy(remote.get("removed"));
    if l_removed || r_removed {
        let w = if l_removed && r_removed {
            newer(local_hlc, remote_hlc)
        } else if l_removed {
            if remote_hlc > local_hlc { Winner::Remote } else { Winner::Local }
        } else {
            if local_hlc > remote_hlc { Winner::Local } else { Winner::Remote }
        };
        let merged = match w {
            Winner::Local => local.clone(),
            _ => remote.clone(),
        };
        return MergeResult { merged, conflicts: Vec::new(), winner: w };
    }
    // 两端都是"加入" → 保留，HLC 较新的一侧胜出（带 sortOrder）
    merge_entity(local, remote, None, local_hlc, remote_hlc)
}

fn truthy(v: Option<&Value>) -> bool {
    matches!(v, Some(Value::Bool(true)))
}

fn percent_of(v: &Value) -> f32 {
    v.get("percent")
        .and_then(|p| p.as_f64())
        .map(|f| f as f32)
        .unwrap_or(0.0)
}

/// HLC 比较；完全相等时用 node 字典序打破平局（保证全序）
fn newer(a: &Hlc, b: &Hlc) -> Winner {
    match a.cmp(b) {
        std::cmp::Ordering::Greater => Winner::Local,
        std::cmp::Ordering::Less => Winner::Remote,
        std::cmp::Ordering::Equal => {
            if a.node >= b.node { Winner::Local } else { Winner::Remote }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn hlc(ms: u64, c: u16, node: &str) -> Hlc {
        Hlc::new(ms, c, node)
    }

    #[test]
    fn three_way_keeps_both_side_changes() {
        let base = json!({"title":"旧名","tags":"a","hlc":"x"});
        let local = json!({"title":"A改的名","tags":"a","hlc":"x"});
        let remote = json!({"title":"旧名","tags":"b","hlc":"x"});
        let r = merge_entity(&local, &remote, Some(&base), &hlc(2, 0, "aaaaaaaa"), &hlc(1, 0, "bbbbbbbb"));
        assert_eq!(r.merged["title"], "A改的名"); // 只有本地改了
        assert_eq!(r.merged["tags"], "b"); // 只有远端改了
        assert!(r.conflicts.is_empty());
        assert_eq!(r.winner, Winner::Merged);
    }

    #[test]
    fn true_conflict_resolved_by_hlc() {
        let base = json!({"title":"旧名"});
        let local = json!({"title":"本地名"});
        let remote = json!({"title":"远端名"});
        let r = merge_entity(&local, &remote, Some(&base), &hlc(1, 0, "aaaaaaaa"), &hlc(5, 0, "bbbbbbbb"));
        assert_eq!(r.merged["title"], "远端名");
        assert_eq!(r.conflicts.len(), 1);
        assert_eq!(r.conflicts[0].winner, Winner::Remote);
    }

    #[test]
    fn tombstone_wins_unless_modified_later() {
        let local = json!({"deleted":true,"title":"x"});
        let remote = json!({"deleted":false,"title":"y"});
        // 远端修改更晚 → 复活
        let r = merge_entity(&local, &remote, None, &hlc(1, 0, "aaaaaaaa"), &hlc(9, 0, "bbbbbbbb"));
        assert_eq!(r.merged["deleted"], false);
        // 删除更晚 → 删除生效
        let r2 = merge_entity(&local, &remote, None, &hlc(9, 0, "aaaaaaaa"), &hlc(1, 0, "bbbbbbbb"));
        assert_eq!(r2.merged["deleted"], true);
    }

    #[test]
    fn progress_takes_max_when_not_forced() {
        let local = json!({"percent":0.2,"forced":false,"hlc":"a"});
        let remote = json!({"percent":0.6,"forced":false,"hlc":"b"});
        let r = merge_progress(&local, &remote, &hlc(9, 0, "aaaaaaaa"), &hlc(1, 0, "bbbbbbbb"));
        assert_eq!(r.merged["percent"], 0.6); // 即使本地 HLC 更新也取更远进度
    }

    #[test]
    fn progress_forced_jump_is_not_overridden() {
        // 手机上把进度拖回 10%（forced），电脑上自然读到 60%
        let local = json!({"percent":0.1,"forced":true,"hlc":"a"});
        let remote = json!({"percent":0.6,"forced":false,"hlc":"b"});
        let r = merge_progress(&local, &remote, &hlc(9, 0, "aaaaaaaa"), &hlc(5, 0, "bbbbbbbb"));
        assert_eq!(r.merged["percent"], 0.1);
        assert_eq!(r.merged["forced"], false); // forced 被消费掉
    }
}
