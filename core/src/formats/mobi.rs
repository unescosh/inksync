use std::fs;
use std::path::Path;

use crate::error::{Error, Result};
use crate::formats::{sanitize, strip_tags, txt};
use crate::model::*;

/// MOBI(KF7) / AZW3(KF8) 解析。
///
/// 正文压缩有两类：`PalmDOC`（LZ77 变体）与 `HUFF-CDIC`（Huffman + 字典），
/// 由 `mobi` crate 承担 —— 自研成本极高且极易出错，不值得重造。
/// 元数据补充与封面则**自己按字节解析 PDB/EXTH**，少依赖一层 API。
///
/// ⚠️ 构建校准点：本文件依赖的 `mobi` crate API 只有这 9 个方法 ——
///    `from_path / title / author / publisher / description / isbn /
///     publish_date / contributor / content_as_string`
///    若升级 crate 后编译报错，只需改 `read_meta_from_crate()` 一处。
///
/// 已知限制：
///  1. 带 DRM（Topaz / KFX）无法解析（法律与技术双重限制）；
///  2. KF8 目录（INDX/NCX）不稳定时退化为按正文 `<hN>` 分章；
///  3. 解析失败时返回明确错误，UI 层应引导用户"用 Calibre 转 EPUB"。
pub fn parse(path: &Path) -> Result<ParsedBook> {
    let doc = mobi::Mobi::from_path(path).map_err(|e| Error::Mobi(e.to_string()))?;
    let raw = fs::read(path)?;

    let mut meta = read_meta_from_crate(&doc);
    let exth = Exth::parse(&raw);
    exth.apply_to(&mut meta);

    let format = if is_kf8(path) {
        BookFormat::Azw3
    } else {
        BookFormat::Mobi
    };
    let file_size = raw.len() as u64;

    // 漫画（图片书）判定：图片记录数远多于文本章节
    let img_recs = list_image_records(&raw);
    let text = doc.content_as_string().ok();
    let mut chapters = if let Some(text) = &text {
        if text.trim_start().starts_with('<') {
            split_kf8(text)
        } else {
            txt::split_chapters(text, &meta.title)
        }
    } else {
        Vec::new()
    };

    // 图片书判定：图片记录必须是"主力"，且正文接近空白。
    // 配图小说（大量插图 + 大量文字）会被正确判为文本书，不再误判成漫画。
    let total_plain = text
        .as_deref()
        .map(|t| strip_tags(&sanitize(t)).chars().count())
        .unwrap_or(0);
    let is_image_book = !img_recs.is_empty()
        && (total_plain < 200
            || (img_recs.len() >= 3
                && (chapters.is_empty() || img_recs.len() >= chapters.len().saturating_mul(2))));

    if is_image_book {
        // 漫画：用图片记录当页序；封面取第一张图
        let pages = Some(img_recs.iter().map(|i| format!("pdb:{i}")).collect());
        let cover = img_recs
            .first()
            .and_then(|&i| read_image_record(&raw, i).ok())
            .map(|data| CoverImage {
                mime: sniff_mime_of(&data),
                data,
            });
        return Ok(ParsedBook {
            format,
            meta,
            toc: Vec::new(),
            chapters: Vec::new(),
            cover,
            sha256: String::new(),
            file_size,
            pages,
            is_image_book: true,
            total_chars: 0,
        });
    }

    // 文本书：回填进度锚点（spine_href 对 MOBI 无意义，填 None）
    let toc = chapters
        .iter()
        .map(|c| TocEntry {
            title: c.title.clone(),
            href: None,
            level: 0,
            children: Vec::new(),
        })
        .collect();
    let mut total = 0usize;
    for c in chapters.iter_mut() {
        c.char_start = total;
        total += c.plain.chars().count();
    }

    let cover = extract_cover(&raw, &exth);
    Ok(ParsedBook {
        format,
        meta,
        toc,
        chapters,
        cover,
        sha256: String::new(),
        file_size,
        pages: None,
        is_image_book: false,
        total_chars: total,
    })
}

/// 列出 MOBI 中所有图片记录的序号（漫画书用，页面按记录索引取）
pub fn list_image_records(raw: &[u8]) -> Vec<u32> {
    let mut out = Vec::new();
    let mut i = 0u32;
    loop {
        match pdb_record(raw, i as usize) {
            Some(rec) => {
                if sniff_image(rec).is_some() || find_image_magic(rec).is_some() {
                    out.push(i);
                }
                i += 1;
            }
            None => break,
        }
    }
    out
}

/// 取指定 PDB 图片记录的字节（KF8 资源记录可能带前缀，自动扫魔数切片）。
/// 供 Dart 侧按 `pages` 里的 `pdb:<index>` 逐页读取漫画。
pub fn read_image_record(raw: &[u8], record_index: u32) -> Result<Vec<u8>> {
    let rec = pdb_record(raw, record_index as usize)
        .ok_or_else(|| Error::Other(format!("MOBI 记录 {record_index} 不存在")))?;
    if sniff_image(rec).is_some() {
        return Ok(rec.to_vec());
    }
    if let Some(p) = find_image_magic(rec) {
        return Ok(rec[p..].to_vec());
    }
    Err(Error::Other(format!("MOBI 记录 {record_index} 非图片")))
}

fn sniff_mime_of(b: &[u8]) -> String {
    sniff_image(b)
        .map(|s| s.to_string())
        .unwrap_or_else(|| "image/jpeg".to_string())
}

fn read_meta_from_crate(doc: &mobi::Mobi) -> BookMeta {
    let mut meta = BookMeta::default();
    // mobi 0.8.0：`title()` 返回 String，其余返回 Option<String>
    meta.title = doc.title().trim().to_string();
    if let Some(a) = doc.author().as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        meta.authors = vec![a.to_string()];
    }
    meta.publisher = doc
        .publisher()
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(String::from);
    meta.description = doc.description().as_deref().map(str::trim).map(String::from);
    meta.published = doc.publish_date().as_deref().map(str::trim).map(String::from);
    if let Some(isbn) = doc.isbn().as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        meta.identifiers.push(("isbn".to_string(), isbn.to_string()));
    }
    if let Some(c) = doc.contributor().as_deref().map(str::trim).filter(|s| !s.is_empty()) {
        meta.tags.push(c.to_string());
    }
    meta
}

fn is_kf8(path: &Path) -> bool {
    path.extension()
        .and_then(|e| e.to_str())
        .map(|e| e.eq_ignore_ascii_case("azw3") || e.eq_ignore_ascii_case("kf8"))
        .unwrap_or(false)
}

/// 轻量探测：只解析元数据 + 封面（EXTH + 首图），**不做正文解压与分章**。
/// 供导入列表缩略图预览；正式阅读走 `parse`（会精确判定 is_image_book）。
pub fn probe(path: &Path) -> Result<ParsedBook> {
    let doc = mobi::Mobi::from_path(path).map_err(|e| Error::Mobi(e.to_string()))?;
    let raw = fs::read(path)?;

    let mut meta = read_meta_from_crate(&doc);
    let exth = Exth::parse(&raw);
    exth.apply_to(&mut meta);

    let format = if is_kf8(path) {
        BookFormat::Azw3
    } else {
        BookFormat::Mobi
    };
    let file_size = raw.len() as u64;

    // 预览场景只需粗判：图片记录数 >= 3 视为图片书（打开时由 parse 精确再判）
    let img_recs = list_image_records(&raw);
    let is_image_book = !img_recs.is_empty() && img_recs.len() >= 3;
    let cover = img_recs
        .first()
        .and_then(|&i| read_image_record(&raw, i).ok())
        .map(|data| CoverImage {
            mime: sniff_mime_of(&data),
            data,
        });
    let pages = if is_image_book {
        Some(img_recs.iter().map(|i| format!("pdb:{i}")).collect())
    } else {
        None
    };

    Ok(ParsedBook {
        format,
        meta,
        toc: Vec::new(),
        chapters: Vec::new(),
        cover,
        sha256: String::new(),
        file_size,
        pages,
        is_image_book,
        total_chars: 0,
    })
}

// ─────────────────────── EXTH / PDB 自解析 ───────────────────────

/// EXTH 记录类型（常用）
#[derive(Debug, Default)]
struct Exth {
    cover_offset: Option<u32>,
    thumb_offset: Option<u32>,
    language: Option<String>,
    title: Option<String>,
    author: Option<String>,
    series: Option<String>,
    series_index: Option<f32>,
}

impl Exth {
    /// 从原始文件解析 PDB record0 → MOBI header → EXTH
    fn parse(raw: &[u8]) -> Self {
        let mut out = Self::default();
        let Some(r0) = pdb_record(raw, 0) else { return out };

        // MOBI header 位于 record0 偏移 16 处
        if r0.len() < 16 + 116 || &r0[16..20] != b"MOBI" {
            return out;
        }
        let be32 = |b: &[u8], o: usize| -> u32 {
            u32::from_be_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]])
        };
        let m = 16;
        let header_len = be32(r0, m + 4) as usize;

        let exth_start = m + header_len;
        if exth_start + 12 > r0.len() || &r0[exth_start..exth_start + 4] != b"EXTH" {
            return out;
        }
        let exth_len = be32(r0, exth_start + 4) as usize;
        let count = be32(r0, exth_start + 8) as usize;
        let mut pos = exth_start + 12;
        let end = (exth_start + exth_len).min(r0.len());
        let mut n = 0;
        while pos + 8 <= end && n < count {
            let rtype = be32(r0, pos);
            let rlen = be32(r0, pos + 4) as usize;
            if rlen < 8 || pos + rlen > end {
                break;
            }
            let data = &r0[pos + 8..pos + rlen];
            match rtype {
                100 => out.author = Some(latin1_or_utf8(data)),
                503 => out.title = Some(latin1_or_utf8(data)),
                201 => out.cover_offset = u32_from_be_slice(data),
                202 => out.thumb_offset = u32_from_be_slice(data),
                502 => out.series = Some(latin1_or_utf8(data)),
                524 => out.language = Some(latin1_or_utf8(data)),
                // 100=作者 503=书名 已在上处理；106=出版日 / 108=贡献者 由 crate 提供
                _ => {}
            }
            pos += rlen;
            n += 1;
        }
        out
    }

    fn apply_to(&self, meta: &mut BookMeta) {
        if meta.title.trim().is_empty() {
            if let Some(t) = &self.title {
                meta.title = t.clone();
            }
        }
        if meta.authors.is_empty() {
            if let Some(a) = &self.author {
                meta.authors = vec![a.clone()];
            }
        }
        if meta.language.is_none() {
            meta.language = self.language.clone();
        }
        if meta.series.is_none() {
            meta.series = self.series.clone();
        }
        if let Some(i) = self.series_index {
            meta.series_index = Some(i);
        }
    }
}

fn latin1_or_utf8(b: &[u8]) -> String {
    match std::str::from_utf8(b) {
        Ok(s) => s.trim().to_string(),
        Err(_) => b.iter().map(|&c| c as char).collect::<String>().trim().to_string(),
    }
}

fn u32_from_be_slice(b: &[u8]) -> Option<u32> {
    if b.len() < 4 {
        return None;
    }
    Some(u32::from_be_bytes([b[0], b[1], b[2], b[3]]))
}

/// 取 PDB 的第 index 条记录（PDB header 78B + 每条目 8B 的 record info）
fn pdb_record(raw: &[u8], index: usize) -> Option<&[u8]> {
    if raw.len() < 78 {
        return None;
    }
    let num = u16::from_be_bytes([raw[76], raw[77]]) as usize;
    if index >= num {
        return None;
    }
    let off0 = 78 + index * 8;
    let off1 = 78 + (index + 1) * 8;
    if off1 + 4 > raw.len() {
        return None;
    }
    let start = u32::from_be_bytes([raw[off0], raw[off0 + 1], raw[off0 + 2], raw[off0 + 3]]) as usize;
    let end = if index + 1 < num {
        let o = 78 + (index + 1) * 8;
        u32::from_be_bytes([raw[o], raw[o + 1], raw[o + 2], raw[o + 3]]) as usize
    } else {
        raw.len()
    };
    if start >= end || end > raw.len() {
        return None;
    }
    Some(&raw[start..end])
}

/// 封面：优先 EXTH 202(缩略图) / 201(coveroffset)，否则取 First Image record。
fn extract_cover(raw: &[u8], exth: &Exth) -> Option<CoverImage> {
    let candidates: Vec<u32> = [
        exth.cover_offset,
        exth.thumb_offset,
        first_image_index(raw),
    ]
    .into_iter()
    .flatten()
    .collect();

    for idx in candidates {
        if let Some(rec) = pdb_record(raw, idx as usize) {
            if let Some(mime) = sniff_image(rec) {
                return Some(CoverImage {
                    mime: mime.to_string(),
                    data: rec.to_vec(),
                });
            }
            // KF8 的资源记录可能带一段前缀，向后扫描 JPEG/PNG 魔数
            if let Some(p) = find_image_magic(rec) {
                let body = &rec[p..];
                if let Some(mime) = sniff_image(body) {
                    return Some(CoverImage {
                        mime: mime.to_string(),
                        data: body.to_vec(),
                    });
                }
            }
        }
    }
    None
}

fn first_image_index(raw: &[u8]) -> Option<u32> {
    let r0 = pdb_record(raw, 0)?;
    if r0.len() < 16 + 96 {
        return None;
    }
    Some(u32::from_be_bytes([r0[108], r0[109], r0[110], r0[111]]))
}

fn sniff_image(b: &[u8]) -> Option<&'static str> {
    if b.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some("image/jpeg")
    } else if b.starts_with(&[0x89, b'P', b'N', b'G']) {
        Some("image/png")
    } else if b.starts_with(b"GIF8") {
        Some("image/gif")
    } else if b.starts_with(b"RIFF") && b.len() > 12 && &b[8..12] == b"WEBP" {
        Some("image/webp")
    } else if b.starts_with(b"BM") {
        Some("image/bmp")
    } else {
        None
    }
}

fn find_image_magic(b: &[u8]) -> Option<usize> {
    // KF8 的图片资源记录可能带一小段前缀头，魔数未必落在前 64 字节内；
    // 放宽到前 4KB 扫描即可覆盖任何前缀，又避免对超大整图做无意义全扫。
    let limit = b.len().min(4096);
    b.windows(3)
        .take(limit)
        .position(|w| w == [0xFF, 0xD8, 0xFF])
        .or_else(|| {
            b.windows(4)
                .take(limit)
                .position(|w| w == [0x89, b'P', b'N', b'G'])
        })
}

// ─────────────────────── 正文分章 ───────────────────────

/// KF8 正文按 `<h1>~<h6>` 切分；识别不到标题则退回纯文本分章。
fn split_kf8(text: &str) -> Vec<RawChapter> {
    let mut chapters = Vec::new();
    let Some(re) = regex::Regex::new(r#"(?is)<h([1-6])[^>]*>(.*?)</h\1>"#).ok() else {
        return txt::split_chapters(&strip_tags(&sanitize(text)), "MOBI");
    };

    struct Piece<'a> {
        title: Option<String>,
        body: &'a str,
    }
    let mut pieces: Vec<Piece> = Vec::new();
    let mut last = 0usize;
    for m in re.find_iter(text) {
        let raw_title = re
            .captures(m.as_str())
            .and_then(|c| c.get(2))
            .map(|t| strip_tags(&sanitize(t.as_str())))
            .unwrap_or_default();
        if m.start() > last {
            pieces.push(Piece { title: None, body: &text[last..m.start()] });
        }
        pieces.push(Piece { title: Some(raw_title), body: m.as_str() });
        last = m.end();
    }
    if last < text.len() {
        pieces.push(Piece { title: None, body: &text[last..] });
    }

    let mut current = String::new();
    let mut current_title: Option<String> = None;
    for p in pieces {
        match p.title {
            Some(t) => {
                if !current.trim().is_empty() {
                    push_chapter(&mut chapters, current_title.take(), &current);
                    current.clear();
                }
                current_title = Some(t);
                current.push_str(p.body);
            }
            None => current.push_str(p.body),
        }
    }
    if !current.trim().is_empty() {
        push_chapter(&mut chapters, current_title, &current);
    }

    if chapters.len() < 2 {
        return txt::split_chapters(&strip_tags(&sanitize(text)), "MOBI");
    }
    chapters
}

fn push_chapter(out: &mut Vec<RawChapter>, title: Option<String>, body: &str) {
    let xhtml = sanitize(body);
    let plain = strip_tags(&xhtml);
    if plain.trim().is_empty() && !xhtml.contains("<img") {
        return;
    }
    out.push(RawChapter {
        index: out.len(),
        title: title.unwrap_or_else(|| format!("第 {} 节", out.len() + 1)),
        xhtml,
        plain,
        char_start: 0,
        spine_href: None,
    });
}
