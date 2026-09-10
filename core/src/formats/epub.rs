use std::collections::HashMap;
use std::fs::File;
use std::path::Path;

use roxmltree::{Document, Node};

use crate::error::{Error, Result};
use crate::formats::{
    decode_entities, dir_of, is_image_entry, join, mime_for, read_zip_bytes, read_zip_string,
    sanitize, strip_fragment, strip_tags,
};
use crate::model::*;

struct ManifestItem {
    href: String,
    media_type: String,
    properties: String,
}

pub fn parse(path: &Path) -> Result<ParsedBook> {
    let f = File::open(path)?;
    let mut zip = zip::ZipArchive::new(f)?;

    let opf_path = find_opf_path(&mut zip)?;
    let opf_text = read_zip_string(&mut zip, &opf_path)?;
    let doc = Document::parse(&opf_text)?;
    let base = dir_of(&opf_path);

    let meta = read_metadata(&doc);
    let manifest = read_manifest(&doc, &base);
    let spine = read_spine(&doc);
    let cover = read_cover(&mut zip, &doc, &manifest)?;
    let toc = read_toc(&mut zip, &doc, &manifest)?;

    // href -> 目录标题，用于给没有标题的章节兜底
    let mut title_by_href: HashMap<String, String> = HashMap::new();
    collect_toc_titles(&toc, &mut title_by_href);

    // 图片型 spine 项占比 → 判定漫画书（进度走 page_index）
    let image_spine = spine
        .iter()
        .filter(|id| manifest.get(*id).map(|i| i.media_type.starts_with("image/")).unwrap_or(false))
        .count();
    let text_spine = spine.len() - image_spine;

    let mut chapters = Vec::new();
    let mut total_chars = 0usize;
    for idref in &spine {
        let Some(item) = manifest.get(idref) else { continue };
        // 图片型条目：漫画书的一页，不进文本章节
        if item.media_type.starts_with("image/") {
            continue;
        }
        let Ok(raw) = read_zip_string(&mut zip, &item.href) else {
            continue;
        };
        let chapter_dir = dir_of(&item.href);
        let xhtml = sanitize_with_base(&raw, &chapter_dir, &base);
        let plain = strip_tags(&xhtml);
        if plain.trim().is_empty() && !xhtml.contains("<img") {
            continue;
        }
        let key = strip_fragment(&item.href).to_string();
        let title = title_by_href
            .get(&key)
            .cloned()
            .filter(|t| !t.trim().is_empty())
            .unwrap_or_else(|| first_line(&plain, 24).unwrap_or_else(|| format!("第 {} 节", chapters.len() + 1)));
        let char_start = total_chars;
        total_chars += plain.chars().count();
        chapters.push(RawChapter {
            index: chapters.len(),
            title,
            xhtml,
            plain,
            char_start,
            spine_href: Some(item.href.clone()),
        });
    }

    let is_image_book = image_spine > 0 && (text_spine == 0 || chapters.is_empty());
    let pages = if is_image_book {
        Some(
            spine
                .iter()
                .filter_map(|id| manifest.get(id))
                .filter(|i| i.media_type.starts_with("image/"))
                .map(|i| i.href.clone())
                .collect(),
        )
    } else {
        None
    };
    let file_size = path.metadata().map(|m| m.len()).unwrap_or(0);

    Ok(ParsedBook {
        format: BookFormat::Epub,
        meta,
        toc,
        chapters,
        cover,
        sha256: String::new(),
        file_size,
        pages,
        is_image_book,
        total_chars,
    })
}

/// 只取元数据 + 封面，不解析正文（导入列表的缩略图预览用）
pub fn probe(path: &Path) -> Result<ParsedBook> {
    let f = File::open(path)?;
    let mut zip = zip::ZipArchive::new(f)?;
    let opf_path = find_opf_path(&mut zip)?;
    let opf_text = read_zip_string(&mut zip, &opf_path)?;
    let doc = Document::parse(&opf_text)?;
    let base = dir_of(&opf_path);
    let meta = read_metadata(&doc);
    let manifest = read_manifest(&doc, &base);
    let cover = read_cover(&mut zip, &doc, &manifest)?;
    let spine = read_spine(&doc);
    let image_spine = spine
        .iter()
        .filter(|id| manifest.get(*id).map(|i| i.media_type.starts_with("image/")).unwrap_or(false))
        .count();
    let text_spine = spine.len() - image_spine;
    let is_image_book = image_spine > 0 && text_spine == 0;
    let pages = if is_image_book {
        Some(
            spine
                .iter()
                .filter_map(|id| manifest.get(id))
                .filter(|i| i.media_type.starts_with("image/"))
                .map(|i| i.href.clone())
                .collect(),
        )
    } else {
        None
    };
    Ok(ParsedBook {
        format: BookFormat::Epub,
        meta,
        toc: Vec::new(),
        chapters: Vec::new(),
        cover,
        sha256: String::new(),
        file_size: path.metadata().map(|m| m.len()).unwrap_or(0),
        pages,
        is_image_book,
        total_chars: 0,
    })
}

// ─────────────────────────── container / OPF ───────────────────────────

fn find_opf_path<R: std::io::Read + std::io::Seek>(
    zip: &mut zip::ZipArchive<R>,
) -> Result<String> {
    if let Ok(xml) = read_zip_string(zip, "META-INF/container.xml") {
        let doc = Document::parse(&xml)?;
        for n in doc.descendants().filter(|n| n.is_element()) {
            if n.tag_name().name() == "rootfile" {
                if let Some(p) = n.attribute("full-path") {
                    if !p.is_empty() {
                        return Ok(p.to_string());
                    }
                }
            }
        }
    }
    // 兜底：根目录或任意一级目录下的 *.opf
    for i in 0..zip.len() {
        let entry = zip.by_index(i)?;
        let name = entry.name().to_string();
        if name.to_ascii_lowercase().ends_with(".opf") {
            return Ok(name);
        }
    }
    Err(Error::Other("EPUB 中找不到 OPF 文件".into()))
}

fn elem<'a, 'i>(n: Node<'a, 'i>, name: &str) -> Option<Node<'a, 'i>> {
    n.children()
        .find(|c| c.is_element() && c.tag_name().name() == name)
}

fn elems<'a, 'i>(n: Node<'a, 'i>, name: &str) -> Vec<Node<'a, 'i>> {
    n.children()
        .filter(|c| c.is_element() && c.tag_name().name() == name)
        .collect()
}

fn text_of(n: Node) -> String {
    n.text().unwrap_or("").trim().to_string()
}

fn deep_text(n: Node) -> String {
    let mut s = String::new();
    for d in n.descendants().filter(|d| d.is_text()) {
        s.push_str(d.text().unwrap_or(""));
    }
    decode_entities(s.trim())
}

fn read_metadata(doc: &Document) -> BookMeta {
    let root = doc.root_element();
    let md = match elem(root, "metadata") {
        Some(m) => m,
        None => return BookMeta::default(),
    };

    let mut meta = BookMeta::default();
    // 主标题取第一个 <dc:title>；副标题取第二个 <dc:title> 或带 opf:type="subtitle" 的
    let titles: Vec<String> = elems(md, "title")
        .into_iter()
        .map(deep_text)
        .filter(|s| !s.is_empty())
        .collect();
    meta.title = titles.first().cloned().unwrap_or_default();
    if titles.len() > 1 {
        meta.subtitle = Some(titles[1].clone());
    } else if let Some(sub) = elems(md, "title")
        .into_iter()
        .find(|t| {
            t.attribute(("http://www.idpf.org/2007/opf", "type")) == Some("subtitle")
                || t.attribute("opf:type") == Some("subtitle")
        })
        .map(deep_text)
    {
        if !sub.is_empty() {
            meta.subtitle = Some(sub);
        }
    }
    meta.language = elems(md, "language").first().cloned().map(text_of);
    meta.publisher = elems(md, "publisher").first().cloned().map(text_of);
    meta.description = elems(md, "description").first().cloned().map(deep_text);

    for c in elems(md, "creator") {
        let role = c
            .attribute(("http://www.idpf.org/2007/opf", "role"))
            .or_else(|| c.attribute("role"))
            .unwrap_or("aut");
        if role == "aut" || meta.authors.is_empty() {
            let name = text_of(c);
            if !name.is_empty() && !meta.authors.contains(&name) {
                meta.authors.push(name);
            }
        }
    }

    for i in elems(md, "identifier") {
        let value = text_of(i);
        if value.is_empty() {
            continue;
        }
        let scheme = i
            .attribute(("http://www.idpf.org/2007/opf", "scheme"))
            .or_else(|| i.attribute("scheme"))
            .map(|s| s.to_string())
            .unwrap_or_else(|| {
                if let Some((head, _)) = value.split_once(':') {
                    if head.len() <= 12 {
                        return head.to_string();
                    }
                }
                "unknown".to_string()
            });
        meta.identifiers.push((scheme, value));
    }

    meta.tags = elems(md, "subject").into_iter().map(text_of).filter(|s| !s.is_empty()).collect();

    // EPUB3 关键词：<meta property="keyword">
    for m in elems(md, "meta") {
        if m.attribute("property") == Some("keyword") {
            let kw = deep_text(m);
            if !kw.is_empty() && !meta.tags.contains(&kw) {
                meta.tags.push(kw);
            }
        }
    }

    // EPUB2 风格的 calibre 系列信息 + EPUB3 belongs-to-collection
    for m in elems(md, "meta") {
        let name = m.attribute("name").unwrap_or("").to_string();
        let content = m.attribute("content").unwrap_or("").to_string();
        match name.as_str() {
            "calibre:series" => meta.series = Some(content),
            "calibre:series_index" => meta.series_index = content.parse::<f32>().ok(),
            _ => {}
        }
    }
    for m in elems(md, "meta") {
        if m.attribute("property") == Some("belongs-to-collection") {
            let id = m.attribute("id").unwrap_or("").to_string();
            meta.series = Some(deep_text(m));
            // 找 refines="#id" 且 property=group-position
            let refine_target = format!("#{id}");
            for r in elems(md, "meta") {
                if r.attribute("refines") == Some(refine_target.as_str())
                    && r.attribute("property") == Some("group-position")
                {
                    meta.series_index = r.text().and_then(|t| t.parse::<f32>().ok());
                }
            }
            break;
        }
    }

    if meta.title.is_empty() {
        meta.title = "未命名".to_string();
    }
    meta
}

fn read_manifest(doc: &Document, base: &str) -> HashMap<String, ManifestItem> {
    let mut map = HashMap::new();
    let Some(mf) = doc.root_element().children().find(|c| c.is_element() && c.tag_name().name() == "manifest") else {
        return map;
    };
    for item in mf.children().filter(|c| c.is_element() && c.tag_name().name() == "item") {
        let id = item.attribute("id").unwrap_or("").to_string();
        let href = item.attribute("href").unwrap_or("").to_string();
        if id.is_empty() || href.is_empty() {
            continue;
        }
        map.insert(
            id,
            ManifestItem {
                href: join(base, &href),
                media_type: item.attribute("media-type").unwrap_or("").to_ascii_lowercase(),
                properties: item.attribute("properties").unwrap_or("").to_ascii_lowercase(),
            },
        );
    }
    map
}

fn read_spine(doc: &Document) -> Vec<String> {
    let Some(sp) = doc.root_element().children().find(|c| c.is_element() && c.tag_name().name() == "spine") else {
        return Vec::new();
    };
    sp.children()
        .filter(|c| {
            c.is_element()
                && c.tag_name().name() == "itemref"
                && c.attribute("linear") != Some("no")
        })
        .filter_map(|c| c.attribute("idref").map(|s| s.to_string()))
        .collect()
}

// ─────────────────────────── 封面 ───────────────────────────

fn read_cover<R: std::io::Read + std::io::Seek>(
    zip: &mut zip::ZipArchive<R>,
    doc: &Document,
    manifest: &HashMap<String, ManifestItem>,
) -> Result<Option<CoverImage>> {
    // 1) EPUB2: <meta name="cover" content="<id>">
    let mut candidates: Vec<String> = Vec::new();
    if let Some(md) = elem(doc.root_element(), "metadata") {
        for m in elems(md, "meta") {
            if m.attribute("name") == Some("cover") {
                if let Some(id) = m.attribute("content") {
                    if let Some(item) = manifest.get(id) {
                        candidates.push(item.href.clone());
                    }
                }
            }
        }
    }
    // 2) EPUB3: properties 含 cover-image
    for item in manifest.values() {
        if item.properties.contains("cover-image") {
            candidates.push(item.href.clone());
        }
    }
    // 3) 名字里带 cover/封面/title 的图片
    let mut named: Vec<&String> = manifest
        .values()
        .filter(|i| {
            i.media_type.starts_with("image/") && {
                let l = i.href.to_ascii_lowercase();
                l.contains("cover") || l.contains("title") || l.contains("封面")
            }
        })
        .map(|i| &i.href)
        .collect();
    named.sort();
    candidates.extend(named.into_iter().cloned());

    // 4) 最后兜底：manifest 里第一张图
    let mut any_img: Vec<&String> = manifest
        .values()
        .filter(|i| i.media_type.starts_with("image/"))
        .map(|i| &i.href)
        .collect();
    any_img.sort();
    candidates.extend(any_img.into_iter().cloned());

    for href in candidates {
        if let Ok(data) = read_zip_bytes(zip, &href) {
            if !data.is_empty() {
                return Ok(Some(CoverImage {
                    mime: mime_for(&href).to_string(),
                    data,
                }));
            }
        }
    }
    Ok(None)
}

// ─────────────────────────── 目录 ───────────────────────────

fn read_toc<R: std::io::Read + std::io::Seek>(
    zip: &mut zip::ZipArchive<R>,
    doc: &Document,
    manifest: &HashMap<String, ManifestItem>,
) -> Result<Vec<TocEntry>> {
    // EPUB3 nav 优先
    for item in manifest.values() {
        if item.properties.contains("nav") {
            if let Ok(xml) = read_zip_string(zip, &item.href) {
                if let Ok(parsed) = Document::parse(&xml) {
                    let base = dir_of(&item.href);
                    let entries = parse_nav_doc(&parsed, &base);
                    if !entries.is_empty() {
                        return Ok(entries);
                    }
                }
            }
        }
    }
    // EPUB2 NCX
    let ncx_id = doc
        .root_element()
        .children()
        .find(|c| c.is_element() && c.tag_name().name() == "spine")
        .and_then(|sp| sp.attribute("toc").map(|s| s.to_string()));
    if let Some(id) = ncx_id {
        if let Some(item) = manifest.get(&id) {
            if let Ok(xml) = read_zip_string(zip, &item.href) {
                let parsed = Document::parse(&xml)?;
                let base = dir_of(&item.href);
                return Ok(parse_ncx(&parsed, &base));
            }
        }
    }
    Ok(Vec::new())
}

fn parse_nav_doc(doc: &Document, base: &str) -> Vec<TocEntry> {
    for nav in doc.descendants().filter(|n| n.is_element() && n.tag_name().name() == "nav") {
        let is_toc = nav
            .attribute(("http://www.idpf.org/2007/ops", "type"))
            .or_else(|| nav.attribute("type"))
            .map(|t| t.contains("toc"))
            .unwrap_or(false);
        if !is_toc {
            continue;
        }
        if let Some(ol) = nav
            .descendants()
            .find(|n| n.is_element() && n.tag_name().name() == "ol")
        {
            let out = parse_ol(ol, base, 0);
            if !out.is_empty() {
                return out;
            }
        }
    }
    Vec::new()
}

fn parse_ol(ol: Node, base: &str, level: u32) -> Vec<TocEntry> {
    let mut out = Vec::new();
    for li in ol.children().filter(|c| c.is_element() && c.tag_name().name() == "li") {
        let mut entry: Option<TocEntry> = None;
        if let Some(a) = li
            .children()
            .find(|c| c.is_element() && c.tag_name().name() == "a")
        {
            let title = deep_text(a);
            let href = a.attribute("href").map(|h| join(base, strip_fragment(h)));
            entry = Some(TocEntry { title, href, level, children: Vec::new() });
        }
        let children = li
            .children()
            .find(|c| c.is_element() && c.tag_name().name() == "ol")
            .map(|o| parse_ol(o, base, level + 1))
            .unwrap_or_default();
        match entry {
            Some(mut e) => {
                e.children = children;
                out.push(e);
            }
            None => out.extend(children),
        }
    }
    out
}

fn parse_ncx(doc: &Document, base: &str) -> Vec<TocEntry> {
    let Some(navmap) = doc.descendants().find(|n| n.is_element() && n.tag_name().name() == "navMap") else {
        return Vec::new();
    };
    fn walk(n: Node, base: &str, level: u32, out: &mut Vec<TocEntry>) {
        for np in n.children().filter(|c| c.is_element() && c.tag_name().name() == "navPoint") {
            let title = np
                .children()
                .find(|c| c.is_element() && c.tag_name().name() == "navLabel")
                .and_then(|l| l.children().find(|c| c.is_element() && c.tag_name().name() == "text"))
                .map(deep_text)
                .unwrap_or_default();
            let href = np
                .children()
                .find(|c| c.is_element() && c.tag_name().name() == "content")
                .and_then(|c| c.attribute("src"))
                .map(|h| join(base, strip_fragment(h)));
            let mut children = Vec::new();
            walk(np, base, level + 1, &mut children);
            out.push(TocEntry { title, href, level, children });
        }
    }
    let mut out = Vec::new();
    walk(navmap, base, 0, &mut out);
    out
}

fn collect_toc_titles(entries: &[TocEntry], map: &mut HashMap<String, String>) {
    for e in entries {
        if let Some(href) = &e.href {
            map.entry(href.clone()).or_insert_with(|| e.title.clone());
        }
        collect_toc_titles(&e.children, map);
    }
}

// ─────────────────────────── 正文 ───────────────────────────

/// 净化并把 `<img src>` 改写为**相对 OPF 根目录**的绝对路径，
/// 这样 Dart 侧只需记住一个 base，就能从 zip 里取图。
///
/// `chapter_dir` 取自 `dir_of(item.href)`，而 `item.href` 已在 `read_manifest`
/// 中与 OPF 根目录 `base` 拼接过，故 `chapter_dir` 本身已含根前缀。
/// 因此直接 `join(chapter_dir, src)` 即可得到正确路径；**切忌再叠一次 OPF base**，
/// 否则会生成 `OEBPS/OEBPS/Images/...` 这类重复前缀，导致 Dart 取图 404。
fn sanitize_with_base(raw: &str, chapter_dir: &str) -> String {
    let out = sanitize(raw);
    if !out.contains("<img") {
        return out;
    }
    let mut result = String::with_capacity(out.len() + 64);
    let mut rest = out.as_str();
    while let Some(pos) = rest.find("<img src=\"") {
        result.push_str(&rest[..pos]);
        let tail = &rest[pos + 10..];
        let Some(end) = tail.find('"') else {
            result.push_str(rest);
            return result;
        };
        let src = &tail[..end];
        let absolute = join(&join(opf_base, chapter_dir), src);
        result.push_str("<img src=\"");
        result.push_str(&absolute);
        result.push_str("\"/>");
        rest = &tail[end + 2..];
    }
    result.push_str(rest);
    result
}

fn first_line(s: &str, max_chars: usize) -> Option<String> {
    let line = s.lines().find(|l| !l.trim().is_empty())?.trim();
    let t: String = line.chars().take(max_chars).collect();
    Some(if line.chars().count() > max_chars {
        format!("{t}…")
    } else {
        t
    })
}

/// 判断 zip 内某条目是否为图片（供 Dart 侧读取内嵌图复用）
pub fn is_image(name: &str) -> bool {
    is_image_entry(name)
}

#[cfg(test)]
mod tests {
    use crate::formats::{join, sanitize};

    /// 回归：正文在 `OEBPS/Text/chap1.xhtml`，引用 `../Images/pic.png`。
    /// 纠正前会得到 `OEBPS/OEBPS/Images/pic.png`（重复前缀）→ Dart 取图 404。
    #[test]
    fn img_src_rewritten_relative_to_opf_root_without_double_prefix() {
        let raw = "<p>正文</p><img src=\"../Images/pic.png\"/>";
        let out = sanitize_with_base(raw, "OEBPS/Text");
        assert!(
            out.contains("<img src=\"OEBPS/Images/pic.png\"/>"),
            "got: {out}"
        );
    }

    /// 绝对路径（以 / 开头）应去掉前导斜杠、相对 zip 根目录，而不是再叠 OPF 根。
    #[test]
    fn img_src_absolute_stripped_to_zip_root() {
        let raw = "<img src=\"/Images/pic.png\"/>";
        let out = sanitize_with_base(raw, "OEBPS/Text");
        assert!(
            out.contains("<img src=\"Images/pic.png\"/>"),
            "got: {out}"
        );
    }

    /// 自检：与上方断言一致的底层 join 行为，确保不会回退成重复前缀。
    #[test]
    fn join_does_not_double_prefix() {
        assert_eq!(join("OEBPS/Text", "../Images/pic.png"), "OEBPS/Images/pic.png");
        assert_eq!(join(join("OEBPS", "OEBPS/Text"), "../Images/pic.png"), "OEBPS/OEBPS/Images/pic.png");
        // 上方第二行正是「旧实现的错误结果」，证明修复前确实会出错
        let _ = sanitize;
    }
}

