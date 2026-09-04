use std::fs::File;
use std::path::Path;

use crate::error::{Error, Result};
use crate::formats::{is_image_entry, mime_for, natural_key, read_zip_bytes, read_zip_string, split_persons};
use crate::model::*;

/// CBZ = zip 里按顺序放图片。核心难点只有一个：**页序**。
/// 必须自然排序 + 目录优先，否则会出现 `page10` 排在 `page2` 前面。
pub fn parse(path: &Path) -> Result<ParsedBook> {
    let f = File::open(path)?;
    let mut zip = zip::ZipArchive::new(f)?;

    let mut entries: Vec<String> = (0..zip.len())
        .filter_map(|i| zip.by_index(i).ok().map(|e| e.name().to_string()))
        .filter(|n| is_image_entry(n))
        .filter(|n| !n.starts_with("__MACOSX") && !n.contains("/."))
        .collect();

    // 先按目录（自然序），再按文件名（自然序）
    entries.sort_by(|a, b| {
        let da = a.rfind('/').map(|i| &a[..i]).unwrap_or("");
        let db = b.rfind('/').map(|i| &b[..i]).unwrap_or("");
        natural_key(da)
            .cmp(&natural_key(db))
            .then_with(|| natural_key(a).cmp(&natural_key(b)))
    });

    if entries.is_empty() {
        return Err(Error::Other("压缩包内没有找到图片".into()));
    }

    let cover = read_zip_bytes(&mut zip, &entries[0])
        .ok()
        .map(|data| CoverImage {
            mime: mime_for(&entries[0]).to_string(),
            data,
        });

    let meta = read_comic_info(&mut zip).unwrap_or_else(|| {
        let stem = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("未命名")
            .to_string();
        BookMeta {
            title: stem,
            ..Default::default()
        }
    });

    let file_size = path.metadata().map(|m| m.len()).unwrap_or(0);
    Ok(ParsedBook {
        format: BookFormat::Cbz,
        meta,
        toc: Vec::new(),
        // 漫画不生成 text chapter，Dart 侧直接按 pages 渲染
        chapters: Vec::new(),
        cover,
        sha256: String::new(),
        file_size,
        pages: Some(entries),
        // CBZ 一律图片书，进度走 page_index
        is_image_book: true,
        total_chars: 0,
    })
}

/// ComicInfo.xml（ComicRack 事实标准）→ 元数据
fn read_comic_info<R: std::io::Read + std::io::Seek>(
    zip: &mut zip::ZipArchive<R>,
) -> Option<BookMeta> {
    let xml = (0..zip.len())
        .filter_map(|i| zip.by_index(i).ok().map(|e| e.name().to_string()))
        .find(|n| n.eq_ignore_ascii_case("ComicInfo.xml"))?;
    let text = read_zip_string(zip, &xml).ok()?;
    let doc = roxmltree::Document::parse(&text).ok()?;

    fn val(doc: &roxmltree::Document, tag: &str) -> Option<String> {
        doc.descendants()
            .find(|n| n.is_element() && n.tag_name().name() == tag)
            .and_then(|n| n.text())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
    }

    Some(BookMeta {
        title: val(&doc, "Title")?,
        series: val(&doc, "Series"),
        series_index: val(&doc, "Number").and_then(|n| n.parse::<f32>().ok()),
        authors: val(&doc, "Writer").as_deref().map(split_persons).unwrap_or_default(),
        publisher: val(&doc, "Publisher"),
        description: val(&doc, "Summary"),
        tags: val(&doc, "Tags").as_deref().map(split_persons).unwrap_or_default(),
        language: val(&doc, "LanguageISO"),
        ..Default::default()
    })
}

/// CBR：RAR 是商业格式，本项目不内置解码器。
/// 这里给出明确的错误，让用户走「一键转换 CBZ」流程。
pub fn parse_cbr(_path: &Path) -> Result<ParsedBook> {
    Err(Error::Unsupported(
        "CBR(RAR) 未内置解码器，请在导入时转换为 CBZ".into(),
    ))
}
