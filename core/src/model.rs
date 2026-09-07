use serde::{Deserialize, Serialize};

/// 支持的书籍格式
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum BookFormat {
    Epub,
    Mobi,
    Azw3,
    Txt,
    Pdf,
    Cbz,
    Cbr,
    Unknown,
}

impl BookFormat {
    pub fn is_comic(&self) -> bool {
        matches!(self, Self::Cbz | Self::Cbr | Self::Pdf)
    }
    pub fn is_text(&self) -> bool {
        matches!(self, Self::Epub | Self::Txt | Self::Mobi | Self::Azw3)
    }
}

/// 从扩展名推断格式
pub fn format_from_ext(ext: &str) -> BookFormat {
    match ext.to_ascii_lowercase().as_str() {
        "epub" => BookFormat::Epub,
        "mobi" | "azw" | "kf8" => BookFormat::Mobi,
        "azw3" => BookFormat::Azw3,
        "txt" | "text" => BookFormat::Txt,
        "pdf" => BookFormat::Pdf,
        "cbz" | "zip" => BookFormat::Cbz,
        "cbr" | "rar" => BookFormat::Cbr,
        _ => BookFormat::Unknown,
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BookMeta {
    pub title: String,
    pub subtitle: Option<String>,
    pub authors: Vec<String>,
    pub publisher: Option<String>,
    pub language: Option<String>,
    pub description: Option<String>,
    /// (scheme, value)，例如 ("isbn", "9787...")、("calibre", "uuid")
    pub identifiers: Vec<(String, String)>,
    pub series: Option<String>,
    pub series_index: Option<f32>,
    pub published: Option<String>,
    pub tags: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TocEntry {
    pub title: String,
    /// EPUB: zip 内路径（可能带 #fragment）；TXT/MOBI: None，用 `pos` 定位
    pub href: Option<String>,
    pub level: u32,
    pub children: Vec<TocEntry>,
}

/// 归一化后的章节。
/// `xhtml` 只含白名单标签（p/br/h1-h6/blockquote/em/strong/img/hr），
/// Dart 侧用一个极小的解析器即可还原为可渲染的 InlineSpan。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RawChapter {
    pub index: usize,
    pub title: String,
    pub xhtml: String,
    /// 纯文本，供搜索、TXT 渲染、进度估算
    pub plain: String,
    /// 文本书：该章在「所有章节 `plain` 顺序拼接」后的纯文本视图中的起始字符偏移，
    /// 用于把阅读位置换算成 `(spine, offset)` 进度。
    /// 锚定在**拼接 plain 视图**上（不是 xhtml —— xhtml 含标签字符，偏移不可比），
    /// 即 `offset == char_start + 章内 plain 位置`，取值范围 `[0, ParsedBook.total_chars)`。
    /// 漫画/图片书无意义，填 0。
    pub char_start: usize,
    /// 文本书：spine 内路径（EPUB 为 OPF 相对路径；TXT/MOBI 文本书为 None）。
    /// 用于 CFI 精确定位；漫画/图片书为 None。
    pub spine_href: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CoverImage {
    pub data: Vec<u8>,
    pub mime: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ParsedBook {
    pub format: BookFormat,
    pub meta: BookMeta,
    pub toc: Vec<TocEntry>,
    pub chapters: Vec<RawChapter>,
    pub cover: Option<CoverImage>,
    /// 原文件 sha256（内容寻址 / 同步去重）
    pub sha256: String,
    pub file_size: u64,
    /// CBZ/PDF/EPUB 图片书/MOBI 图片书的页序（zip 内路径或 PDB 图片记录序号）；文本格式为 None
    pub pages: Option<Vec<String>>,
    /// 是否图片书（漫画 / 扫描 PDF / 图片型 EPUB / MOBI 图片书）。
    /// 决定进度走 `page_index`（true）还是 `(spine, char_offset)`（false）。
    pub is_image_book: bool,
    /// 文本书：整本归一化纯文本的总字符数（进度 percent 换算用）；图片书为 0。
    pub total_chars: usize,
}

impl Default for ParsedBook {
    fn default() -> Self {
        Self {
            format: BookFormat::Unknown,
            meta: BookMeta::default(),
            toc: Vec::new(),
            chapters: Vec::new(),
            cover: None,
            sha256: String::new(),
            file_size: 0,
            pages: None,
            is_image_book: false,
            total_chars: 0,
        }
    }
}

/// 阅读进度快照（同步实体 `d` 的载荷之一）。
/// 按格式分两类，避免小说 / 漫画混用同一个主键：
/// - `Char`：小说 / TXT / reflow EPUB，`spine` 为章节路径（TXT 为 None），
///   `offset` 为字符偏移（锚定在「拼接 plain 视图」，= `char_start + 章内位置`）；
/// - `Page`：漫画 / PDF / 图片书，`index` 为页序，`zoom`/`scroll` 为该页视图状态。
/// `percent` 仅作各端展示换算，不作为同步主键（合并主键为 spine+offset 或 index）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ReadProgress {
    Char {
        /// 文本书：spine 路径（EPUB 为 OPF 相对路径；TXT/MOBI 为 None）。
        spine: Option<String>,
        /// 绝对字符偏移 = 对应章节 `char_start` + 章内 `plain` 位置；
        /// 锚定在「所有章节 plain 顺序拼接」的纯文本视图上（非 xhtml），
        /// 取值落在 `[0, ParsedBook.total_chars)`。
        offset: usize,
        /// 仅展示用：相对阅读进度百分比，不进同步主键。
        percent: f32,
    },
    Page {
        index: usize,
        zoom: f32,
        scroll: f32,
        percent: f32,
    },
}

// ─────────────────────────── 高亮规则 ───────────────────────────

/// 高亮规则种类（详见 `core::highlight`）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RuleKind {
    Regex,
    Quote,
    BookTitle,
    Paren,
    Person,
}

/// 一条自定义高亮规则。持久化在本地 SQLite，随 WebDAV `changes` 三端同步。
/// `person` 类型的 `pattern` 存逗号/顿号/换行分隔的人名名单，核心编译为正则；
/// 其余类型的 `pattern`：`regex` 即正则源，quote/booktitle/paren 忽略 `pattern`。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HighlightRule {
    pub id: String,
    pub name: String,
    pub kind: RuleKind,
    pub pattern: String,
    /// 高亮色 `#RRGGBB`
    pub color: String,
    /// 重叠消解优先级，越大越优先
    pub priority: i32,
    pub enabled: bool,
}

// ─────────────────────────── 同步相关模型 ───────────────────────────

/// 一次同步中上传的变更批次
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "t", rename_all = "camelCase")]
pub enum ChangeRecord {
    Book {
        id: String,
        #[serde(flatten)]
        body: ChangeBody,
    },
    Progress {
        id: String,
        #[serde(flatten)]
        body: ChangeBody,
    },
    Rule {
        id: String,
        #[serde(flatten)]
        body: ChangeBody,
    },
    Collection {
        id: String,
        #[serde(flatten)]
        body: ChangeBody,
    },
    Membership {
        id: String,
        #[serde(flatten)]
        body: ChangeBody,
    },
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ChangeBody {
    /// upsert | delete
    pub op: Op,
    /// 混合逻辑时钟，字典序即全序
    pub hlc: String,
    /// 产生这条变更的设备 ID（8 位 hex）
    pub node: String,
    /// 实体完整快照（upsert 时）；delete 时为 null
    pub d: Option<serde_json::Value>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Op {
    Upsert,
    Delete,
}

/// 远端清单
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub schema: u32,
    pub last_hlc: String,
    pub files: Vec<ManifestFile>,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ManifestFile {
    /// changes/ 下的文件名
    pub n: String,
    pub b: u64,
    pub d: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WebDavConfig {
    pub base_url: String,
    pub username: String,
    pub password: String,
    /// 信任自签名证书
    pub accept_invalid_certs: bool,
    pub user_agent: Option<String>,
}

/// 同步结果报告（给 UI 展示）
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncReport {
    pub pulled_changes: u32,
    pub pushed_changes: u32,
    pub uploaded_books: u32,
    pub downloaded_books: u32,
    /// 封面图片跨端传输计数（与 Dart 引擎 SyncReport 对齐；
    /// 由 `core::sync::transfer::transfer_covers` 在 Rust 原生同步路径下产出）
    pub uploaded_covers: u32,
    pub downloaded_covers: u32,
    pub conflicts: u32,
    pub errors: Vec<String>,
    pub new_last_hlc: String,
}
