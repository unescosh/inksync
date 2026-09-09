// WebDAV 客户端退避重试策略的单测。
//
// 同步传输对网络抖动很敏感：弱网 / 服务端瞬时 5xx 会让整轮同步失败。
// 重试策略（哪些错重试、退避多久）是同步健壮性的核心，但原本嵌在私有 `_do` 里、
// 没有任何测试守护，极易在重构时悄悄改坏。这里把策略抽成纯函数后集中覆盖。
//
// 跑法：app 目录下 `flutter test`（CI 已配）。无需真实网络——只测策略判定与退避数学。

import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inksync/sync/webdav_client.dart';

void main() {
  group('isRetryableStatus', () {
    test('5xx / 429 / 423 可重试（瞬时服务端错误）', () {
      for (final s in [500, 502, 503, 504, 429, 423]) {
        expect(WebDavClient.isRetryableStatus(s), isTrue, reason: '$s 应可重试');
      }
    });

    test('4xx 不可重试（含 404 / 412 / 409，重试无意义）', () {
      for (final s in [400, 401, 403, 404, 405, 409, 412]) {
        expect(WebDavClient.isRetryableStatus(s), isFalse, reason: '$s 不应重试');
      }
    });

    test('0（无状态码，网络层异常）交给 Dio 类型判定，本身不可重试', () {
      expect(WebDavClient.isRetryableStatus(0), isFalse);
    });
  });

  group('isRetryableDioType', () {
    test('超时 / 连接错误可重试', () {
      for (final t in [
        DioExceptionType.connectionTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.sendTimeout,
        DioExceptionType.connectionError,
        DioExceptionType.unknown,
      ]) {
        expect(WebDavClient.isRetryableDioType(t), isTrue, reason: '$t 应可重试');
      }
    });

    test('cancel / badResponse / badCertificate 不可重试', () {
      for (final t in [
        DioExceptionType.cancel,
        DioExceptionType.badResponse,
        DioExceptionType.badCertificate,
      ]) {
        expect(WebDavClient.isRetryableDioType(t), isFalse);
      }
    });
  });

  group('backoffDelay', () {
    test('随 attempt 指数增长，且落在 [基础, 基础+抖动) 内（固定种子确定性）', () {
      final rng = math.Random(42);
      final d0 = WebDavClient.backoffDelay(0, rng);
      final d1 = WebDavClient.backoffDelay(1, rng);
      final d2 = WebDavClient.backoffDelay(2, rng);

      // 基础部分 300 / 600 / 1200（不含抖动），含抖动应 >= 基础下限
      expect(d0.inMilliseconds, greaterThanOrEqualTo(300));
      expect(d1.inMilliseconds, greaterThanOrEqualTo(600));
      expect(d2.inMilliseconds, greaterThanOrEqualTo(1200));
      // 抖动上限 +250，故上界为基础 + 250
      expect(d0.inMilliseconds, lessThanOrEqualTo(300 + 250));
      expect(d1.inMilliseconds, lessThanOrEqualTo(600 + 250));
      expect(d2.inMilliseconds, lessThanOrEqualTo(1200 + 250));
    });

    test('整体上限 8s（大 attempt 被 clamp）', () {
      final rng = math.Random(7);
      final big = WebDavClient.backoffDelay(20, rng);
      expect(big.inMilliseconds, lessThanOrEqualTo(8000));
    });

    test('同 attempt + 同种子确定性（可复现，便于调试）', () {
      final a = WebDavClient.backoffDelay(3, math.Random(99));
      final b = WebDavClient.backoffDelay(3, math.Random(99));
      expect(a, equals(b));
    });
  });
}
