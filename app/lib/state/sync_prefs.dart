import 'dart:math' as math;

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drift/drift.dart';

import '../data/database.dart';

/// 自动同步轮询偏好（本地，不同步）。
///
/// PM#5：把原来写死在 main.dart 的「5 分钟 Timer」升级为可配置、可门限、
/// 可退避的轮询策略。偏好存进 [SyncStateKeys]（sync_states 表），不进 outbox。
class SyncPrefs {
  const SyncPrefs({
    this.autoSync = true,
    this.intervalMin = 5,
    this.wifiOnly = false,
    this.chargingOnly = false,
  });

  /// 总开关：关则完全不轮询（手动同步仍可用）。
  final bool autoSync;

  /// 轮询间隔（分钟），默认 5。
  final int intervalMin;

  /// 仅 Wi-Fi / 有线 下同步（移动网络跳过）。
  final bool wifiOnly;

  /// 仅充电 / 满电时同步（省电）。
  final bool chargingOnly;

  SyncPrefs copyWith({
    bool? autoSync,
    int? intervalMin,
    bool? wifiOnly,
    bool? chargingOnly,
  }) =>
      SyncPrefs(
        autoSync: autoSync ?? this.autoSync,
        intervalMin: intervalMin ?? this.intervalMin,
        wifiOnly: wifiOnly ?? this.wifiOnly,
        chargingOnly: chargingOnly ?? this.chargingOnly,
      );

  static Future<SyncPrefs> load(AppDatabase db) async {
    final a = await db.getState(SyncStateKeys.autoSync);
    final i = await db.getState(SyncStateKeys.syncIntervalMin);
    final w = await db.getState(SyncStateKeys.syncWifiOnly);
    final c = await db.getState(SyncStateKeys.syncChargingOnly);
    return SyncPrefs(
      autoSync: a != '0',
      intervalMin: int.tryParse(i ?? '') ?? 5,
      wifiOnly: w == '1',
      chargingOnly: c == '1',
    );
  }

  Future<void> save(AppDatabase db) async {
    await db.setState(SyncStateKeys.autoSync, autoSync ? '1' : '0');
    await db.setState(SyncStateKeys.syncIntervalMin, '$intervalMin');
    await db.setState(SyncStateKeys.syncWifiOnly, wifiOnly ? '1' : '0');
    await db.setState(SyncStateKeys.syncChargingOnly, chargingOnly ? '1' : '0');
  }
}

/// 连续失败达此上限后停止自动轮询（手动同步成功即复位、恢复）。
const int kMaxConsecutiveFails = 5;

/// 下次轮询延迟（纯函数，便于测试）。
///
/// 连续失败次数 0 → 用用户配置间隔；之后指数退避 30s→60s→120s…，封顶 2 小时。
Duration computePollDelay({required int consecutiveFails, required int intervalMin}) {
  if (consecutiveFails <= 0) {
    return Duration(minutes: intervalMin.clamp(1, 1440));
  }
  final secs = (30 * math.pow(2, consecutiveFails - 1)).clamp(0, 7200).toInt();
  return Duration(seconds: secs);
}

/// 仅 Wi-Fi 模式下是否应跳过本次同步（纯函数，便于测试）。
///
/// 移动网络（蜂窝）会烧流量，跳过；Wi-Fi / 有线 / VPN 视为可同步。
bool shouldSkipForNetwork(List<ConnectivityResult> results, bool wifiOnly) {
  if (!wifiOnly) return false;
  return results.any((r) => r == ConnectivityResult.mobile);
}
