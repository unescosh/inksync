//! 端到端集成测试：在内存里造最小 EPUB/CBZ/TXT，验证核心解析链路。
//! 运行：`cargo +nightly test --test integration`

use std::io::Write;
use std::path::Path;

use inksync_core::parse_book;
use zip::write::SimpleFileOptions;
use zip::ZipWriter;

/// 1x1 像素 PNG（合法，能被封面解码器接受；image crate 默认支持 PNG）
const TINY_PNG: &[u8] = include_bytes!("../tests/assets/px.png");

fn write_epub(path: &Path) {
    let f = std::fs::File::create(path).unwrap();
    let mut z = ZipWriter::new(f);
    let opt = SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Stored);

    z.start_file("mimetype", opt).unwrap();
    z.write_all(b"application/epub+zip").unwrap();

    z.start_file("META-INF/container.xml", opt).unwrap();
    z.write_all(
        r#"<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"#.as_bytes(),
    )
    .unwrap();

    z.start_file("OEBPS/content.opf", opt).unwrap();
    z.write_all(
        r#"<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>测试书名</dc:title>
    <dc:creator>测试作者</dc:creator>
    <dc:language>zh</dc:language>
    <meta name="cover" content="cover-img"/>
  </metadata>
  <manifest>
    <item id="cover-img" href="cover.png" media-type="image/png"/>
    <item id="c1" href="chap1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine>
    <itemref idref="c1"/>
  </spine>
</package>"#.as_bytes(),
    )
    .unwrap();

    z.start_file("OEBPS/cover.png", opt).unwrap();
    z.write_all(TINY_PNG).unwrap();

    z.start_file("OEBPS/chap1.xhtml", opt).unwrap();
    z.write_all(
        r#"<?xml version="1.0" encoding="utf-8"?>
<html xmlns="http://www.w3.org/1999/xhtml"><body>
  <h1>第一章 初见</h1>
  <p>这是正文第一句。&amp; 包含实体。</p>
  <p>这是正文第二句。</p>
</body></html>"#.as_bytes(),
    )
    .unwrap();

    z.finish().unwrap();
}

#[test]
fn epub_end_to_end() {
    let dir = std::env::temp_dir().join("inksync_test");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("sample.epub");
    write_epub(&path);

    let book = parse_book(path.to_str().unwrap()).expect("解析 EPUB 失败");
    assert_eq!(book.meta.title, "测试书名");
    assert_eq!(book.meta.authors, vec!["测试作者".to_string()]);
    assert_eq!(book.format, inksync_core::BookFormat::Epub);
    assert!(book.chapters.len() >= 1, "应至少有一章");
    assert_eq!(book.chapters[0].title, "第一章 初见");
    assert!(book.chapters[0].plain.contains("正文第一句"), "正文应被提取");
    assert!(book.cover.is_some(), "封面应被识别（meta name=cover）");
    // 实体解码：&amp; -> &
    assert!(book.chapters[0].plain.contains('&'), "HTML 实体应被解码");
    assert!(!book.sha256.is_empty(), "sha256 应被计算");

    // M1 进度锚点：文本书 char_start 从 0 单调递增、total_chars 与正文一致
    assert!(!book.is_image_book, "本测试是文本书，不应判为图片书");
    assert!(book.total_chars > 0, "total_chars 应大于 0");
    let mut prev = 0usize;
    for c in &book.chapters {
        assert!(c.char_start >= prev, "char_start 应单调递增");
        assert!(c.spine_href.is_some(), "EPUB 章节应带 spine_href");
        prev = c.char_start;
    }
}

#[test]
fn epub_unknown_format_rejected() {
    let dir = std::env::temp_dir().join("inksync_test");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("bad.xyz");
    std::fs::write(&path, b"not a book").unwrap();
    assert!(parse_book(path.to_str().unwrap()).is_err());
}

fn write_cbz(path: &Path) {
    let f = std::fs::File::create(path).unwrap();
    let mut z = ZipWriter::new(f);
    let opt = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);
    // 自然序：page2 在 page10 之前，验证排序正确
    for name in ["page2.png", "page10.png", "page1.png"] {
        z.start_file(format!("images/{name}"), opt).unwrap();
        z.write_all(TINY_PNG).unwrap();
    }
    z.finish().unwrap();
}

#[test]
fn cbz_end_to_end() {
    let dir = std::env::temp_dir().join("inksync_test");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("sample.cbz");
    write_cbz(&path);

    let book = parse_book(path.to_str().unwrap()).expect("解析 CBZ 失败");
    assert_eq!(book.format, inksync_core::BookFormat::Cbz);
    assert!(book.is_image_book, "CBZ 应判为图片书");
    let pages = book.pages.expect("CBZ 应有页序");
    assert_eq!(pages.len(), 3, "应有 3 页");
    // 自然排序：page1 < page2 < page10
    assert!(pages[0].contains("page1"), "页序应按自然序：page1 在最前");
    assert!(pages[2].contains("page10"), "页序应按自然序：page10 在最后");
    assert!(book.cover.is_some(), "封面应取第一页");
    assert_eq!(book.total_chars, 0, "图片书 total_chars 为 0");
}

fn write_epub_imagebook(path: &Path) {
    let f = std::fs::File::create(path).unwrap();
    let mut z = ZipWriter::new(f);
    let opt = SimpleFileOptions::default().compression_method(zip::CompressionMethod::Stored);

    z.start_file("mimetype", opt).unwrap();
    z.write_all(b"application/epub+zip").unwrap();

    z.start_file("META-INF/container.xml", opt).unwrap();
    z.write_all(
        r#"<?xml version="1.0"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>"#.as_bytes(),
    )
    .unwrap();

    z.start_file("OEBPS/content.opf", opt).unwrap();
    z.write_all(
        r#"<?xml version="1.0" encoding="utf-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>测试漫画</dc:title>
    <dc:language>zh</dc:language>
    <meta name="cover" content="cover-img"/>
  </metadata>
  <manifest>
    <item id="cover-img" href="cover.png" media-type="image/png"/>
    <item id="p1" href="page1.png" media-type="image/png"/>
    <item id="p2" href="page2.png" media-type="image/png"/>
  </manifest>
  <spine>
    <itemref idref="p1"/>
    <itemref idref="p2"/>
  </spine>
</package>"#.as_bytes(),
    )
    .unwrap();

    z.start_file("OEBPS/cover.png", opt).unwrap();
    z.write_all(TINY_PNG).unwrap();
    z.start_file("OEBPS/page1.png", opt).unwrap();
    z.write_all(TINY_PNG).unwrap();
    z.start_file("OEBPS/page2.png", opt).unwrap();
    z.write_all(TINY_PNG).unwrap();

    z.finish().unwrap();
}

#[test]
fn epub_image_book_end_to_end() {
    let dir = std::env::temp_dir().join("inksync_test");
    std::fs::create_dir_all(&dir).unwrap();
    let path = dir.join("sample_image.epub");
    write_epub_imagebook(&path);

    let book = parse_book(path.to_str().unwrap()).expect("解析 EPUB 图片书失败");
    assert!(book.is_image_book, "图片型 spine 应判为图片书");
    assert!(book.chapters.is_empty(), "图片书不应生成文本章节");
    let pages = book.pages.expect("图片书应有页序");
    assert_eq!(pages.len(), 2, "应有 2 页");
    assert_eq!(book.total_chars, 0, "图片书 total_chars 为 0");
    assert!(book.cover.is_some(), "图片书封面应被识别（meta name=cover）");
}
