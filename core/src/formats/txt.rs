use std::fs;
use std::path::Path;

use chardetng::EncodingDetector;

use crate::error::Result;
use crate::formats::{sanitize, split_persons, strip_tags};
use crate::model::*;

/// 中文 TXT 的章节标题模式。
/// 覆盖：第一章 / 第1章 / 第 12 回 / 卷三 / Chapter 1 / 序 / 楔子 / 后记 / 番外
const CHAPTER_PATTERNS: [&str; 6] = [
    r"^\s*第\s*[0-9零〇一二三四五六七八九十百千万两]+\s*[章节節回卷篇集部]",
    r"^\s*(?:chapter|chap|part|book)\s+[0-9ivxlc]+",
    r"^\s*(?:卷|部|篇)\s*[0-9零〇一二三四五六七八九十百千万两]+\s*$",
    r"^\s*(?:序|序言|自序|楔子|引子|引言|前言|后记|後記|尾声|尾聲|结语)",
    r"^\s*(?:番外|外传|外傳)\s*[^\n]{0,30}$",
    r"^\s*[0-9]{1,4}[.、．]\s*\S{1,30}$",
];

pub fn parse(path: &Path) -> Result<ParsedBook> {
    let bytes = fs::read(path)?;
    let text = decode_txt(&bytes);

    let file_stem = path
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("未命名")
        .to_string();

    let meta = build_meta(&text, &file_stem);
    let chapters = split_chapters(&text, &meta.title);
    let total_chars: usize = chapters.iter().map(|c| c.plain.chars().count()).sum();

    // TXT 没有封面 → 由 Dart 侧生成"文字封面"（取书名首字 + 主题色）
    let file_size = bytes.len() as u64;
    Ok(ParsedBook {
        format: BookFormat::Txt,
        meta,
        toc: chapters
            .iter()
            .map(|c| TocEntry {
                title: c.title.clone(),
                href: None,
                level: 0,
                children: Vec::new(),
            })
            .collect(),
        chapters,
        cover: None,
        sha256: String::new(),
        file_size,
        pages: None,
        // TXT 是文本书，进度走 (spine, char_offset)
        is_image_book: false,
        total_chars,
    })
}

/// 编码嗅探顺序：BOM → chardetng（中文优先）→ GB18030 兜底。
/// 国内 TXT 绝大多数是 GBK/GB18030，这一步做不好全是乱码。
pub fn decode_txt(bytes: &[u8]) -> String {
    // 1) BOM
    if bytes.starts_with(&[0xEF, 0xBB, 0xBF]) {
        return String::from_utf8_lossy(&bytes[3..]).into_owned();
    }
    if bytes.starts_with(&[0xFF, 0xFE]) {
        return utf16_to_string(bytes, true);
    }
    if bytes.starts_with(&[0xFE, 0xFF]) {
        return utf16_to_string(bytes, false);
    }
    // 2) 合法 UTF-8 直接用（最快路径）
    if let Ok(s) = std::str::from_utf8(bytes) {
        return s.to_string();
    }
    // 3) chardetng 给中文提示，但最终以"中文优先"决策：
    //    国内 TXT 99% 是 GBK/GB18030；chardetng 在短样本上极易误判
    //    （如把 GBK 的"你好"判成韩文 EUC-KR），或给出 windows-1252 兜底。
    let mut detector = EncodingDetector::new();
    detector.feed(bytes, true);
    let enc = detector.guess(Some(b"zh"), true);
    let enc_name = enc.name().to_ascii_lowercase();
    match enc_name.as_str() {
        // chardetng "没把握"的兜底答案
        "windows-1252" => {}
        // 明确是 GB 系 → 直接用
        "gbk" | "gb18030" => {
            let (cow, _, _) = enc.decode(bytes);
            return cow.into_owned();
        }
        // CJK 歧义（Big5/Shift_JIS/EUC-KR/EUC-JP）→ 中文场景 GB18030 更稳
        "big5" | "big5-hkscs" | "shift_jis" | "euc-kr" | "euc-jp" => {}
        // 明确非中文（俄语/西欧等）→ 信任 chardetng
        _ => {
            let (cow, _, _) = enc.decode(bytes);
            return cow.into_owned();
        }
    }
    // 其余一律走 GB18030（GBK 超集），对中文字节最稳
    let (cow, _, _) = encoding_rs::GB18030.decode(bytes);
    cow.into_owned()
}

fn utf16_to_string(bytes: &[u8], le: bool) -> String {
    let u16s: Vec<u16> = bytes
        .chunks_exact(2)
        .map(|c| {
            if le {
                u16::from_le_bytes([c[0], c[1]])
            } else {
                u16::from_be_bytes([c[0], c[1]])
            }
        })
        .collect();
    String::from_utf16_lossy(&u16s)
}

/// 从正文头部抽取书名 / 作者（网文 TXT 常见约定）
fn build_meta(text: &str, fallback_title: &str) -> BookMeta {
    let head: String = text.chars().take(300).collect();
    let mut meta = BookMeta::default();

    meta.title = find_labeled(&head, &["书名", "标题", "Title", "title"])
        .unwrap_or_else(|| clean_title(fallback_title));
    if let Some(a) = find_labeled(&head, &["作者", "作  者", "Author", "author"]) {
        meta.authors = split_persons(&a);
    }
    meta.language = Some("zh".to_string());
    meta
}

fn find_labeled(head: &str, labels: &[&str]) -> Option<String> {
    for line in head.lines().take(12) {
        let line = line.trim();
        for label in labels {
            for sep in [":", "：", "="] {
                let prefix = format!("{label}{sep}");
                if let Some(rest) = line.strip_prefix(&prefix) {
                    let v = rest.trim();
                    if !v.is_empty() && v.chars().count() <= 80 {
                        return Some(v.to_string());
                    }
                }
            }
        }
    }
    None
}

/// 去掉文件名里常见的来源尾巴：`xxx作者李四.txt` / `xxx(全集)` / `xxx_精校版`
fn clean_title(stem: &str) -> String {
    let mut s = stem.to_string();
    for junk in ["作者", "全集", "精校", "校对", "完整版", "txt", "TXT"] {
        if let Some(i) = s.find(junk) {
            if i > 2 {
                s = s[..i].to_string();
            }
        }
    }
    let s = s.trim_matches(|c: char| c == '(' || c == ')' || c == '（' || c == '）' || c == ' ' || c == '_' || c == '-');
    if s.is_empty() {
        stem.to_string()
    } else {
        s.to_string()
    }
}

/// 按章节标题切分。匹配不到任何标题时，退化为按 5000 字均分，
/// 避免一本 200 万字的书只有"一个章节"导致打开卡顿。
pub fn split_chapters(text: &str, book_title: &str) -> Vec<RawChapter> {
    let re_list: Vec<regex::Regex> = CHAPTER_PATTERNS
        .iter()
        .filter_map(|p| regex::Regex::new(p).ok())
        .collect();

    let lines: Vec<&str> = text.lines().collect();
    let mut heads: Vec<(usize, String)> = Vec::new(); // (行号, 标题)
    for (i, line) in lines.iter().enumerate() {
        if line.trim().is_empty() || line.trim().chars().count() > 60 {
            continue;
        }
        let is_head = re_list.iter().any(|re| re.is_match(line));
        if is_head {
            heads.push((i, line.trim().to_string()));
        }
    }

    let mut chapters = Vec::new();
    if heads.len() >= 2 {
        for (idx, (start, title)) in heads.iter().enumerate() {
            let end = heads.get(idx + 1).map(|(n, _)| *n).unwrap_or(lines.len());
            let body: String = lines[*start..end].join("\n");
            if body.trim().is_empty() {
                continue;
            }
            let xhtml = text_to_xhtml(&body);
            let plain = strip_tags(&xhtml);
            if plain.trim().is_empty() {
                continue;
            }
            chapters.push(RawChapter {
                index: chapters.len(),
                title: title.clone(),
                xhtml,
                plain,
                char_start: 0,
                spine_href: None,
            });
        }
    }

    if chapters.len() < 2 {
        chapters = chunk_by_length(text, 5000);
    }
    if chapters.is_empty() {
        let xhtml = text_to_xhtml(text);
        chapters.push(RawChapter {
            index: 0,
            title: book_title.to_string(),
            plain: strip_tags(&xhtml),
            xhtml,
            char_start: 0,
            spine_href: None,
        });
    }
    assign_char_start(&mut chapters);
    chapters
}

/// 文本书：按章节顺序累加 `plain` 字符数，回填 `char_start`，
/// 供上层把阅读位置换算成 `(spine, char_offset)` 进度。
fn assign_char_start(chapters: &mut [RawChapter]) {
    let mut total = 0usize;
    for c in chapters.iter_mut() {
        c.char_start = total;
        total += c.plain.chars().count();
    }
}

fn chunk_by_length(text: &str, per: usize) -> Vec<RawChapter> {
    let chars: Vec<char> = text.chars().collect();
    let mut out = Vec::new();
    let mut i = 0usize;
    let mut idx = 0usize;
    while i < chars.len() {
        let end = (i + per).min(chars.len());
        // 尽量在段落边界（换行）断开
        let mut real_end = end;
        if real_end < chars.len() {
            while real_end < chars.len() && chars[real_end] != '\n' {
                real_end += 1;
            }
            // 若一直找到文末都没有换行（整段超长、无段落边界），
            // 则强制回到 per 边界硬切，避免只剩 1 段导致超长卡顿。
            if real_end == chars.len() {
                real_end = end;
            }
        }
        let body: String = chars[i..real_end].iter().collect();
        let xhtml = text_to_xhtml(&body);
        let plain = strip_tags(&xhtml);
        out.push(RawChapter {
            index: idx,
            title: format!("第 {} 节", idx + 1),
            plain,
            xhtml,
            char_start: 0,
            spine_href: None,
        });
        idx += 1;
        i = real_end + 1;
    }
    out
}

/// 纯文本 → 归一化 XHTML（每个非空行一个 <p>）
fn text_to_xhtml(body: &str) -> String {
    let mut out = String::with_capacity(body.len() + 64);
    for line in body.lines() {
        let t = line.trim();
        if t.is_empty() {
            continue;
        }
        out.push_str("<p>");
        for c in t.chars() {
            match c {
                '&' => out.push_str("&amp;"),
                '<' => out.push_str("&lt;"),
                '>' => out.push_str("&gt;"),
                _ => out.push(c),
            }
        }
        out.push_str("</p>");
    }
    // 再做一次净化，确保与 EPUB 走同一条渲染管线
    sanitize(&out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gbk_decoded() {
        // "你好" 的 GBK 编码
        let bytes = [0xC4, 0xE3, 0xBA, 0xC3];
        assert_eq!(decode_txt(&bytes), "你好");
    }

    #[test]
    fn utf8_kept() {
        assert_eq!(decode_txt("你好，世界".as_bytes()), "你好，世界");
    }

    #[test]
    fn chapters_split() {
        let t = "第一章 初见\n正文一\n正文二\n\n第二章 惊变\n正文三";
        let cs = split_chapters(t, "测试");
        assert_eq!(cs.len(), 2);
        assert_eq!(cs[0].title, "第一章 初见");
        assert!(cs[0].plain.contains("正文一"));
    }

    #[test]
    fn falls_back_to_chunking() {
        let t = "孤零零的一段话，没有任何章节标题。".repeat(500);
        let cs = split_chapters(&t, "测试");
        assert!(cs.len() > 1);
    }
}
