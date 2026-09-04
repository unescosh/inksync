# inksync · 三端同步漫画/小说阅读器

> Android · Windows 10 · 统信 UOS 20（1070 / kernel 4.19）
> 一套 Dart 代码 + 一个 Rust 原生核心，WebDAV 多端同步。

## 目录说明

```
inksync/
├─ docs/          实现方案（选型 / 同步协议 / 三端适配）
├─ core/          Rust 原生核心：格式解析、元数据与封面抽取、WebDAV 客户端、HLC 与冲突合并
└─ app/           Flutter 应用：UI、本地库（Drift/SQLite）、同步引擎、高亮规则引擎
```

## 为什么是 Flutter + Rust

| 候选 | Android | Win10 | UOS 20 | 结论 |
|---|---|---|---|---|
| **Flutter 3.22+** | 稳定 | 稳定 | **官方支持 Linux desktop** | ✅ 一套代码、自绘 UI，自定义高亮/排版完全可控 |
| Qt 6 (QML) | 支持弱 | ✅ | ✅（UOS 生态最亲和） | ❌ 移动端拖累、开发效率低 |
| Electron / Tauri | ❌ | ✅ | ✅ | ❌ 无 Android |
| Compose Multiplatform | ✅ | ✅ | ✅(JVM) | ⚠️ 需预装 JRE，包体与启动慢 |
| .NET MAUI | ✅ | ✅ | ❌ | ❌ Linux 无官方支持 |

**Flutter 的额外优势**：阅读器不依赖 WebView。
EPUB 解析后由 Flutter 直接排 `RichText`，因此：① 自定义高亮规则可以精确到字符区间；② 三端渲染结果像素级一致（Windows 是 WebView2、UOS 是 WebKitGTK，版本差异巨大，走 WebView 必然踩坑）；③ 阅读进度可以按「字符偏移」计算，才能跨端同步到同一句话。

**为什么还需要 Rust 核心**：Dart 生态在 MOBI/AZW3（HUFF-CDIC 解压）、GBK/Big5 编码嗅探、PDF 文本层抽取上没有成熟库，而 Rust 有 `mobi` / `encoding_rs` / `pdfium-render`，且能编译出 Android `.so`、Windows `.dll`、Linux `.so`，正好补齐三端。

## 支持的格式

| 格式 | 解析位置 | 说明 |
|---|---|---|
| EPUB 2 / 3 | Rust（`zip` + `roxmltree`） | OPF/NCX/nav.xhtml，输出归一化 XHTML |
| TXT | Rust | BOM → `chardetng` 嗅探 → 中文默认 GBK；正则分章 |
| MOBI / AZW3 (KF7/KF8) | Rust（`mobi` crate） | PalmDOC + HUFF-CDIC 解压、EXTH 元数据 |
| PDF | 渲染 `pdfrx`(PDFium)，文本层 Rust（`pdfium-render`） | 漫画/扫描版主力格式 |
| CBZ | Rust（`zip`） | 自然序排页，首图即封面 |
| CBR | ⚠️ 受限 | RAR 为商业格式，建议转 CBZ 或集成 `unarr` |

## 快速开始

```bash
# 1. 构建原生核心
cd core && cargo build --release

# 2. 生成 FFI 绑定（需 flutter_rust_bridge_codegen）
flutter_rust_bridge_codegen generate --watch

# 3. 运行（三端任选）
cd app && flutter run -d windows      # Windows 10
cd app && flutter run -d linux        # UOS 20 / 任意 glibc>=2.28 发行版
cd app && flutter run -d <android-id> # Android
```

> **UOS 前置检查**：先执行 `uname -m`。若为 `loongarch64` / `mips64`，Flutter 无官方支持，需走 `docs/03` 中的降级方案（Qt + 复用 Rust 核心）。
