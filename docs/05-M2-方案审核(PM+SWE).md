# 05 · M2 方案审核（产品经理 + 软件开发师 双视角）

> 状态：**审核稿**，已实地核对 `app/lib/**` 与 `core/src/**` 源码。待 Ryou 确认修订点后并回 `05-M2-Flutter实施计划.md` 再开工（遵循「先过一遍再动手」）。
>
> 硬约束：本沙箱无 Flutter SDK / C 链，M2 的 codegen / build / run 只能在你本机验；本审核只基于静态读码。

## 0. 结论速览

方案骨架**正确**：T1→T7 拆分与依赖合理，§1 验收标准可测。但**实际源码与计划存在 7 处未对齐**（其中 3 处是 R4.4 双端高亮一致性的致命点），另有 2 处文档/范围建议。建议在开工前把修订点并回计划，否则 T5/T7 会返工。

---

## 1. 产品经理视角

### 1.1 范围与验收
- 验收清单（§1）清晰、可测，覆盖空态 / 导入 / 文本 / 漫画 / 规则 / 双端测试六条，质量高。
- **缺项 · 首次启动规则预设种子**：代码已有 `RulePresets` 5 条（`reader/rules.dart`），但 DB 无 seed，首启规则页为空，演示「高亮即时生效」会落空。建议 T6 加「首启写入预设」。
- **缺项 · 导入失败 / 不支持格式**的空态与提示。验收只写了成功路径。

### 1.2 用户路径完整性
- **导入是整条 M2 的关键路径**：FAB → `/import` 当前是 placeholder。没有导入，其余都不演示得出来。计划把 T4 排在 T3 之后合理，但 PM 风险点：`file_selector` 三端行为 + BlobStore 落盘最易出问题，应作为「可运行」第一优先级验证。
- **书籍操作全为空操作**：`library_screen._BookCard._showBookActions` 4 项都是 `Navigator.pop`。对 M2「可本地运行」演示，最小可用集 = **导入 + 删除（标 `deleted`）+ 分组重排**；编辑信息 / 自定义封面建议**推迟到 M3**，以降 M2 风险。
- **封面方案 R4.1**：推荐 ① 字节→缓存文件→`cover_path`（`_BookCard` 已用 `Image.file(coverPath)`、网格省内存、漫画大封面尤甚）。内存方案需改 `_BookCard`，收益不大。

### 1.3 风险到交付
- T1（FFI）与 T2（drift）是阻塞链，任一卡住全盘停。R4.3（沙箱编不出 cdylib）意味着验证在你本机——建议在计划里补「T1 完成定义 = 你本机 `flutter run` 起应用 + `parseBook` 返回真实章节」。
- 整体 M2 风险**中等**，主要不在代码量，在**双端一致性（R4.4）+ 三端 file_selector 行为差异**。

---

## 2. 软件开发师视角（已实地读码）

> 已读：`native_core` / `database` / `reader/{content,highlight,rules}` / `screens/{library,reader}` / `state/providers` / `core/src/{lib,model,highlight}` / `pubspec.yaml`。

### 🔴 #1 两套重叠消解算法不一致（R4.4 头号风险，计划低估）
Rust `highlight::apply_rules` 与 Dart `RuleEngine._resolveOverlaps` 是**两种不同算法**：
- **Rust**：按 `(priority↓, start↑)` 排序后**贪心丢弃**——遇到与已选区间重叠的候选直接跳过（即使其尾部不重叠也整条丢）。
- **Dart**：先把所有命中端点做**区间切分**，每个最小子区间取覆盖它的**最高优先级**规则，再合并相邻同规则区间。

后果：同文本 + 同规则集，两端产出的高亮区间**可能不同**（尤其两条重叠且优先级不同的规则）。计划 T5 只写「priority 消解」，没锁定统一算法。
**修订**：固化**唯一规范算法**（建议采用 Dart 的「区间切分 + 最高优先级」语义，更贴合「互不重叠低优先级仍保留」预期），Rust 侧 `apply_rules` 同步改成同一实现；并补一条两端共用的对照 fixture。

### 🔴 #2 Dart 引号/书名号正则当前是「多行」的（活 bug，与 Rust 单行语义相反）
- Rust：`RuleKind::Quote` = `"(?:"[^"\n]*"|“[^”\n]*”|「[^」\n]*」|『[^』\n]*』)"`、`BookTitle` = `《[^》\n]*》`——显式排除 `\n`，缺失闭引号**不跨行吞整段**（M1 不变量 `quote_does_not_cross_lines`）。
- Dart `_regexSourceFor`（quote / bookTitleMark）：`$open[^$close]{1,400}?$close`，`[^close]` **不排除 `\n`**，且上限 400 与 Rust 无上限不同 → 缺闭引号时会跨行吞文本。

这是计划 R4.4 警告的「同一本书两端高亮不一样」**已经在骨架里发生**。
**修订**：Dart 改为 `[^close\n]`（与 Rust 一致），并统一是否带长度上限。

### 🔴 #3 RuleKind 漂移计划低估：Rust 有 `paren`、Dart 没有；Dart 有 `dialogue/keywordList`、Rust 没有
- Rust `RuleKind`：Regex / Quote / BookTitle / **Paren** / Person（5）。
- Dart `RuleKind`：regex / quote / bookTitleMark / personName / **dialogue** / **keywordList**（6）。

具体：
- **Rust `Paren`（（）/()）在 Dart 无对应** → 含括号高亮的文本书在 Dart 端完全不渲染。需补 Dart `RuleKind.paren` + 正则 `(?:（[^）\n]*）|\([^)\n]*\))`。
- `bookTitleMark`↔`BookTitle`、`personName`↔`Person` 仅命名差异；DB `Rules.kind` 存 Dart 名，M3 Rust↔Dart 规则 DTO 需映射表（M2 暂不涉及，但 T6 应记一笔）。
- `dialogue`/`keywordList` Rust 无——M2 阅读器只用 Dart 引擎，M2 内不影响显示；但 **T7 双端一致性测试必须限定在两端共有的 5 类**（regex/quote/bookTitle/paren/person），否则测不到真一致。

### 🟡 #4 DTO ↔ `CallbackNativeCore` 适配器形状不匹配（T1 隐性坑）
- Rust `ParsedBook` = `{ meta:{title,authors…}, cover:{data,mime}, chapters:[…], sha256, isImageBook, … }`（带 `meta`/`cover` 嵌套）。
- 计划 T1 的 `ParsedBookDto` 写成**扁平** `{ format, title, authors, cover:{mime,data}, … }`。
- 但现有 `CallbackNativeCore.parseBook` 按 `m['meta']['title']`、`m['meta']['authors']`、`m['cover']['data']` 取值。

→ 生成的 DTO `.toJson()` 与现有适配器**对不上**，要么 T1 让 DTO 保持 `meta`/`cover` 嵌套，要么重写适配器。计划没点明，T1 易返工。
**修订**：T1 显式规定 DTO 字段布局 + 适配器改法，二选一写死。

### 🟡 #5 `flutter_rust_bridge` 版本必须「锁死」而非 `^`（R4.2 升级为硬性）
`pubspec` 写 `flutter_rust_bridge: ^2.0.0-dev.0`。`^` 会解析到 **2.0.0 正式版**，而 2.0.0 的 codegen 宏 API 与 `2.0.0-dev.0` 不同（计划自己也写「若版本漂移再调」）。这是 T1 codegen 的隐性爆点。
**修订**：改为**精确锁定**（如 `flutter_rust_bridge: 2.0.0-dev.0` 或你本机已验证版本），并在 `core/Cargo.toml` 加同名 Rust crate **可选依赖 + `frb` feature**（否则 `#[frb]` 宏路径在 `--features frb` 下仍无来源）。

### 🟡 #6 按分组（collection）的 `collectionName` 永远为 null（T4 死功能）
`AppDatabase.watchLibrary` 的 join 只读 `books`+`progresses`，**没取 collections 名称**；`BookWithProgress.collectionName` 恒为 null → `GroupKey.collection` 全显示「未分组」。要么 join 取 name，要么 M2 先不暴露「按分组」维度。T4 分组重排依赖它，需先修。

### 🟡 #7 T2 表清单与代码不符（文档错误，非代码错）
计划写 `tables:[Books,Progresses,Collections,Memberships,Rules,Outbox,SyncState]`，实际是 8 张且含 `ConflictLog`、`SyncStates`（复数）。`part 'database.g.dart'` 与所需自定义方法都在，T2 step1/2 检查能通过——但计划漏了 `ConflictLog`，写定稿时对齐。

### 🟢 #8 进度恢复（T3.3）是健壮性增强，非阻塞
当前 `_load` 按 `chapter`+`fraction` 恢复，已可用；`char` 字段 = 各章 plain 累加，恰等于 Rust `char_start` 语义。加 `RawChapter.charStart/spineHref` 是为跨端 anchor 更稳，建议保留但排低优先级。

### 2.1 已核对正确、无需改（给你信心）
- `RawChapterDto` 字段 `charStart/spineHref` ↔ Rust `char_start/spine_href` 一一对应（camelCase 一致）✓
- `reader_screen` 路由改 `isImageBook`、`_InlineImage` 加 `pdb:`→`readMobiImage` 分支、T3.1/3.2 方向正确 ✓
- `ruleSetProvider` 是 `Provider`，随 `rawRulesProvider` 变自动重算；`reader` 的 `build` 里 `ref.watch(ruleSetProvider)` → 规则增删**即时反映**已成立 ✓
- `BookFormat` 两端枚举名一致，DTO 可直映 ✓
- `nativeCoreProvider` 默认 `UnimplementedNativeCore`，T1 须在 `main` 用 `overrideWithValue` 注入真实 `InksyncCore` ✓（计划已含）

---

## 3. 建议并回计划的修订点（开工前）

1. T5/T7 前增「**统一重叠消解算法**」子任务（采用区间切分语义，Rust 同步改）。#1
2. T5 增「**Dart 引号/书名号正则加 `\n` 排除**」子任务，对齐 Rust 单行不变量。#2
3. T3 + T6 增「**Dart 补 `paren` 规则**」，并规定 T7 一致性测试仅覆盖共有 5 类。#3
4. T1 显式规定 **DTO 字段布局 + CallbackNativeCore 适配器改法**（保持 `meta`/`cover` 嵌套或重写）。#4
5. T1 把 frb 版本**精确锁定**，并在 `Cargo.toml` 加可选依赖 + `frb` feature。#5
6. T4 修 `watchLibrary` 取 `collectionName`，或 M2 暂不暴露「按分组」。#6
7. T6 加「**首启 seed 预设规则**」；导入成功/失败路径都补 UX。#1.1 / #1.2
8. T4 范围收敛为「导入 + 删除（标 tombstone）+ 分组重排」，编辑信息 / 自定义封面推 M3。
9. 文档：T2 表清单补 `ConflictLog` / `SyncStates`。#7

---

## 4. 待 Ryou 确认的两个决策

- **R4.1 封面**：默认按 ① 文件缓存（推荐）。
- **R4.2 frb 版本**：默认精确锁定 `2.0.0-dev.0`（或你本机已验证版本）（推荐）。
