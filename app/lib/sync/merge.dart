import '../core/hlc.dart';

/// 冲突合并 —— 与 Rust 侧 `core/src/sync/merge.rs` 逻辑一致。
///
/// 核心思想：**不同数据用不同策略**。一律 LWW 会造成
/// "读到一半进度被回退"、"分组里加的书被旧快照抹掉"这类致命体验问题。
library;

enum MergeWinner { local, remote, merged }

/// 被裁决掉的写入留痕。**绝不静默覆盖**，用户可在同步中心找回。
class FieldConflict {
  FieldConflict({
    required this.field,
    required this.local,
    required this.remote,
    required this.winner,
  });

  final String field;
  final Object? local;
  final Object? remote;
  final MergeWinner winner;

  Map<String, dynamic> toJson() => {
        'field': field,
        'local': local,
        'remote': remote,
        'winner': winner.name,
      };
}

class MergeResult {
  MergeResult({required this.merged, required this.conflicts, required this.winner});

  final Map<String, dynamic> merged;
  final List<FieldConflict> conflicts;
  final MergeWinner winner;
}

const Set<String> _metaKeys = {'hlc', 'updatedBy', 'updatedAt', 'rev'};

/// 通用实体：**字段级三方合并**。
///
/// 纯 LWW 的问题是：两端基于同一个旧版本各自改了不同字段时，
/// 后同步的一方会把对方的修改整条覆盖。三方合并能同时保住两边。
MergeResult mergeEntity(
  Map<String, dynamic> local,
  Map<String, dynamic> remote, {
  Map<String, dynamic>? base,
  required Hlc localHlc,
  required Hlc remoteHlc,
}) {
  // 墓碑优先：删除生效，除非另一侧的修改更晚（说明删了之后又被改过）
  final lDel = local['deleted'] == true;
  final rDel = remote['deleted'] == true;
  if (lDel || rDel) {
    MergeWinner w;
    if (lDel && rDel) {
      w = _newer(localHlc, remoteHlc);
    } else if (lDel) {
      w = remoteHlc.compareTo(localHlc) > 0 ? MergeWinner.remote : MergeWinner.local;
    } else {
      w = localHlc.compareTo(remoteHlc) > 0 ? MergeWinner.local : MergeWinner.remote;
    }
    return MergeResult(merged: Map.of(w == MergeWinner.local ? local : remote), conflicts: const [], winner: w);
  }

  final out = <String, dynamic>{};
  final conflicts = <FieldConflict>[];
  var anyRemote = false;
  var anyLocal = false;

  final keys = {...local.keys, ...remote.keys}.toList()..sort();

  for (final k in keys) {
    if (_metaKeys.contains(k)) continue;
    final remoteHas = remote.containsKey(k);
    final lv = local[k];
    final rv = remote[k];
    final bv = base?[k];

    // 远端没带这个字段 = 它没改过 → 保留本地值（或 base），绝不能当"置空"处理。
    // 否则稀疏 outbox payload（如 reorderCollections 只发 {id, sortOrder}）会清掉
    // 分组名 / 颜色 / emoji、书籍封面等未改字段。
    if (!remoteHas) {
      out[k] = lv ?? bv;
      continue;
    }

    final localChanged = !_eq(lv, bv);
    final remoteChanged = !_eq(rv, bv);

    if (localChanged && remoteChanged && !_eq(lv, rv)) {
      final w = _newer(localHlc, remoteHlc);
      conflicts.add(FieldConflict(field: k, local: lv, remote: rv, winner: w));
      if (w == MergeWinner.local) {
        anyLocal = true;
        out[k] = lv;
      } else {
        anyRemote = true;
        out[k] = rv;
      }
    } else if (localChanged) {
      anyLocal = true;
      out[k] = lv;
    } else if (remoteChanged) {
      anyRemote = true;
      out[k] = rv;
    } else {
      out[k] = lv ?? rv;
    }
  }

  final winner = conflicts.isNotEmpty
      ? MergeWinner.merged
      : (anyRemote && anyLocal
          ? MergeWinner.merged
          : anyRemote
              ? MergeWinner.remote
              : MergeWinner.local);

  // 同步元字段取 HLC 较新的一侧
  final metaSrc = _newer(localHlc, remoteHlc) == MergeWinner.local ? local : remote;
  for (final k in _metaKeys) {
    if (metaSrc.containsKey(k)) out[k] = metaSrc[k];
  }

  return MergeResult(merged: out, conflicts: conflicts, winner: winner);
}

/// 阅读进度：**不能用 LWW**。
///
/// - 两端都是自然阅读（forced=false）→ 取 percent 更大的；
/// - 任一端是强制跳转（拖进度条 / 目录跳转）→ 按 HLC 取**最新意图**，
///   否则用户拖回第 1 章后，另一端一同步又把他弹回第 12 章。
MergeResult mergeProgress(
  Map<String, dynamic> local,
  Map<String, dynamic> remote, {
  required Hlc localHlc,
  required Hlc remoteHlc,
}) {
  final lf = local['forced'] == true;
  final rf = remote['forced'] == true;
  final lp = (local['percent'] as num?)?.toDouble() ?? 0.0;
  final rp = (remote['percent'] as num?)?.toDouble() ?? 0.0;

  late MergeWinner w;
  var forcedResolved = false;
  if (lf || rf) {
    forcedResolved = true;
    if (lf && rf) {
      w = _newer(localHlc, remoteHlc);
    } else if (lf) {
      w = remoteHlc.compareTo(localHlc) > 0 ? MergeWinner.remote : MergeWinner.local;
    } else {
      w = localHlc.compareTo(remoteHlc) > 0 ? MergeWinner.local : MergeWinner.remote;
    }
  } else if ((lp - rp).abs() < 1e-9) {
    w = _newer(localHlc, remoteHlc);
  } else if (rp > lp) {
    w = MergeWinner.remote;
  } else {
    w = MergeWinner.local;
  }

  final merged = Map<String, dynamic>.of(w == MergeWinner.local ? local : remote);
  // 强制跳转被采纳后要"消费掉" forced，否则它会一直压制后续的自然阅读进度
  if (forcedResolved) merged['forced'] = false;
  return MergeResult(merged: merged, conflicts: const [], winner: w);
}

/// 分组成员：**加入取并集，移除才删除**。
/// 否则一端"把书加进分组"会被另一端的旧快照抹掉。
MergeResult mergeMembership(
  Map<String, dynamic> local,
  Map<String, dynamic> remote, {
  required Hlc localHlc,
  required Hlc remoteHlc,
}) {
  final lRemoved = local['removed'] == true;
  final rRemoved = remote['removed'] == true;
  if (lRemoved || rRemoved) {
    late MergeWinner w;
    if (lRemoved && rRemoved) {
      w = _newer(localHlc, remoteHlc);
    } else if (lRemoved) {
      w = remoteHlc.compareTo(localHlc) > 0 ? MergeWinner.remote : MergeWinner.local;
    } else {
      w = localHlc.compareTo(remoteHlc) > 0 ? MergeWinner.local : MergeWinner.remote;
    }
    return MergeResult(
      merged: Map.of(w == MergeWinner.local ? local : remote),
      conflicts: const [],
      winner: w,
    );
  }
  return mergeEntity(local, remote, localHlc: localHlc, remoteHlc: remoteHlc);
}

bool _eq(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_eq(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !_eq(a[k], b[k])) return false;
    }
    return true;
  }
  return a == b;
}

/// HLC 比较；完全相等时用 node 字典序打破平局，保证全序
MergeWinner _newer(Hlc a, Hlc b) {
  final c = a.compareTo(b);
  if (c > 0) return MergeWinner.local;
  if (c < 0) return MergeWinner.remote;
  return a.node.compareTo(b.node) >= 0 ? MergeWinner.local : MergeWinner.remote;
}
