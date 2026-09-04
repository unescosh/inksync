#![cfg(feature = "frb")]

//! `flutter_rust_bridge` 绑定入口。
//!
//! 全部用 `#[cfg(feature = "frb")]` 门控：默认纯 Rust 构建（沙箱可验）不受影响，
//! 只有 `cargo build --features frb` 才会编进 FFI。
//!
//! **两套 API，刻意的冗余：**
//!
//! 1. 结构化 API（[`parse_book`] / [`probe_book`] 返回 [`ParsedBookDto`]）——
//!    零 JSON 开销，性能最好，但 Dart 侧要引用 codegen 生成的类名与字段名，
//!    frb 版本升级时字段命名策略若变化会连带改 UI 代码。
//! 2. JSON API（[`parse_book_json`] / [`probe_book_json`] 返回字符串）——
//!    Dart 侧只 `jsonDecode` 成 `Map`，喂给 `CallbackNativeCore`，
//!    **不依赖任何生成类**。字段名由本文件的 serde 契约锁定，跨 frb 版本稳定。
//!
//! 目前 `main.dart` 走第 2 条（见 `app/lib/main.dart`）。第 1 条保留给将来
//! 大书解析要压掉 JSON 开销时切换。
//!
//! 封面处理遵循 M2 决策①「字节 → 缓存文件 → `cover_path`」：
//! · [`probe_book_json`]：**含**封面字节（导入时只调一次）
//! · [`parse_book_json`]：**不含**封面字节（阅读器每次开书都调，不能白传 MB 级数据）
//!
//! 类型选择：所有整数走 `i32` / `i64`，不用 `usize` / `u64` —— frb 对
//! `usize`/`u64` 在不同版本里有映射成 `BigInt` 的历史，`i64` 稳定映射 Dart `int`。

use crate::model::*;
use flutter_rust_bridge::frb;
use serde::Serialize;
use std::path::Path;

/// 初始化 FFI。frb 会在 Dart 侧首次调用前自动执行本函数。
#[frb(init)]
pub fn init_app() {}

// ─────────────────────────── JSON API（main.dart 使用） ───────────────────────────

/// 解析整本书 → JSON 字符串。**不含封面字节**（封面在导入时已落盘为 `cover_path`）。
pub fn parse_book_json(path: String) -> Result<String, String> {
    let book = crate::parse_book(&path).map_err(|e| e.to_string())?;
    let json = JsonBook::from_book(book, false);
    serde_json::to_string(&json).map_err(|e| e.to_string())
}

/// 只抽元数据 + 封面 → JSON 字符串。**含封面字节**（导入用，每本只调一次）。
pub fn probe_book_json(path: String) -> Result<String, String> {
    let book = crate::probe_book(&path).map_err(|e| e.to_string())?;
    let json = JsonBook::from_book(book, true);
    serde_json::to_string(&json).map_err(|e| e.to_string())
}

// ─────────────────────────── 图片 / 杂项 ───────────────────────────

/// 从 EPUB/CBZ 容器内读取一张图片（章节插图、漫画页）。
pub fn read_internal_image(path: String, entry: String) -> Result<Vec<u8>, String> {
    crate::read_internal_image(&path, &entry).map_err(|e| e.to_string())
}

/// 读取 MOBI/AZW3 图片书的一页，`record` 对应 `pages` 里的 `pdb:<index>`。
pub fn read_mobi_image(path: String, record: i32) -> Result<Vec<u8>, String> {
    if record < 0 {
        return Err("record 不能为负".to_string());
    }
    crate::read_mobi_image(&path, record as u32).map_err(|e| e.to_string())
}

/// 生成封面缩略图（统一尺寸，减小同步体积）。
pub fn make_thumbnail(data: Vec<u8>, max_w: i32, max_h: i32) -> Result<Vec<u8>, String> {
    crate::make_thumbnail(&data, max_w.max(1) as u32, max_h.max(1) as u32).map_err(|e| e.to_string())
}

/// 流式计算 sha256（书籍可能几百 MB，绝不整体读入内存）。
pub fn sha256_file(path: String) -> Result<String, String> {
    crate::sha256_file(Path::new(&path)).map_err(|e| e.to_string())
}

// ─────────────────────────── 结构化 API（备用通道） ───────────────────────────

/// 解析一本书，返回结构化结果（不走 JSON）。
pub fn parse_book(path: String) -> Result<ParsedBookDto, String> {
    crate::parse_book(&path)
        .map(ParsedBookDto::from)
        .map_err(|e| e.to_string())
}

/// 只抽元数据 + 封面（导入预览用，避免解析整本大书）。
pub fn probe_book(path: String) -> Result<ParsedBookDto, String> {
    crate::probe_book(&path)
        .map(ParsedBookDto::from)
        .map_err(|e| e.to_string())
}

// ─────────────────────────── JSON 契约 ───────────────────────────
//
// 字段名即 Dart 侧 `CallbackNativeCore.parseBook` 读取的键，**改这里必须同步改
// app/lib/core/native_core.dart**。保持 `meta` / `cover` 嵌套。

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct JsonMeta {
    title: String,
    subtitle: Option<String>,
    authors: Vec<String>,
    publisher: Option<String>,
    language: Option<String>,
    description: Option<String>,
    series: Option<String>,
    series_index: Option<f32>,
    tags: Vec<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct JsonCover {
    mime: String,
    /// 字节数组。仅 `probe_book_json` 填充；`parse_book_json` 恒为空。
    data: Vec<u8>,
    /// 原始字节长度。即使 `data` 被省略也能让 UI 知道"有封面"。
    size: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct JsonChapter {
    index: i32,
    title: String,
    xhtml: String,
    plain: String,
    char_start: i64,
    spine_href: Option<String>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct JsonBook {
    format: String,
    meta: JsonMeta,
    chapters: Vec<JsonChapter>,
    cover: Option<JsonCover>,
    pages: Option<Vec<String>>,
    is_image_book: bool,
    total_chars: i64,
    sha256: String,
    file_size: i64,
}

impl JsonBook {
    fn from_book(b: ParsedBook, with_cover_bytes: bool) -> Self {
        JsonBook {
            format: fmt_str(b.format),
            meta: JsonMeta {
                title: b.meta.title,
                subtitle: b.meta.subtitle,
                authors: b.meta.authors,
                publisher: b.meta.publisher,
                language: b.meta.language,
                description: b.meta.description,
                series: b.meta.series,
                series_index: b.meta.series_index,
                tags: b.meta.tags,
            },
            chapters: b
                .chapters
                .into_iter()
                .map(|c| JsonChapter {
                    index: c.index as i32,
                    title: c.title,
                    xhtml: c.xhtml,
                    plain: c.plain,
                    char_start: c.char_start as i64,
                    spine_href: c.spine_href,
                })
                .collect(),
            cover: b.cover.map(|c| {
                let size = c.data.len() as i64;
                JsonCover {
                    mime: c.mime,
                    data: if with_cover_bytes { c.data } else { Vec::new() },
                    size,
                }
            }),
            pages: b.pages,
            is_image_book: b.is_image_book,
            total_chars: b.total_chars as i64,
            sha256: b.sha256,
            file_size: b.file_size as i64,
        }
    }
}

// ─────────────────────────── 结构化 DTO ───────────────────────────

#[derive(Clone)]
pub struct MetaDto {
    pub title: String,
    pub subtitle: Option<String>,
    pub authors: Vec<String>,
    pub publisher: Option<String>,
    pub language: Option<String>,
    pub description: Option<String>,
    pub series: Option<String>,
    pub series_index: Option<f32>,
    pub tags: Vec<String>,
}

#[derive(Clone)]
pub struct CoverDto {
    pub mime: String,
    pub data: Vec<u8>,
}

#[derive(Clone)]
pub struct RawChapterDto {
    pub index: i32,
    pub title: String,
    pub xhtml: String,
    pub plain: String,
    pub char_start: i64,
    pub spine_href: Option<String>,
}

#[derive(Clone)]
pub struct ParsedBookDto {
    pub format: String,
    pub meta: MetaDto,
    pub chapters: Vec<RawChapterDto>,
    pub cover: Option<CoverDto>,
    pub pages: Option<Vec<String>>,
    pub is_image_book: bool,
    pub total_chars: i64,
    pub sha256: String,
    pub file_size: i64,
}

impl From<ParsedBook> for ParsedBookDto {
    fn from(b: ParsedBook) -> Self {
        ParsedBookDto {
            format: fmt_str(b.format),
            meta: MetaDto {
                title: b.meta.title,
                subtitle: b.meta.subtitle,
                authors: b.meta.authors,
                publisher: b.meta.publisher,
                language: b.meta.language,
                description: b.meta.description,
                series: b.meta.series,
                series_index: b.meta.series_index,
                tags: b.meta.tags,
            },
            chapters: b
                .chapters
                .into_iter()
                .map(|c| RawChapterDto {
                    index: c.index as i32,
                    title: c.title,
                    xhtml: c.xhtml,
                    plain: c.plain,
                    char_start: c.char_start as i64,
                    spine_href: c.spine_href,
                })
                .collect(),
            cover: b.cover.map(|c| CoverDto {
                mime: c.mime,
                data: c.data,
            }),
            pages: b.pages,
            is_image_book: b.is_image_book,
            total_chars: b.total_chars as i64,
            sha256: b.sha256,
            file_size: b.file_size as i64,
        }
    }
}

fn fmt_str(f: BookFormat) -> String {
    match f {
        BookFormat::Epub => "epub",
        BookFormat::Mobi => "mobi",
        BookFormat::Azw3 => "azw3",
        BookFormat::Txt => "txt",
        BookFormat::Pdf => "pdf",
        BookFormat::Cbz => "cbz",
        BookFormat::Cbr => "cbr",
        BookFormat::Unknown => "unknown",
    }
    .to_string()
}
