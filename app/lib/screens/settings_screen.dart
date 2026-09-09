import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/providers.dart';
import '../state/sync_prefs.dart';
import '../sync/sync_engine.dart';
import '../sync/webdav_client.dart';

/// 同步设置 + 同步中心（M3 T1 / T2-lite）。
///
/// 这是「下一步」里最先落地的部分：把原来 `/settings` 的占位屏换成真正的
/// WebDAV 凭据录入页，并顺带提供「立即同步 / 进度 / 上次结果」的同步操作区。
///
/// 凭据只存进 `flutter_secure_storage`（键 `webdav`），不写进明文偏好；
/// 保存后刷新 `webdavConfigProvider` / `syncEngineProvider`，引擎随即可用。
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  final _baseUrlCtl = TextEditingController();
  final _userCtl = TextEditingController();
  final _passCtl = TextEditingController();
  final _pinnedCtl = TextEditingController();
  bool _acceptInvalid = false;

  bool _testing = false;
  String? _testMsg;
  bool _testOk = false;

  bool _saving = false;

  SyncPrefs _prefs = const SyncPrefs();
  bool _prefsSeeded = false;

  @override
  void initState() {
    super.initState();
    // 用已有配置预填（首次进入通常为空）
    final cfg = ref.read(webdavConfigProvider).valueOrNull;
    if (cfg != null) {
      _baseUrlCtl.text = cfg.baseUrl;
      _userCtl.text = cfg.username;
      _passCtl.text = cfg.password;
      _pinnedCtl.text = cfg.pinnedCertSha256 ?? '';
      _acceptInvalid = cfg.acceptInvalidCerts;
    }
  }

  @override
  void dispose() {
    _baseUrlCtl.dispose();
    _userCtl.dispose();
    _passCtl.dispose();
    _pinnedCtl.dispose();
    super.dispose();
  }

  WebDavConfig _buildConfig() => WebDavConfig(
        baseUrl: _baseUrlCtl.text.trim(),
        username: _userCtl.text,
        password: _passCtl.text,
        acceptInvalidCerts: _acceptInvalid,
        pinnedCertSha256: _pinnedCtl.text.trim().isEmpty ? null : _pinnedCtl.text.trim(),
      );

  Future<void> _test() async {
    final url = _baseUrlCtl.text.trim();
    if (url.isEmpty) {
      setState(() => _testMsg = '请先填写服务器地址');
      return;
    }
    setState(() => _testing = true);
    try {
      final client = WebDavClient(_buildConfig());
      // mkcolAll 对「已存在」返回 405 视为成功；能走到这说明可达 + 鉴权通过
      await client.mkcolAll('inksync/');
      setState(() {
        _testOk = true;
        _testMsg = '连接成功，远端目录已就绪';
      });
    } on WebDavException catch (e) {
      setState(() {
        _testOk = false;
        _testMsg = '连接失败：HTTP ${e.status} ${e.message}';
      });
    } catch (e) {
      setState(() {
        _testOk = false;
        _testMsg = '连接失败：$e';
      });
    } finally {
      setState(() => _testing = false);
    }
  }

  /// 写入自动同步偏好并让轮询控制器重新排程。
  Future<void> _applyPrefs(SyncPrefs next) async {
    if (!mounted) return;
    setState(() => _prefs = next);
    await next.save(ref.read(databaseProvider));
    ref.invalidate(syncPrefsProvider);
  }

  Future<void> _save() async {
    final url = _baseUrlCtl.text.trim();
    if (url.isEmpty) {
      setState(() => _testMsg = '服务器地址不能为空');
      return;
    }
    setState(() => _saving = true);
    try {
      await saveWebDavConfig(_buildConfig());
      // 重建引擎 + 配置，使 SyncController 下一次 syncNow 能拿到 client
      ref.invalidate(webdavConfigProvider);
      ref.invalidate(syncEngineProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已保存同步设置')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('保存失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final progress = ref.watch(syncProgressProvider);
    final last = ref.watch(syncTriggerProvider);
    final livePrefs = ref.watch(syncPrefsProvider).valueOrNull;
    if (livePrefs != null && !_prefsSeeded) {
      _prefs = livePrefs;
      _prefsSeeded = true;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('同步设置')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('WebDAV 账户',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          TextField(
            controller: _baseUrlCtl,
            decoration: const InputDecoration(
              labelText: '服务器地址',
              hintText: 'https://dav.example.com/remote.php/dav/files/me',
              border: OutlineInputBorder(),
            ),
            keyboardType: TextInputType.url,
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _userCtl,
            decoration: const InputDecoration(
              labelText: '用户名',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _passCtl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '密码 / 应用专用令牌',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('信任自签证书（内网/群晖）'),
            value: _acceptInvalid,
            onChanged: (v) => setState(() => _acceptInvalid = v),
          ),
          TextField(
            controller: _pinnedCtl,
            decoration: const InputDecoration(
              labelText: '证书指纹 SHA-256（可选，比"信任一切"更安全）',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              FilledButton.icon(
                onPressed: _testing ? null : _test,
                icon: const Icon(Icons.cable),
                label: const Text('测试连接'),
              ),
              const SizedBox(width: 12),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: const Icon(Icons.save),
                label: const Text('保存'),
              ),
            ],
          ),
          if (_testMsg != null) ...[
            const SizedBox(height: 8),
            Text(
              _testMsg!,
              style: TextStyle(
                color: _testOk ? Colors.green : Colors.red,
              ),
            ),
          ],
          const Divider(height: 28),
          Text('同步', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: progress.isRunning
                ? null
                : () => ref.read(syncTriggerProvider.notifier).syncNow(),
            icon: const Icon(Icons.sync),
            label: const Text('立即同步'),
          ),
          const SizedBox(height: 10),
          if (progress.isRunning) ...[
            LinearProgressIndicator(value: progress.fraction),
            const SizedBox(height: 6),
            Text(progress.detail),
          ] else if (progress.detail.isNotEmpty) ...[
            Text(progress.detail),
          ],
          const SizedBox(height: 10),
          last.when(
            loading: () => const Text('同步中…'),
            error: (e, _) => Text('上次同步出错：$e',
                style: const TextStyle(color: Colors.red)),
            data: (report) {
              if (report == null) {
                return const Text('尚未同步');
              }
              final drift = ref.watch(hlcClockProvider).valueOrNull?.driftWarning();
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('上次同步：$report'),
                  if (drift != null)
                    Text(drift, style: const TextStyle(color: Colors.orange)),
                ],
              );
            },
          ),
          const SizedBox(height: 10),
          const Divider(height: 28),
          Text('自动同步', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('自动同步'),
            subtitle: const Text('后台定期拉取改动（命中 304 几乎零流量）'),
            value: _prefs.autoSync,
            onChanged: (v) => _applyPrefs(_prefs.copyWith(autoSync: v)),
          ),
          if (_prefs.autoSync) ...[
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('同步频率'),
              trailing: DropdownButton<int>(
                value: _prefs.intervalMin,
                items: const [
                  DropdownMenuItem(value: 1, child: Text('每 1 分钟')),
                  DropdownMenuItem(value: 5, child: Text('每 5 分钟')),
                  DropdownMenuItem(value: 15, child: Text('每 15 分钟')),
                  DropdownMenuItem(value: 30, child: Text('每 30 分钟')),
                  DropdownMenuItem(value: 60, child: Text('每 60 分钟')),
                ],
                onChanged: (v) {
                  if (v != null) _applyPrefs(_prefs.copyWith(intervalMin: v));
                },
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('仅 Wi-Fi / 有线时同步'),
              subtitle: const Text('移动网络下不同步，避免消耗流量'),
              value: _prefs.wifiOnly,
              onChanged: (v) => _applyPrefs(_prefs.copyWith(wifiOnly: v)),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('仅充电时同步'),
              subtitle: const Text('插电时才做后台同步，省电'),
              value: _prefs.chargingOnly,
              onChanged: (v) => _applyPrefs(_prefs.copyWith(chargingOnly: v)),
            ),
          ],
          Builder(
            builder: (context) {
              final polling = ref.watch(pollingControllerProvider);
              if (polling.consecutiveFails < kMaxConsecutiveFails) {
                return const SizedBox.shrink();
              }
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '自动同步已暂停：连续 $kMaxConsecutiveFails 次失败。'
                  '点上方「立即同步」成功后即自动恢复。',
                  style: const TextStyle(color: Colors.orange, fontSize: 12),
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          // 同步失败明细（若有）
          _ErrorList(report: last.valueOrNull),
          const Divider(height: 28),
          ListTile(
            leading: const Icon(Icons.hub_outlined),
            title: const Text('打开同步中心'),
            subtitle: const Text('查看设备 / 待同步 / 冲突留痕'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.of(context).pushNamed('/sync-center'),
          ),
        ],
      ),
    );
  }
}

class _ErrorList extends StatelessWidget {
  const _ErrorList({required this.report});
  final SyncReport? report;

  @override
  Widget build(BuildContext context) {
    if (report == null || report!.errors.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 6),
        Text('同步中出现 ${report!.errors.length} 个问题：',
            style: const TextStyle(color: Colors.orange)),
        ...report!.errors.map((e) => Text('• $e',
            style: const TextStyle(color: Colors.orange, fontSize: 12))),
      ],
    );
  }
}
