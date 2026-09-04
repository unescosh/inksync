pub mod cbz;
pub mod epub;
pub mod mobi;
pub mod pdf;
pub mod txt;

use std::io::Read;

use crate::error::Result;

// ─────────────────────────── 路径工具 ───────────────────────────

/// `OEBPS/content.opf` -> `OEBPS`
pub fn dir_of(path: &str) -> String {
    match path.rfind('/') {
        Some(i) => path[..i].to_string(),
        None => String::new(),
    }
}

/// 相对路径合并，处理 `../`
pub fn join(base: &str, rel: &str) -> String {
    if rel.starts_with('/') {
        return rel[1..].to_string();
    }
    let mut parts: Vec<&str> = Vec::new();
    if !base.is_empty() {
        parts.extend(base.split('/').filter(|s| !s.is_empty()));
    }
    for seg in rel.split('/') {
        match seg {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            s => parts.push(s),
        }
    }
    parts.join("/")
}

/// 去掉 URL fragment：`chap.xhtml#sec2` -> `chap.xhtml`
pub fn strip_fragment(href: &str) -> &str {
    match href.find('#') {
        Some(i) => &href[..i],
        None => href,
    }
}

// ─────────────────────────── 压缩包读取 ───────────────────────────

/// 从 zip 中读取文本条目。EPUB 规范要求 UTF-8，但破损书常见 GBK，
/// 因此先读 XML 声明里的 encoding，失败再退回 UTF-8（lossy）。
pub fn read_zip_string<R: Read + std::io::Seek>(
    zip: &mut zip::ZipArchive<R>,
    name: &str,
) -> Result<String> {
    let mut file = zip.by_name(name)?;
    let mut bytes = Vec::with_capacity(file.size() as usize);
    file.read_to_end(&mut bytes)?;
    Ok(decode_text(&bytes))
}

pub fn read_zip_bytes<R: Read + std::io::Seek>(
    zip: &mut zip::ZipArchive<R>,
    name: &str,
) -> Result<Vec<u8>> {
    let mut file = zip.by_name(name)?;
    let mut out = Vec::with_capacity(file.size() as usize);
    file.read_to_end(&mut out)?;
    Ok(out)
}

/// 按 XML 声明的 encoding 解码；无声明则 UTF-8。
/// 用于 EPUB 内 XHTML/OPF。TXT 请用 `txt::decode_txt`（带嗅探）。
pub fn decode_text(bytes: &[u8]) -> String {
    let head = &bytes[..bytes.len().min(512)];
    let probe = String::from_utf8_lossy(head);
    if let Some(enc) = extract_declared_encoding(&probe) {
        if let Some(cs) = encoding_rs::Encoding::for_label(enc.as_bytes()) {
            let (cow, _, _) = cs.decode(bytes);
            return cow.into_owned();
        }
    }
    String::from_utf8_lossy(bytes).into_owned()
}

fn extract_declared_encoding(head: &str) -> Option<String> {
    let start = head.find("encoding")?;
    let rest = &head[start..];
    let q_start = rest.find(['"', '\''])?;
    let q = rest.as_bytes()[q_start];
    let rest = &rest[q_start + 1..];
    let end = rest.find(q as char)?;
    Some(rest[..end].trim().to_string())
}

// ─────────────────────────── HTML 归一化 ───────────────────────────

const BLOCK_TAGS: [&str; 10] = [
    "p", "div", "section", "article", "aside", "li", "tr", "dd", "dt", "blockquote",
];
const SKIP_TAGS: [&str; 5] = ["script", "style", "svg", "object", "iframe"];

/// 把任意 XHTML 净化为白名单子集：`p h1-h6 blockquote em strong br hr img`。
/// 输出一定是**标签闭合**的，Dart 侧的极简解析器可以无脑信任。
pub fn sanitize(src: &str) -> String {
    let mut san = Sanitizer::default();
    let mut rest = src;
    let mut skip_tag = String::new();
    let mut skipping = false;

    while let Some(lt) = rest.find('<') {
        if !skipping {
            san.text(&rest[..lt]);
        }
        let tail = &rest[lt..];
        let Some(gt) = tail.find('>') else { break };
        let raw = &tail[1..gt];
        rest = &tail[gt + 1..];

        // <!-- -->、<!DOCTYPE>、<?xml?>
        if raw.starts_with('!') || raw.starts_with('?') {
            continue;
        }

        let (name, attrs, closing, self_closing) = parse_tag(raw);
        if name.is_empty() {
            continue;
        }
        let name_l = name.to_ascii_lowercase();

        if skipping {
            if closing && name_l == skip_tag {
                skipping = false;
                skip_tag.clear();
            }
            continue;
        }
        if !self_closing && SKIP_TAGS.contains(&name_l.as_str()) {
            skipping = true;
            skip_tag = name_l;
            continue;
        }

        match name_l.as_str() {
            "br" => {
                if !closing {
                    san.void("br");
                }
            }
            "hr" => {
                if !closing {
                    san.close_all();
                    san.void("hr");
                }
            }
            "img" => {
                if !closing {
                    if let Some(src) = attr_value(&attrs, "src") {
                        san.void_img(&src);
                    }
                }
            }
            "em" | "i" | "cite" | "strong" | "b" => {
                let tag: &'static str = if name_l == "em" || name_l == "i" || name_l == "cite" {
                    "em"
                } else {
                    "strong"
                };
                if closing {
                    san.close(tag);
                } else {
                    san.open_inline(tag);
                }
            }
            "h1" | "h2" | "h3" | "h4" | "h5" | "h6" => {
                if closing {
                    san.close(&name_l);
                } else {
                    san.close_all();
                    san.open_block(leak_tag(&name_l));
                }
            }
            "blockquote" => {
                if closing {
                    san.close("blockquote");
                } else {
                    san.close_all();
                    san.open_block("blockquote");
                }
            }
            _ => {
                if BLOCK_TAGS.contains(&name_l.as_str()) {
                    if closing {
                        san.close("p");
                    } else if san.stack.last() == Some(&"p") && san.block_empty {
                        // 已在空的 <p> 块中（如 <div><p> 或 <p><p>）：直接沿用，
                        // 避免先闭合再打开产生 <p></p> 空段。
                    } else {
                        san.close_all();
                        san.open_block("p");
                    }
                }
                // 其余标签（span/a/font/u/sub/sup/table...）一律忽略内容保留
            }
        }
    }
    if !skipping {
        san.text(rest);
    }
    san.finish()
}

/// 少量固定标签，直接转成 `&'static str` 免分配
fn leak_tag(name: &str) -> &'static str {
    match name {
        "h1" => "h1",
        "h2" => "h2",
        "h3" => "h3",
        "h4" => "h4",
        "h5" => "h5",
        _ => "h6",
    }
}

#[derive(Default)]
struct Sanitizer {
    out: String,
    stack: Vec<&'static str>,
    /// 当前最内层块自 open 以来是否已写过内容。用于避免包装块产生空段（`<div><p>`）。
    block_empty: bool,
}

impl Sanitizer {
    fn text(&mut self, raw: &str) {
        if raw.is_empty() {
            return;
        }
        let decoded = decode_entities(raw);
        let mut pending_space = false;
        for ch in decoded.chars() {
            match ch {
                '\n' | '\r' | '\t' | ' ' | '\u{a0}' | '\u{3000}' => pending_space = true,
                '<' => {
                    self.flush_space(&mut pending_space);
                    self.block_empty = false;
                    self.out.push_str("&lt;");
                }
                '&' => {
                    self.flush_space(&mut pending_space);
                    self.block_empty = false;
                    self.out.push_str("&amp;");
                }
                '>' => {
                    self.flush_space(&mut pending_space);
                    self.block_empty = false;
                    self.out.push_str("&gt;");
                }
                c => {
                    self.flush_space(&mut pending_space);
                    self.block_empty = false;
                    self.out.push(c);
                }
            }
        }
        self.flush_space(&mut pending_space);
    }

    /// 把挂起的空白压缩成最多一个空格；块首/标签后不补空格
    fn flush_space(&mut self, pending: &mut bool) {
        if *pending {
            if !self.out.is_empty() && !self.out.ends_with(' ') && !self.out.ends_with('>') {
                self.out.push(' ');
            }
            *pending = false;
        }
    }

    /// 块级标签：先关闭所有未闭合标签，再开新块。
    /// 若已处于同名块中（`<div><p>` 场景）则忽略，避免产生空段落。
    fn open_block(&mut self, tag: &'static str) {
        self.close_all();
        self.out.push('<');
        self.out.push_str(tag);
        self.out.push('>');
        self.stack.push(tag);
        self.block_empty = true;
    }

    fn open_inline(&mut self, tag: &'static str) {
        self.out.push('<');
        self.out.push_str(tag);
        self.out.push('>');
        self.stack.push(tag);
        self.block_empty = false;
    }

    fn close(&mut self, tag: &str) {
        if let Some(pos) = self.stack.iter().rposition(|t| *t == tag) {
            while self.stack.len() > pos {
                let t = self.stack.pop().unwrap();
                self.out.push_str("</");
                self.out.push_str(t);
                self.out.push('>');
            }
            // 刚闭合了一层块，无法再判定其内层是否为空
            self.block_empty = false;
        }
    }

    fn close_all(&mut self) {
        while let Some(t) = self.stack.pop() {
            self.out.push_str("</");
            self.out.push_str(t);
            self.out.push('>');
        }
        self.block_empty = false;
    }

    fn void(&mut self, tag: &str) {
        self.out.push('<');
        self.out.push_str(tag);
        self.out.push_str("/>");
    }

    fn void_img(&mut self, src: &str) {
        self.out.push_str("<img src=\"");
        for c in src.chars() {
            match c {
                '"' => self.out.push_str("&quot;"),
                '&' => self.out.push_str("&amp;"),
                '<' => self.out.push_str("&lt;"),
                _ => self.out.push(c),
            }
        }
        self.out.push_str("\"/>");
    }

    fn finish(mut self) -> String {
        self.close_all();
        self.out
    }
}

fn parse_tag(raw: &str) -> (&str, String, bool, bool) {
    let s = raw.trim();
    let closing = s.starts_with('/');
    let s = s.trim_start_matches('/');
    let self_closing = s.trim_end().ends_with('/');
    let s = s.trim_end().trim_end_matches('/').trim_end();
    let name_end = s
        .find(|c: char| c.is_whitespace())
        .unwrap_or(s.len());
    let name = &s[..name_end];
    let attrs = s[name_end..].trim().to_string();
    (name, attrs, closing, self_closing)
}

fn attr_value(attrs: &str, key: &str) -> Option<String> {
    let lower = attrs.to_ascii_lowercase();
    let needle = format!("{}=", key.to_ascii_lowercase());
    let pos = lower.find(&needle)?;
    let rest = &attrs[pos + needle.len()..].trim_start();
    let (q, body) = if let Some(stripped) = rest.strip_prefix('"') {
        ('"', stripped)
    } else if let Some(stripped) = rest.strip_prefix('\'') {
        ('\'', stripped)
    } else {
        return Some(
            rest.split_whitespace()
                .next()
                .unwrap_or("")
                .to_string(),
        );
    };
    let end = body.find(q).unwrap_or(body.len());
    Some(decode_entities(&body[..end]))
}

/// 解码常用 HTML 实体
pub fn decode_entities(s: &str) -> String {
    if !s.contains('&') {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(amp) = rest.find('&') {
        out.push_str(&rest[..amp]);
        let tail = &rest[amp..];
        if let Some(semi) = tail.find(';') {
            let body = &tail[1..semi];
            let decoded = if let Some(hex) = body.strip_prefix("#x").or_else(|| body.strip_prefix("#X")) {
                u32::from_str_radix(hex, 16).ok().and_then(char::from_u32)
            } else if let Some(dec) = body.strip_prefix('#') {
                dec.parse::<u32>().ok().and_then(char::from_u32)
            } else {
                match body {
                    "amp" => Some('&'),
                    "lt" => Some('<'),
                    "gt" => Some('>'),
                    "quot" => Some('"'),
                    "apos" | "squot" => Some('\''),
                    "nbsp" => Some('\u{a0}'),
                    "mdash" => Some('—'),
                    "ndash" => Some('–'),
                    "hellip" => Some('…'),
                    "ldquo" => Some('“'),
                    "rdquo" => Some('”'),
                    "lsquo" => Some('‘'),
                    "rsquo" => Some('’'),
                    _ => None,
                }
            };
            match decoded {
                Some(c) => out.push(c),
                None => out.push_str(&tail[..semi + 1]),
            }
            rest = &tail[semi + 1..];
        } else {
            out.push('&');
            rest = &tail[1..];
        }
    }
    out.push_str(rest);
    out
}

/// 从归一化 XHTML 提取纯文本（段落之间用 \n\n 分隔）
pub fn strip_tags(xhtml: &str) -> String {
    let mut out = String::with_capacity(xhtml.len() / 2);
    let mut rest = xhtml;
    while let Some(lt) = rest.find('<') {
        let text = decode_entities(&rest[..lt]);
        if !text.trim().is_empty() {
            out.push_str(text.trim());
        }
        let tail = &rest[lt..];
        let Some(gt) = tail.find('>') else { break };
        let name = &tail[1..gt];
        rest = &tail[gt + 1..];
        if name.starts_with("img") {
            out.push_str("[图片]");
        } else if matches!(name, "/p" | "/blockquote" | "/h1" | "/h2" | "/h3" | "/h4" | "/h5" | "/h6") {
            out.push_str("\n\n");
        } else if name == "br/" {
            out.push('\n');
        }
    }
    out.push_str(decode_entities(rest).trim());
    out.trim().to_string()
}

// ─────────────────────────── 杂项 ───────────────────────────

/// 自然排序：chap2 < chap10（CBZ 页序用）
pub fn natural_key(s: &str) -> Vec<NaturalPart> {
    let mut parts = Vec::new();
    let mut buf = String::new();
    let mut digits = String::new();
    for c in s.chars() {
        if c.is_ascii_digit() {
            if !buf.is_empty() {
                parts.push(NaturalPart::Text(std::mem::take(&mut buf).to_lowercase()));
            }
            digits.push(c);
        } else {
            if !digits.is_empty() {
                parts.push(NaturalPart::Num(digits.parse::<u64>().unwrap_or(0)));
                digits.clear();
            }
            buf.push(c);
        }
    }
    if !digits.is_empty() {
        parts.push(NaturalPart::Num(digits.parse::<u64>().unwrap_or(0)));
    }
    if !buf.is_empty() {
        parts.push(NaturalPart::Text(buf.to_lowercase()));
    }
    parts
}

#[derive(Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum NaturalPart {
    Num(u64),
    Text(String),
}

pub fn is_image_entry(name: &str) -> bool {
    let l = name.to_ascii_lowercase();
    l.ends_with(".jpg")
        || l.ends_with(".jpeg")
        || l.ends_with(".png")
        || l.ends_with(".webp")
        || l.ends_with(".gif")
        || l.ends_with(".bmp")
        || l.ends_with(".avif")
}

pub fn mime_for(name: &str) -> &'static str {
    let l = name.to_ascii_lowercase();
    if l.ends_with(".png") {
        "image/png"
    } else if l.ends_with(".webp") {
        "image/webp"
    } else if l.ends_with(".gif") {
        "image/gif"
    } else {
        "image/jpeg"
    }
}

/// 把 "张三，李四 / 王五" / "张,李&王" 这类多人串拆成 Vec。
/// 中文英文分隔符都认；**不含 `/`**，以免破坏 "AC/DC" 这类带斜杠的名字 / 乐队名。
/// 供 TXT / PDF / CBZ 的作者与标签解析共用，保证分隔规则一致。
pub fn split_persons(s: &str) -> Vec<String> {
    s.split(['，', ',', ';', '；', '&', '、'])
        .map(|x| x.trim())
        .filter(|x| !x.is_empty())
        .map(|x| x.to_string())
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn join_handles_dotdot() {
        assert_eq!(join("OEBPS/Text", "../Images/cover.jpg"), "OEBPS/Images/cover.jpg");
        assert_eq!(join("OEBPS", "content.opf"), "OEBPS/content.opf");
    }

    #[test]
    fn sanitize_balances_tags() {
        let s = sanitize("<div><p>你好<em>世界</div><script>bad()</script><p>第二段");
        assert_eq!(s, "<p>你好<em>世界</em></p><p>第二段</p>");
    }

    #[test]
    fn sanitize_keeps_headings_and_images() {
        let s = sanitize("<h1>第一章</h1><p><img src=\"a.png\"/></p>");
        assert_eq!(s, "<h1>第一章</h1><p><img src=\"a.png\"/></p>");
    }

    #[test]
    fn entities_decoded() {
        assert_eq!(decode_entities("a&amp;b&#65;c"), "a&bAc");
        assert_eq!(strip_tags("<p>Tom &amp; Jerry</p>"), "Tom & Jerry");
    }

    #[test]
    fn natural_order() {
        assert!(natural_key("page2.jpg") < natural_key("page10.jpg"));
    }
}
