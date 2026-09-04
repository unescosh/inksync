import 'native_core.dart';

/// 原生核心的接线点 —— **整个 App 里唯一 import flutter_rust_bridge 生成产物的文件**。
///
/// 为什么单独抽一个文件：生成产物（`src/rust/frb_generated.dart` 等）在跑
/// `flutter_rust_bridge_codegen generate` 之前根本不存在，Dart 又没有条件编译。
/// 如果直接在 `main.dart` 里 import，仓库在 codegen 之前是**编译不过**的，
/// 新人 clone 下来第一件事就是看到一屏红字。
///
/// 现在的行为：返回 null → `nativeCoreProvider` 保持 [UnimplementedNativeCore]，
/// App 能正常启动、书架/规则页都能用，只有"导入书籍 / 打开阅读器"会抛
/// UnsupportedError 提示未注入核心。
///
/// ── T1 codegen 之后要做的事（三步） ──
///
/// 1. 在 `core/` 下生成绑定：
///    ```
///    cargo install flutter_rust_bridge_codegen --version 2.0.0-dev.0
///    flutter_rust_bridge_codegen generate
///    ```
///    并把 `mod bridge_generated;`（或 codegen 提示的模块名）加进 `core/src/lib.rs`。
///
/// 2. 打开下面 `_wire()` 的注释，按生成产物的实际路径/函数名调整 import 与调用。
///    frb 2.x 默认把 `core/src/api.rs` 映射成 `lib/src/rust/api/api.dart`，
///    Rust 的 `parse_book_json` → Dart 的 `parseBookJson`。
///
/// 3. 把 [createNativeCore] 的实现从 `null` 改成 `_wire()`。
///
/// 只认 `core/src/api.rs` 里 serde 定的 JSON 键，不认生成类的字段名 ——
/// 所以 frb 升级把 DTO 类改名了，也只需要动这个文件。
Future<NativeCore?> createNativeCore() async {
  return null;
  // codegen 完成后改成： return _wire();
}

// ignore: unused_element
Future<NativeCore> _wire() async {
  throw UnsupportedError(
    '请先跑 flutter_rust_bridge_codegen generate，'
    '然后按本文件顶部注释启用真实实现',
  );

  // ── 以下是 codegen 之后的目标代码，取消注释并删掉上面的 throw ──
  //
  // await RustLib.init();
  // return CallbackNativeCore(
  //   parse: (path) async =>
  //       jsonDecode(await parseBookJson(path: path)) as Map<String, dynamic>,
  //   probe: (path) async =>
  //       jsonDecode(await probeBookJson(path: path)) as Map<String, dynamic>,
  //   image: (path, entry) async {
  //     final bytes = await readInternalImage(path: path, entry: entry);
  //     return bytes == null ? null : Uint8List.fromList(bytes);
  //   },
  //   mobi: (path, record) async {
  //     final bytes = await readMobiImage(path: path, record: record);
  //     return bytes == null ? null : Uint8List.fromList(bytes);
  //   },
  //   hash: (path) => sha256File(path: path),
  // );
}
