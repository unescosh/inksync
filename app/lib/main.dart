import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:window_manager/window_manager.dart';

import 'core/native_bridge.dart';
import 'core/native_core.dart';
import 'screens/import_screen.dart';
import 'screens/library_screen.dart';
import 'screens/reader_screen.dart';
import 'screens/rules_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/sync_center_screen.dart';
import 'state/providers.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── 桌面端（Windows 10 / UOS 20）窗口初始化 ──
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux)) {
    await windowManager.ensureInitialized();
    const options = WindowOptions(
      size: Size(1280, 860),
      minimumSize: Size(720, 560),
      center: true,
      title: 'InkSync · 墨阅',
    );
    await windowManager.waitUntilReadyToShow(options, () async {
      await windowManager.show();
      await windowManager.focus();
    });
    // UOS 的 GTK 输入法：不显式设置会导致切不出中文（fcitx）
    if (Platform.isLinux) {
      final im = Platform.environment['GTK_IM_MODULE'];
      if (im == null || im.isEmpty) {
        // 仅打印提示，真正的设置在 deb 包的启动脚本里导出
        debugPrint('[inksync] 提示：GTK_IM_MODULE 未设置，'
            '如遇中文无法输入请在启动脚本中导出 GTK_IM_MODULE=fcitx');
      }
    }
  }

  // 原生解析核心。codegen 还没跑时返回 null，此时用 UnimplementedNativeCore 兜底：
  // App 照样启动，只有导入/开书会明确报"未注入原生核心"，而不是一片白屏。
  NativeCore? core;
  try {
    core = await createNativeCore();
  } catch (e, st) {
    debugPrint('[inksync] 原生核心初始化失败，降级为未注入状态：$e\n$st');
    core = null;
  }

  runApp(ProviderScope(
    overrides: [
      if (core != null) nativeCoreProvider.overrideWithValue(core),
    ],
    child: const InkSyncApp(),
  ));
}

class InkSyncApp extends ConsumerStatefulWidget {
  const InkSyncApp({super.key});

  @override
  ConsumerState<InkSyncApp> createState() => _InkSyncAppState();
}

class _InkSyncAppState extends ConsumerState<InkSyncApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  /// 首帧后的启动动作，**顺序有讲究**：
  /// 先播种内置高亮规则，再拉第一次同步。
  ///
  /// 播种行用 `Hlc.zero`，所以万一远端已经改过/删过这些预设，
  /// 紧接着的同步会把远端版本压下来 —— 不会出现"新设备一开机就把
  /// 别的设备删掉的预设复活"。反过来先同步再播种就会漏判（rules 表
  /// 已经被远端填上，播种条件不成立，本来该有的默认规则就没了）。
  Future<void> _bootstrap() async {
    try {
      await ref.read(libraryActionsProvider).seedDefaultRulesIfEmpty();
    } catch (e) {
      debugPrint('[inksync] 内置高亮规则播种失败：$e');
    }
    if (!mounted) return;
    ref.read(syncTriggerProvider.notifier).syncNow();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 回到前台立即同步一次，这是三端"感觉实时"的重要一环
    if (state == AppLifecycleState.resumed) {
      ref.read(syncTriggerProvider.notifier).syncNow();
    }
  }

  @override
  Widget build(BuildContext context) {
    // 启动自动同步轮询控制器（替代写死的 5 分钟定时器）。
    // 它随同步偏好变化自动重排程；本 widget 常驻，provider 不会被回收。
    ref.watch(pollingControllerProvider);
    return MaterialApp(
      title: 'InkSync · 墨阅',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: _buildTheme(Brightness.light),
      darkTheme: _buildTheme(Brightness.dark),
      initialRoute: '/',
      routes: {
        '/': (_) => const LibraryScreen(),
        '/rules': (_) => const RulesScreen(),
        '/settings': (_) => const SettingsScreen(),
        '/import': (_) => const ImportScreen(),
        '/sync-center': (_) => const SyncCenterScreen(),
      },
      onGenerateRoute: (settings) {
        if (settings.name == '/reader') {
          final id = settings.arguments as String?;
          if (id == null) {
            return MaterialPageRoute<void>(
              builder: (_) => const _PlaceholderScreen('缺少 bookId'),
            );
          }
          return MaterialPageRoute<void>(
            builder: (_) => ReaderScreen(bookId: id),
          );
        }
        return null;
      },
    );
  }

  ThemeData _buildTheme(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF6A4C93),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // 三端统一的中文正文字体（UOS 精简版常缺字，故内置子集）
      fontFamilyFallback: const ['SourceHanSerif', 'Microsoft YaHei', 'Noto Sans CJK SC'],
      // Android 大屏 / 桌面端放宽视觉密度
      visualDensity: VisualDensity.adaptivePlatformDensity,
    );
  }
}

class _PlaceholderScreen extends StatelessWidget {
  const _PlaceholderScreen(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(title)),
        body: const Center(child: Text('该页面在对应里程碑实现')),
      );
}
