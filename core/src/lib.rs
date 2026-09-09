pub mod error;
pub mod formats;
pub mod highlight;
pub mod model;
pub mod sync;

/// 无头 CLI 小工具（`.env` 配置解析），默认 features、纯 std，可在沙箱/CI 默认
/// `cargo test` 下单测；example `cli_backup` 通过它与 `sync` feature 的 WebDAV 客户端组合。
pub mod cli;

#[cfg(feature = "frb")]
pub mod api;

use std::fs::File;
use std::io::{BufReader, Read};
use std::path::Path;

use sha2::{Digest, Sha256};

pub use error::{Error, Result};
pub use model::*;

/// 按扩展名分派解析。这是 Dart 侧调用的主入口之一。
pub fn parse_book(path: &str) -> Result<ParsedBook> {
    let p = Path::new(path);
    let ext = p
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    let mut book = match ext.as_str() {
        "epub" => formats::epub::parse(p)?,
        "txt" | "text" => formats::txt::parse(p)?,
        "mobi" | "azw" | "azw3" | "kf8" => formats::mobi::parse(p)?,
        "cbz" | "zip" => formats::cbz::parse(p)?,
        "pdf" => formats::pdf::parse(p)?,
        other => return Err(Error::Unsupported(other.to_string())),
    };

    if book.sha256.is_empty() {
        book.sha256 = sha256_file(p)?;
    }
    Ok(book)
}

/// 只抽取元数据 + 封面（导入预览用，避免解析整本大书）。
pub fn probe_book(path: &str) -> Result<ParsedBook> {
    let p = Path::new(path);
    let ext = p
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let mut book = match ext.as_str() {
        "epub" => formats::epub::probe(p)?,
        "txt" => formats::txt::parse(p)?,
        "mobi" | "azw" | "azw3" | "kf8" => formats::mobi::probe(p)?,
        "cbz" | "zip" => formats::cbz::parse(p)?,
        "pdf" => formats::pdf::parse(p)?,
        other => return Err(Error::Unsupported(other.to_string())),
    };
    book.sha256 = sha256_file(p)?;
    Ok(book)
}

/// 流式计算 sha256 —— 书籍可能几百 MB，绝不整体读入内存。
pub fn sha256_file(path: &Path) -> Result<String> {
    let f = File::open(path)?;
    let mut reader = BufReader::with_capacity(1024 * 1024, f);
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 1024 * 256];
    loop {
        let n = reader.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(hex::encode(hasher.finalize()))
}

pub fn sha256_bytes(data: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(data);
    hex::encode(h.finalize())
}

/// 从任意容器（EPUB/CBZ）中读取一张图片，供 Dart 侧按需加载内嵌资源。
pub fn read_internal_image(path: &str, entry: &str) -> Result<Vec<u8>> {
    let f = File::open(path)?;
    let mut zip = zip::ZipArchive::new(f)?;
    let mut file = zip.by_name(entry)?;
    let mut out = Vec::with_capacity(file.size() as usize);
    file.read_to_end(&mut out)?;
    Ok(out)
}

/// 读取 MOBI/AZW3 图片书的一页。`record` 对应 `ParsedBook.pages` 里的 `pdb:<index>`。
/// 漫画类进度走 `page_index`，Dart 侧按页调用本函数取图渲染。
pub fn read_mobi_image(path: &str, record: u32) -> Result<Vec<u8>> {
    let raw = std::fs::read(path)?;
    formats::mobi::read_image_record(&raw, record)
}

/// 生成封面缩略图（统一 300x450，JPEG q=82），减小同步体积。
pub fn make_thumbnail(data: &[u8], max_w: u32, max_h: u32) -> Result<Vec<u8>> {
    use image::GenericImageView;
    let img = image::load_from_memory(data)?;
    let (w, h) = img.dimensions();
    let scale = (max_w as f32 / w as f32).min(max_h as f32 / h as f32).min(1.0);
    let nw = (w as f32 * scale).max(1.0) as u32;
    let nh = (h as f32 * scale).max(1.0) as u32;
    let thumb = img.resize(nw, nh, image::imageops::FilterType::Lanczos3);
    let mut out = Vec::new();
    thumb.write_to(&mut std::io::Cursor::new(&mut out), image::ImageFormat::Jpeg)?;
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_known_value() {
        // 标准已知向量：SHA-256("abc") = ba7816bf...（FIPS 180-4）
        assert_eq!(
            sha256_bytes(b"abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        );
    }
}
