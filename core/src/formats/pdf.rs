use std::fs;
use std::path::Path;

use crate::error::Result;
use crate::formats::split_persons;
use crate::model::*;

/// PDF 的定位：**渲染交给 Dart 侧的 `pdfrx`(PDFium)，本模块只负责元数据与文本层**。
///
/// - 文本层（搜索 / 高亮规则 / 进度 anchor）需要 `pdf-text` feature（依赖 pdfium 动态库）；
/// - 不开启该 feature 时，元数据走轻量字节扫描，功能降级但不会崩。
///
/// 三端部署 pdfium 二进制：
///   Android → `jniLibs/<abi>/libpdfium.so`
///   Windows → 与 exe 同目录 `pdfium.dll`
///   UOS     → `/opt/inksync/lib/libpdfium.so`（在启动脚本里 `LD_LIBRARY_PATH`）
pub fn parse(path: &Path) -> Result<ParsedBook> {
    let raw = fs::read(path)?;
    let stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("未命名")
        .to_string();

    let mut meta = scan_info_dict(&raw).unwrap_or(BookMeta { title: stem, ..Default::default() });
    if meta.title.trim().is_empty() {
        meta.title = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("未命名")
            .to_string();
    }

    #[cfg(feature = "pdf-text")]
    let (cover, page_count) = {
        let c = render_first_page_thumb(path).ok();
        let n = page_count_pdfium(path).unwrap_or(0);
        (c, n)
    };
    #[cfg(not(feature = "pdf-text"))]
    let (cover, page_count) = (None, count_pages_crude(&raw));

    Ok(ParsedBook {
        format: BookFormat::Pdf,
        meta,
        toc: Vec::new(),
        // PDF 由 pdfrx 直接按页渲染，不生成文本章节；
        // 若用户开启"文本模式"，Dart 侧调用 extract_page_text() 逐页取文本
        chapters: Vec::new(),
        cover,
        sha256: String::new(),
        file_size: raw.len() as u64,
        pages: Some((0..page_count).map(|i| i.to_string()).collect()),
        // PDF 一律按图片书处理，进度走 page_index
        is_image_book: true,
        total_chars: 0,
    })
}

/// 粗扫 `/Info` 字典里的 `/Title`、`/Author`（PDF 字符串可能是 UTF-16BE 或 latin1）
fn scan_info_dict(raw: &[u8]) -> Option<BookMeta> {
    let text = String::from_utf8_lossy(raw);
    let start = text.find("/Info")?;
    let window = &text[start..(start + 4096).min(text.len())];

    Some(BookMeta {
        title: pdf_string(window, "Title")?,
        authors: pdf_string(window, "Author")
            .as_deref()
            .map(split_persons)
            .unwrap_or_default(),
        publisher: pdf_string(window, "Producer"),
        description: pdf_string(window, "Subject"),
        ..Default::default()
    })
}

fn pdf_string(window: &str, key: &str) -> Option<String> {
    let needle = format!("/{key}");
    let pos = window.find(&needle)?;
    let rest = &window[pos + needle.len()..];
    let rest = rest.trim_start();
    // (...)  字面字符串
    if let Some(after) = rest.strip_prefix('(') {
        let end = after.find(')')?;
        return Some(decode_pdf_literal(&after[..end]));
    }
    // <...> 十六进制字符串（常见 UTF-16BE）
    if let Some(after) = rest.strip_prefix('<') {
        let end = after.find('>')?;
        let hex: String = after[..end].chars().filter(|c| c.is_ascii_hexdigit()).collect();
        if hex.len() % 4 == 0 && hex.starts_with("FEFF") {
            let u16s: Vec<u16> = hex
                .as_bytes()
                .chunks(4)
                .filter_map(|c| std::str::from_utf8(c).ok())
                .filter_map(|s| u16::from_str_radix(s, 16).ok())
                .skip(1)
                .collect();
            let s = String::from_utf16_lossy(&u16s);
            return Some(s.trim().to_string());
        }
        let bytes: Vec<u8> = (0..hex.len() / 2)
            .filter_map(|i| u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).ok())
            .collect();
        return Some(String::from_utf8_lossy(&bytes).trim().to_string());
    }
    None
}

fn decode_pdf_literal(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\\' {
            match chars.next() {
                Some('n') => out.push('\n'),
                Some('r') => out.push('\r'),
                Some('t') => out.push('\t'),
                Some('(') => out.push('('),
                Some(')') => out.push(')'),
                Some('\\') => out.push('\\'),
                Some(o) if o.is_digit(8) => {
                    let mut oct = String::from(o);
                    for _ in 0..2 {
                        if let Some(d) = chars.next() {
                            if d.is_digit(8) {
                                oct.push(d);
                            } else {
                                break;
                            }
                        }
                    }
                    if let Ok(v) = u8::from_str_radix(&oct, 8) {
                        out.push(v as char);
                    }
                }
                Some(o) => out.push(o),
                None => {}
            }
        } else {
            out.push(c);
        }
    }
    out.trim().to_string()
}

/// 未启用 pdf-text 时的页数估算：统计 `/Type /Page`(非 Pages) 出现次数
fn count_pages_crude(raw: &[u8]) -> u32 {
    let text = String::from_utf8_lossy(raw);
    let mut n = 0u32;
    for m in text.split("/Type").skip(1) {
        let seg: String = m.chars().take(40).collect();
        let compact: String = seg.chars().filter(|c| !c.is_whitespace()).collect();
        if compact.starts_with("/Page") && !compact.starts_with("/Pages") {
            n += 1;
        }
    }
    n
}

// ─────────────────── 以下需要 feature = "pdf-text" ───────────────────

/// 用首页渲染缩略图作为封面（扫描版 PDF 没有内嵌图片时这是唯一办法）
#[cfg(feature = "pdf-text")]
pub fn render_first_page_thumb(path: &Path) -> Result<CoverImage> {
    use pdfium_render::prelude::*;
    let pdfium = Pdfium::new(bindings()?);
    let doc = pdfium
        .load_pdf_from_file(path, None)
        .map_err(|e| Error::Pdf(e.to_string()))?;
    let page = doc
        .pages()
        .get(0)
        .map_err(|e| Error::Pdf(e.to_string()))?;
    let render = page
        .render_with_config(&PdfRenderConfig::new().set_target_width(600))
        .map_err(|e| Error::Pdf(e.to_string()))?;
    let image: image::DynamicImage = render
        .as_image()
        .into_rgb8()
        .into();
    let mut out = Vec::new();
    image
        .write_to(&mut std::io::Cursor::new(&mut out), image::ImageFormat::Jpeg)
        .map_err(|e| Error::Pdf(e.to_string()))?;
    Ok(CoverImage { mime: "image/jpeg".to_string(), data: out })
}

#[cfg(feature = "pdf-text")]
pub fn page_count_pdfium(path: &Path) -> Result<u32> {
    use pdfium_render::prelude::*;
    let pdfium = Pdfium::new(bindings()?);
    let doc = pdfium
        .load_pdf_from_file(path, None)
        .map_err(|e| Error::Pdf(e.to_string()))?;
    Ok(doc.pages().len() as u32)
}

/// 抽取指定页的文本层（供搜索 / 高亮规则 / 进度 anchor 使用）
#[cfg(feature = "pdf-text")]
pub fn extract_page_text(path: &Path, page_index: u32) -> Result<String> {
    use pdfium_render::prelude::*;
    let pdfium = Pdfium::new(bindings()?);
    let doc = pdfium
        .load_pdf_from_file(path, None)
        .map_err(|e| Error::Pdf(e.to_string()))?;
    let page = doc
        .pages()
        .get(page_index as u16)
        .map_err(|e| Error::Pdf(e.to_string()))?;
    Ok(page.text().map(|t| t.all()).unwrap_or_default())
}

/// 整本"文本模式"：逐页抽文本聚合成可搜索 / 高亮的纯文本章节（每页一节）。
/// 仅供搜索与高亮规则使用；正常阅读仍走 `pages`（page_index 进度）。
#[cfg(feature = "pdf-text")]
pub fn extract_text_chapters(path: &Path) -> Result<Vec<RawChapter>> {
    use pdfium_render::prelude::*;
    let pdfium = Pdfium::new(bindings()?);
    let doc = pdfium
        .load_pdf_from_file(path, None)
        .map_err(|e| Error::Pdf(e.to_string()))?;
    let mut chapters = Vec::new();
    for (i, page) in doc.pages().iter().enumerate() {
        let text = page.text().map(|t| t.all()).unwrap_or_default();
        let plain = text.trim().to_string();
        if plain.is_empty() {
            continue;
        }
        let xhtml = format!("<p>{}</p>", escape_xml(&plain));
        chapters.push(RawChapter {
            index: chapters.len(),
            title: format!("第 {} 页", i + 1),
            xhtml,
            plain,
            char_start: 0,
            spine_href: None,
        });
    }
    // 回填整本纯文本起始偏移，供高亮锚点定位
    let mut total = 0usize;
    for c in chapters.iter_mut() {
        c.char_start = total;
        total += c.plain.chars().count();
    }
    Ok(chapters)
}

#[cfg(feature = "pdf-text")]
fn escape_xml(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            _ => out.push(c),
        }
    }
    out
}

/// 三端加载 pdfium 动态库的方式不同，这里集中处理
#[cfg(feature = "pdf-text")]
fn bindings() -> Result<PdfiumLibraryBindings> {
    use pdfium_render::prelude::*;
    // 1) 环境变量显式指定
    if let Ok(p) = std::env::var("INKSYNC_PDFIUM") {
        return Pdfium::bind_to_library(&p)
            .map_err(|e| Error::Pdf(format!("加载 {p} 失败: {e}")));
    }
    // 2) 系统库路径（Linux 下由启动脚本设置 LD_LIBRARY_PATH）
    Pdfium::bind_to_system_library().map_err(|e| Error::Pdf(format!("未找到 pdfium: {e}")))
}
