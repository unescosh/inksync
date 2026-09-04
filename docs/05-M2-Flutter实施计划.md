# 05 · M2 Flutter 应用实施计划（定稿版）

> 状态：**已定稿，可开工**（经 PM + SWE 双视角审核，7 处代码对齐缺口已并回本计划，3 项待确认决策已确认）。
> 范围：把 `app/` 现有骨架变成**可编译、可本地运行**的 Flutter 应用（书架 / 阅读器 / 规则）。
> 不在此文档：M3 同步引擎（需 C 工具链，沙箱不可验）、M4 三端打包与真机联调。
>
> 硬约束：本沙箱**未安装 Flutter SDK / C 链**，M2 的 `flutter_rust_bridge codegen` / `build_runner` / `flutter build` **只能在你本机执行**；沙箱只写代码 + 跑纯 Rust 单测/集成测（R4.3）。

## 1. 目标与验收标准

M2 完成判定（在你本机跑通为准）：

- [ ] `flutter pub get` → `flutter_rust_bridge codegen generate` → `dart run build_runner build` → `flutter analyze` 零错误；
- [ ] `flutter run`（Windows 桌面）能起应用，书架为空态正常；
- [ ] 导入一本 EPUB/TXT/CBZ/PDF/MOBI → 书架出现封面卡片、进度 0%；
- [ ] 打开文本书：正文按 `p/h1-h6/blockquote/em/strong/img` 渲染，**高亮规则实时上色**，滚动 2s 后落库进度；
- [ ] 打开漫画书（CBZ/PDF/图片型 EPUB/MOBI 图片书）：分页浏览，按 `page_index` 存进度；
- [ ] 规则页：增删改高亮规则（首启已 seed 预设），阅读器即时反映（无需重启）；
- [ ] Dart 高亮引擎与 Rust `apply_rules` 对一组固定用例输出一致（双端一致性测试）。

## 2. 前置工具链（你本机需具备）

| 工具 | 用途 | 备注 |
|------|------|------|
| Flutter ≥ 3.22 + Dart ≥ 3.4 | 应用编译/运行 | `pubspec.yaml` 已声明 |
| `flutter_rust_bridge_codegen` | 生成 Rust↔Dart FFI 绑定 | **版本必须与 `pubspec` 锁定的 `2.0.0-dev.0` 一致**（`dart pub global activate flutter_rust_bridge_codegen@2.0.0-dev.0`） |
| `build_runner` + `drift_dev` | 生成 `database.g.dart` | dev_dependencies 已声明 |
| Rust cdylib 的 C 链接链 | 编出 `libinksync_core.{dll,so}` | Windows 用 nightly+rust-lld；UOS 用 `cargo zigbuild …2.28`（见 `docs/04`） |
| **Rust crate `flutter-rust-bridge`** | `#[frb]` 宏来源 | **新增可选依赖**，`core/Cargo.toml` 加 `flutter-rust-bridge = { version = "2.0.0-dev.0", optional = true }` + `[features] frb = ["flutter-rust-bridge"]` |

## 3. 任务拆分（带依赖，已并入审核修订点）

### T1 · FFI 绑定打通（flutter_rust_bridge）— 阻塞一切
**现状**：`native_core.dart` 的 `CallbackNativeCore` 引用了尚未生成的 `InksyncCore`；`lib.rs` 没有 `#[frb]` 标注入口。

步骤：
1. `core/Cargo.toml`：加可选依赖 `flutter-rust-bridge = { version = "2.0.0-dev.0", optional = true }` 与 `frb = ["flutter-rust-bridge"]` feature（**修订 #5**）。
2. 新增 `core/src/api.rs`（**用 `#[cfg(feature = "frb")]` 门控**）：
   - `#[frb(init)] pub fn init_app()`；
   - `#[frb] pub async fn parse_book(path: String) -> Result<ParsedBookDto, String>` → 包裹 `crate::parse_book`；
   - 同理 `probe_book`、`read_internal_image`、`read_mobi_image`、`make_thumbnail`、`sha256_file`；
   - DTO：`ParsedBookDto { format, meta: MetaDto, chapters: Vec<RawChapterDto>, cover: Option<CoverDto>, pages: Option<Vec<String>>, isImageBook, totalChars, sha256, fileSize }`、`RawChapterDto { index, title, xhtml, plain, charStart, spineHref }`、`CoverDto { mime, data }`、`MetaDto { title, authors, … }`。
   - **关键（修订 #4）**：DTO 必须保持 `meta` / `cover` 嵌套（与现有 `CallbackNativeCore.parseBook` 的 `m['meta']['title']` / `m['cover']['data']` 取值一致），否则要重写适配器。二选一写死，本计划选「保持嵌套」。
3. `lib.rs` 加 `pub mod api;` 并 `#[cfg(feature="frb")]` 门控。
4. 加 `flutter_rust_bridge.yaml`（指向 `rust_input: core/src/api.rs`、`dart_output: app/lib/bridge/`、默认生成类名 `InksyncCore`）。
5. 你本机：`flutter_rust_bridge codegen generate` → `bridge_generated.dart` + `bridge_definitions.dart`。
6. `main.dart` 注入：`ProviderScope(overrides: [nativeCoreProvider.overrideWithValue(core)])`，`core = CallbackNativeCore(parse: (p) async => (await InksyncCore.parseBook(path: p)).toJson(), image: ..., hash: ..., mobi: (p, r) async => InksyncCore.readMobiImage(path: p, record: r))`。
7. 编 cdylib：`cargo build --features frb`（Windows 走 nightly+rust-lld），把 `.dll` 放到 `app/` 下 FFI 加载路径。

**验收（修订 R4.3）**：T1 完成定义 = 你本机 `flutter run` 起应用 + `parseBook` 返回真实章节（沙箱只保证 `api.rs` 在默认 features 下语法/结构正确）。

### T2 · drift 数据库生成
**现状**：`database.dart` 的 `AppDatabase` 等尚未 `build_runner` 生成 → 全项目引用都编不过。

步骤：
1. 核对 `@DriftDatabase(tables: [Books, Progresses, Collections, Memberships, Rules, Outbox, SyncStates, ConflictLog])` 与 `part 'database.g.dart';`（**修订 #7**：计划原写 `SyncState` 漏 `ConflictLog`，以代码为准，共 8 张）。
2. 确保 `providers.dart` 引用的自定义方法都存在：`getState/setState`、`watchLibrary`、`watchCollections`、`watchRules`、`pendingOutbox`、`lastAppliedHlc`、`SyncStateKeys`。缺的补全。
3. 你本机 `cd app && dart run build_runner build --delete-conflicting-outputs`。
4. `flutter analyze` 确认 `*.g.dart` 与手写代码对齐。

### T3 · Dart↔Rust 模型对齐（M1 改了 Rust，Dart 没跟上）— 高优先级正确性
| # | 漂移 | 修复 |
|---|------|------|
| 3.1 | Dart `ParsedBook.isComic` 只认 `cbz/cbr/pdf`，漏掉图片型 EPUB / MOBI 图片书 | Dart `ParsedBook` 加 `bool isImageBook`（取自 Rust `is_image_book`）；`reader_screen` 路由改用 `isImageBook`，保留 `isComic` 仅作格式判断辅助 |
| 3.2 | `NativeCore` 缺 `readMobiImage`，MOBI 漫画页会走错方法 | 接口加 `Future<Uint8List?> readMobiImage(String path, int record)`；`CallbackNativeCore` 接通；`_InlineImage` 对 `entry` 以 `pdb:` 开头时改调 `readMobiImage` |
| 3.3 | `RawChapter` 缺 `charStart`/`spineHref`；进度 anchor 未用 Rust 的 `char_start` | Dart `RawChapter` 加 `int charStart`、`String? spineHref`；`reader_screen` 进度恢复优先用 `charStart` 精确章节定位（健壮性增强，非阻塞） |
| 3.4 | 封面：Rust 返回 `coverBytes`，`_BookCard` 用 `Image.file(coverPath)` | **已确认采用 ① 字节→缓存文件→`cover_path`**：导入时把 `coverBytes` 写缓存目录、DB 记 `cover_path`、`_BookCard` 沿用 `Image.file` |
| 3.5（新增） | Dart `RuleKind` 无 `paren`；Rust `RuleKind` 有 `Paren`（（）/()） | Dart `RuleKind` 加 `paren`；`_regexSourceFor` 加分支 `(?:（[^）\n]*）|\([^)\n]*\))`；`Rules.kind` 兼容 `paren` 字符串 |

### T4 · 书架 UI 收尾（`library_screen.dart`）— **范围已收敛**
**确认范围**：导入 + 删除（标 `deleted` tombstone）+ 分组重排；编辑信息 / 自定义封面**推迟到 M3**。

- **导入流**（FAB → `/import` 当前是 placeholder）：`file_selector` 选文件 → `nativeCore.parseBook` + `sha256File` → 按 sha256 写入 `BlobStore` → 插 `books` 行 → 封面走 T3.4 缓存 → 回书架刷新。**需先确认 `BlobStore.write` API 存在**（T4 子步）。
- **导入成功 / 失败 UX**：不支持格式与解析异常给出提示空态（**修订 #1.2**）。
- **书籍操作底 sheet**：删除（写 `outbox` 墓碑，本地先标 `deleted`）；编辑信息/自定义封面留 TODO 占位。
- **分组重排**：`_CollectionsPane.onReorder` 补「改本地 sortOrder + 记 outbox」（现有 `SortController.reorder` 已可复用）。
- **修订 #6（按分组死功能）**：`watchLibrary` 的 join 需取 `collections.name` 填入 `BookWithProgress.collectionName`，否则 `GroupKey.collection` 全显示「未分组」；或在 M2 暂不暴露「按分组」维度。

### T5 · 阅读器收尾（`reader_screen.dart`）
- 应用 T3.1（isImageBook 路由）、T3.2（MOBI 页）、T3.3（charStart 恢复）、T3.4（封面）。
- **修订 #2（活 bug，必修）**：`reader/rules.dart` 的 `_regexSourceFor` 对 quote / bookTitleMark 改为 `$open[^$close\n]{1,400}?$close`（`[^close]` 排除 `\n`），与 Rust 单行不变量一致；并统一是否带长度上限（建议去掉上限，与 Rust 一致）。
- **修订 #1（R4.4 头号风险）**：Dart `RuleEngine._resolveOverlaps` 已是「区间切分 + 最高优先级」语义；**Rust 侧 `apply_rules` 已在 M2 准备阶段改为同一算法**（见下方「R4.4 统一进度」），两端靠 T7 等价测试锁死。

### T6 · 规则 UI 收尾（`rules_screen.dart`）
- CRUD 写 `RuleRow`；`RuleKind` 对齐（regex/quote/bookTitleMark/paren/personName），删除 `dialogue`/`keywordList` 或保留为 Dart-only（M2 内不影响显示，但 T7 测试只覆盖共有 5 类）。
- **修订 #1.1（首启 seed）**：首启写入 `RulePresets` 5 条，否则规则页空、演示落空。
- 与 T5 共用同一份「高亮语义」定义，抽注释块固化等价约束。

### T7 · 验证
- 你本机：`flutter analyze` 零错；`flutter test` 过 Dart 单测。
- **Dart 单测**（纯 Dart 行为）：`ContentParser` 白名单解析、`RuleEngine` 对 M1 Rust 用例的等价输出（单行 quote、优先级消解、person 边界、paren）。
- **双端一致性测试（关键，修订 #3）**：用同一本内置 EPUB，Rust `parse_book` 与 Dart `InksyncCore.parseBook` 比较 `chapters.len()`、`total_chars`、`char_start` 序列；高亮用例**仅限两端共有 5 类**（regex/quote/bookTitle/paren/person），确保 FFI DTO 没丢字段、算法一致。
- 手测：导入各格式一本，文本/漫画两条路径各跑一遍，规则增删即时生效。

### R4.4 统一进度（可在沙箱先行，已并入 M2 准备）
- Rust `highlight::apply_rules` 原实现是「贪心丢弃」，与 Dart「区间切分」语义不同 → 已在 M2 准备阶段把 Rust 改为**区间切分 + 最高优先级（平级按 rule_id 升序）**，与 Dart `_resolveOverlaps` 逐字节对齐。
- 同步更新 Rust 单测 `higher_priority_wins_on_overlap` 的预期（高优先赢重叠区、低优先保留不重叠前缀），并新增 Rust 侧与 Dart `RuleEngine` fixture 对应的对照用例。
- 沙箱可跑 `cargo test` 验证 Rust 侧（纯 Rust，无需 C 链 / Flutter）。

## 4. 已确认决策

- **R4.1 封面**：采用 ① 字节→缓存文件→`cover_path`（T3.4）。
- **R4.2 frb 版本**：`pubspec` 改为精确锁定 `flutter_rust_bridge: 2.0.0-dev.0`（去掉 `^`），`codegen` 装同版本；`core/Cargo.toml` 加同名可选依赖 + `frb` feature（T1/T2）。
- **M2 范围**：T4 收敛为「导入 + 删除 + 分组重排」，编辑信息 / 自定义封面推 M3。

## 5. 不在 M2 范围

- M3 同步引擎（`sync_engine.dart`/`webdav_client.dart`/`merge.dart` 已脚手架，但需 `sync` feature 的 Rust 侧 + WebDAV 真机，沙箱不可验）；
- M4 三端打包（Windows MSVC / UOS zigbuild 2.28 / Android NDK）、glibc 2.28 核验、deb 启动脚本导出 `GTK_IM_MODULE=fcitx`。
