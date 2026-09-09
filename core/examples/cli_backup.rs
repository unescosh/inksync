//! inksync 无头 CLI：把本地书目录 + 封面目录按内容寻址备份到 WebDAV。
//!
//! 不依赖数据库或 Flutter 引擎，纯 Rust 即可在 UOS / Windows 服务器 / CI 上
//! 跑「扫描本地 → 推到远端」或「从远端拉回本地仓库」的最小同步。
//!
//! 用法：
//! ```text
//! # 推送（把本地书 + 封面推到远端）
//! cargo run --features sync --example cli_backup -- push \
//!     --books /path/to/books \
//!     --covers /path/to/covers \
//!     --store /path/to/local_store \
//!     --url https://dav.example.com/inksync/ \
//!     --user alice --pass secret
//!
//! # 拉取（把远端有、本地仓库缺的书/封面拉回 --store）
//! cargo run --features sync --example cli_backup -- pull \
//!     --store /path/to/local_store \
//!     --url https://dav.example.com/inksync/ \
//!     --user alice --pass secret
//! ```
//!
//! 远端布局（与 Dart 引擎一致，内容寻址）：
//! `inksync/blobs/<sha[:2]>/<sha>`、`inksync/covers/<hash[:2]>/<hash>`。
//! 同名即同内容，天然幂等、免冲突、支持秒传。

use std::path::PathBuf;
use std::process::exit;

use inksync_core::model::{SyncReport, WebDavConfig};
use inksync_core::sync::transfer::{
    CoverEntry, FsBlobStore, FsCoverStore, list_remote, pair_covers, scan_book_dir, transfer_blobs,
    transfer_covers,
};
use inksync_core::sync::webdav::WebDavClient;

struct Args {
    mode: String,
    books: Option<PathBuf>,
    covers: Option<PathBuf>,
    store: PathBuf,
    url: String,
    user: String,
    pass: String,
    remote: String,
    accept_invalid_certs: bool,
}

fn parse_args() -> Args {
    let mut a = Args {
        mode: "push".into(),
        books: None,
        covers: None,
        store: PathBuf::from("inksync_store"),
        url: String::new(),
        user: String::new(),
        pass: String::new(),
        remote: "inksync".into(),
        accept_invalid_certs: false,
    };
    let mut it = std::env::args().skip(1);
    while let Some(tok) = it.next() {
        match tok.as_str() {
            "push" | "pull" => a.mode = tok,
            "--books" => a.books = it.next().map(PathBuf::from),
            "--covers" => a.covers = it.next().map(PathBuf::from),
            "--store" => a.store = it.next().map(PathBuf::from).unwrap_or(a.store),
            "--url" => a.url = it.next().unwrap_or_default(),
            "--user" => a.user = it.next().unwrap_or_default(),
            "--pass" => a.pass = it.next().unwrap_or_default(),
            "--remote" => a.remote = it.next().unwrap_or_else(|| "inksync".into()),
            "--accept-invalid-certs" => a.accept_invalid_certs = true,
            other => {
                eprintln!("未知参数：{other}");
                exit(2);
            }
        }
    }
    if a.url.is_empty() {
        eprintln!("缺少 --url（WebDAV 基址）");
        exit(2);
    }
    if a.mode == "push" && (a.books.is_none() || a.covers.is_none()) {
        eprintln!("push 模式需要 --books 与 --covers");
        exit(2);
    }
    a
}

fn cfg(args: &Args) -> WebDavConfig {
    WebDavConfig {
        base_url: args.url.clone(),
        username: args.user.clone(),
        password: args.pass.clone(),
        accept_invalid_certs: args.accept_invalid_certs,
        user_agent: Some("inksync-cli/0.1".into()),
    }
}

fn run() -> Result<(), String> {
    let args = parse_args();
    let cfg = cfg(&args);
    let client = WebDavClient::new(&cfg).map_err(|e| format!("创建 WebDAV 客户端失败：{e}"))?;
    let mut report = SyncReport::default();

    if args.mode == "push" {
        let books_dir = args.books.as_ref().unwrap();
        let covers_dir = args.covers.as_ref().unwrap();
        let books = scan_book_dir(books_dir).map_err(|e| format!("扫描书目录失败：{e}"))?;
        let covers = pair_covers(&books, covers_dir).map_err(|e| format!("配对封面失败：{e}"))?;
        println!("扫描到 {} 本书、{} 张配对封面", books.len(), covers.len());

        let store = FsBlobStore::new(args.store.clone());
        let cover_store = FsCoverStore::new(args.store.clone());
        // push 模式以本地为准：本地有、远端缺才上传；远端有则跳过（幂等）。
        // on_downloaded 在 push 下通常不触发，置空即可。
        transfer_blobs(&client, &cfg, &args.remote, &books, &store, &mut report, |_, _| {})
            .map_err(|e| format!("传输书籍失败：{e}"))?;
        transfer_covers(&client, &cfg, &args.remote, &covers, &cover_store, &mut report, |_, _| {})
            .map_err(|e| format!("传输封面失败：{e}"))?;

        println!(
            "推送完成：上传书 {} / 下载书 {} / 上传封面 {} / 下载封面 {} / 错误 {}",
            report.uploaded_books,
            report.downloaded_books,
            report.uploaded_covers,
            report.downloaded_covers,
            report.errors.len()
        );
    } else {
        // pull：把远端有、本地仓库缺的按内容寻址拉回 --store
        let (blob_shas, cover_hashes) =
            list_remote(&client, &cfg, &args.remote).map_err(|e| format!("枚举远端失败：{e}"))?;
        println!(
            "远端共 {} 个 blobs、{} 个 covers，开始拉取本地仓库缺失项",
            blob_shas.len(),
            cover_hashes.len()
        );

        let books: Vec<_> = blob_shas
            .iter()
            .map(|sha| inksync_core::sync::transfer::BlobEntry {
                title: sha.clone(),
                sha256: sha.clone(),
                local_path: None,
            })
            .collect();
        let covers: Vec<_> = cover_hashes
            .iter()
            .map(|h| CoverEntry {
                title: h.clone(),
                cover_hash: h.clone(),
                local_path: None,
            })
            .collect();

        let store = FsBlobStore::new(args.store.clone());
        let cover_store = FsCoverStore::new(args.store.clone());
        transfer_blobs(&client, &cfg, &args.remote, &books, &store, &mut report, |sha, p| {
            println!("  拉回书：{sha} -> {}", p.display());
        })
        .map_err(|e| format!("拉取书籍失败：{e}"))?;
        transfer_covers(&client, &cfg, &args.remote, &covers, &cover_store, &mut report, |h, p| {
            println!("  拉回封面：{h} -> {}", p.display());
        })
        .map_err(|e| format!("拉取封面失败：{e}"))?;

        println!(
            "拉取完成：下载书 {} / 下载封面 {} / 错误 {}",
            report.downloaded_books, report.downloaded_covers, report.errors.len()
        );
    }

    if !report.errors.is_empty() {
        eprintln!("存在 {} 个错误：", report.errors.len());
        for e in &report.errors {
            eprintln!("  - {e}");
        }
        exit(1);
    }
    Ok(())
}

fn main() {
    if let Err(e) = run() {
        eprintln!("inksync-cli 失败：{e}");
        exit(1);
    }
}
