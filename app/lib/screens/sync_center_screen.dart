import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/database.dart';
import '../state/providers.dart';
import '../sync/sync_engine.dart';

/// 同步中心：一眼看清同步状态 + 处理冲突留痕。
///
/// 数据层：`conflict_log` 表「绝不静默覆盖」——被裁决掉的值都进这里，用户能找回；
/// 这里把它展示出来并支持「标记为已处理」。pendingOutbox 计数 + lastSyncAt 给同步概览。
class SyncCenterScreen extends ConsumerWidget {
  const SyncCenterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final syncState = ref.watch(syncTriggerProvider);
    final syncing = syncState.isLoading;
    final progress = ref.watch(syncProgressProvider);
    final report = syncState.value;
    final pending = ref.watch(pendingOutboxCountProvider).valueOrNull ?? 0;
    final lastSync = ref.watch(lastSyncAtProvider);
    final deviceId = ref.watch(deviceIdProvider);
    final conflicts = ref.watch(conflictsProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('同步中心')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _StatusCard(
            syncing: syncing,
            progress: progress,
            report: report,
            pending: pending,
            lastSync: lastSync,
            deviceId: deviceId,
            onSync: syncing
                ? null
                : () => ref.read(syncTriggerProvider.notifier).syncNow(),
          ),
          const SizedBox(height: 24),
          Text('冲突留痕', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          conflicts.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (e, _) => Text('加载失败：$e'),
            data: (list) {
              if (list.isEmpty) {
                return const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('没有冲突，所有同步都干净落地 ✅'),
                  ),
                );
              }
              return Column(
                children: [for (final c in list) _ConflictTile(row: c)],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.syncing,
    required this.progress,
    required this.report,
    required this.pending,
    required this.lastSync,
    required this.deviceId,
    required this.onSync,
  });

  final bool syncing;
  final SyncProgressState progress;
  final SyncReport? report;
  final int pending;
  final AsyncValue<String?> lastSync;
  final AsyncValue<String> deviceId;
  final VoidCallback? onSync;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('同步状态', style: Theme.of(context).textTheme.titleMedium),
                ),
                FilledButton.icon(
                  onPressed: onSync,
                  icon: syncing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.sync),
                  label: Text(syncing ? '同步中…' : '立即同步'),
                ),
              ],
            ),
            if (progress.isRunning) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(value: progress.fraction),
              const SizedBox(height: 4),
              Text(progress.detail,
                  style: Theme.of(context).textTheme.bodySmall),
            ],
            const Divider(height: 24),
            _Row(
              label: '设备 ID',
              value: deviceId.when(
                loading: () => '…',
                error: (_, __) => '—',
                data: (v) => v,
              ),
            ),
            _Row(label: '待同步变更', value: '$pending 条'),
            _Row(
              label: '上次同步',
              value: lastSync.when(
                loading: () => '…',
                error: (_, __) => '—',
                data: (v) => v == null ? '尚未同步' : _formatTime(v),
              ),
            ),
            if (report != null && report.ok) ...[
              const SizedBox(height: 8),
              Text(
                '上次结果：推送 ${report.pushedChanges} / 拉取 ${report.pulledChanges} / 冲突 ${report.conflicts}',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        ),
      ),
    );
  }

  static String _formatTime(String iso) {
    final t = DateTime.tryParse(iso);
    if (t == null) return iso;
    final local = t.toLocal();
    final p = (int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${p(local.month)}-${p(local.day)} '
        '${p(local.hour)}:${p(local.minute)}';
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            SizedBox(
              width: 80,
              child: Text(
                label,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
              ),
            ),
            Expanded(child: Text(value)),
          ],
        ),
      );
}

class _ConflictTile extends ConsumerWidget {
  const _ConflictTile({required this.row});

  final ConflictRow row;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final winnerText = row.winner == 'local' ? '保留本地' : '采用远端';
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${row.entityType} · ${row.field}',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Chip(
                  label: Text(winnerText, style: const TextStyle(fontSize: 12)),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: scheme.surfaceContainerHighest,
                ),
              ],
            ),
            const SizedBox(height: 8),
            _ValueLine(label: '本地', value: _decode(row.localValue), color: scheme.primary),
            _ValueLine(label: '远端', value: _decode(row.remoteValue), color: scheme.tertiary),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => ref.read(databaseProvider).dismissConflict(row.id),
                child: const Text('标记为已处理'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _decode(String v) {
    try {
      final d = jsonDecode(v);
      if (d is String) return d;
      return d.toString();
    } catch (_) {
      return v;
    }
  }
}

class _ValueLine extends StatelessWidget {
  const _ValueLine({
    required this.label,
    required this.value,
    required this.color,
  });

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 40,
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color),
              ),
            ),
            Expanded(
              child: SelectableText(
                value,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
}
