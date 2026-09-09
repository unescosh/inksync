import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:inksync/state/sync_prefs.dart';

void main() {
  group('computePollDelay', () {
    test('连续失败 0 → 用用户配置间隔', () {
      expect(
        computePollDelay(consecutiveFails: 0, intervalMin: 5),
        const Duration(minutes: 5),
      );
      expect(
        computePollDelay(consecutiveFails: 0, intervalMin: 1),
        const Duration(minutes: 1),
      );
    });

    test('间隔下限钳制为 1 分钟、上限 1440 分钟', () {
      expect(
        computePollDelay(consecutiveFails: 0, intervalMin: 0),
        const Duration(minutes: 1),
      );
      expect(
        computePollDelay(consecutiveFails: 0, intervalMin: 99999),
        const Duration(minutes: 1440),
      );
    });

    test('指数退避 30s → 60s → 120s', () {
      expect(
        computePollDelay(consecutiveFails: 1, intervalMin: 5),
        const Duration(seconds: 30),
      );
      expect(
        computePollDelay(consecutiveFails: 2, intervalMin: 5),
        const Duration(seconds: 60),
      );
      expect(
        computePollDelay(consecutiveFails: 3, intervalMin: 5),
        const Duration(seconds: 120),
      );
    });

    test('退避封顶 2 小时', () {
      // 2^9 * 30s = 15360s，远超 7200s 上限
      expect(
        computePollDelay(consecutiveFails: 10, intervalMin: 5),
        const Duration(seconds: 7200),
      );
    });
  });

  group('shouldSkipForNetwork', () {
    test('关闭门限永不跳过', () {
      expect(shouldSkipForNetwork(const [ConnectivityResult.mobile], false), isFalse);
      expect(shouldSkipForNetwork(const [ConnectivityResult.wifi], false), isFalse);
    });

    test('移动网络应跳过', () {
      expect(shouldSkipForNetwork(const [ConnectivityResult.mobile], true), isTrue);
      expect(
        shouldSkipForNetwork(
          const [ConnectivityResult.wifi, ConnectivityResult.mobile],
          true,
        ),
        isTrue,
      );
    });

    test('Wi-Fi / 有线 / VPN / 无网络 不跳过', () {
      expect(shouldSkipForNetwork(const [ConnectivityResult.wifi], true), isFalse);
      expect(shouldSkipForNetwork(const [ConnectivityResult.ethernet], true), isFalse);
      expect(shouldSkipForNetwork(const [ConnectivityResult.vpn], true), isFalse);
      expect(shouldSkipForNetwork(const [ConnectivityResult.none], true), isFalse);
    });
  });

  group('SyncPrefs', () {
    test('默认值：开、5 分钟、不限网络、不充电', () {
      const p = SyncPrefs();
      expect(p.autoSync, isTrue);
      expect(p.intervalMin, 5);
      expect(p.wifiOnly, isFalse);
      expect(p.chargingOnly, isFalse);
    });

    test('copyWith 只改指定字段', () {
      const p = SyncPrefs();
      final q = p.copyWith(autoSync: false, intervalMin: 30);
      expect(q.autoSync, isFalse);
      expect(q.intervalMin, 30);
      expect(q.wifiOnly, isFalse);
      expect(q.chargingOnly, isFalse);
    });
  });
}
