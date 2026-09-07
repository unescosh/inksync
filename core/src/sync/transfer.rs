//! 文件传输编排：书籍原文件（blobs）与封面图片（covers）按内容寻址跨端同步。
//!
//! 这是 Dart `SyncEngine._transferBlobs` / `_transferCovers` 的 Rust 原生镜像，
//! 让 UOS / CLI 路径（无需 Flutter 引擎）也能把书与封面字节随 WebDAV 跨端传。
//!
//! ## 设计要点
//! 1. **不耦合数据库**：Rust 核心没有 drift，所以函数接收调用方传入的待传条目列表，
//!    DB 取数留给未来的 Rust SyncEngine / CLI。这与 Dart 把取数放在引擎里不同，
//!    但循环体内的传输逻辑逐条对齐。
//! 2. **可单测**：通过 `DavFs` trait 接缝把具体 WebDAV 实现（含网络）隔离开；
//!    真实 `WebDavClient` 仅在 `feature="sync"` 下 `impl DavFs`，本模块本身
//!    **不**门控，故默认 `cargo test`（不带 `sync`，沙箱/CI 也编不过 `sync`）即可
//!    编译并跑通单测。
//! 3. **内容寻址 + sha256 校验 + 幂等**：同名即同内容，天然免冲突、可秒传；
//!    下载后校验 sha256，不符则丢弃（绝不写入本地）。这正好让
//!    `SyncReport.uploaded_covers` / `downloaded_covers` 字段从"暂不使用"变为真正产出。

use std::path::{Path, PathBuf};
use std::time::SystemTime;

use crate::error::Result;
use crate::model::{SyncReport, WebDavConfig};
use crate::sha256_bytes;

/// 远端文件系统接缝：传输编排只依赖这组纯抽象，从而能在无真实服务器时单测。
///
/// 真实 `WebDavClient` 在 `feature="sync"` 下实现本 trait；
/// 测试用内存版（`MemDav`）实现本 trait。
pub trait DavFs {
    /// 幂等创建目录（含中间层级），失败时返回 `Err`。
    fn mkcol_all(&self, cfg: &WebDavConfig, path: &str) -> Result<()>;

    /// 列出某目录（depth=1）下的**文件名**（不含路径、不含目录项）。
    fn list_names(&self, cfg: &WebDavConfig, dir: &str) -> Result<Vec<String>>;

    /// 下载整段字节。
    fn get_bytes(&self, cfg: &WebDavConfig, path: &str) -> Result<Vec<u8>>;

    /// 原子写入（先临时名再改名；内存实现直接存）。
    fn put_atomic(&self, cfg: &WebDavConfig, path: &str, body: Vec<u8>) -> Result<()>;
}

/// 本地书籍 blob 仓库（按 sha256 内容寻址）。
pub trait BlobStore {
    /// 返回本地文件绝对路径；不存在返回 `None`。
    fn path_for(&self, sha256: &str) -> Result<Option<PathBuf>>;
    /// 把 `source` 复制为内容寻址路径（`<root>/blobs/<sha[:2]>/<sha>`），
    /// 返回最终路径（原子：先 tmp 再 rename）。
    fn import_file(&self, source: &Path, sha256: &str) -> Result<PathBuf>;
}

/// 本地封面仓库（按 coverHash 内容寻址，扩展名由魔数决定）。
pub trait CoverStore {
    /// 返回本地封面绝对路径（带正确扩展名）；不存在返回 `None`。
    fn path_for(&self, cover_hash: &str) -> Result<Option<PathBuf>>;
    /// 把 `source` 复制为 `<root>/covers/<hash>.<ext>`，返回最终路径。
    fn import_file(&self, source: &Path, cover_hash: &str, ext: &str) -> Result<PathBuf>;
}

/// 一条待传输的书籍文件条目。
pub struct BlobEntry {
    pub title: String,
    pub sha256: String,
    pub local_path: Option<PathBuf>,
}

/// 一条待传输的封面条目。
pub struct CoverEntry {
    pub title: String,
    pub cover_hash: String,
    pub local_path: Option<PathBuf>,
}

// ─────────────────────────── 路径拼接 ───────────────────────────

fn blob_remote_path(root: &str, sha: &str) -> String {
    format!("{}/blobs/{}/{}", root.trim_end_matches('/'), &sha[..2], sha)
}
fn blob_prefix(root: &str, sha: &str) -> String {
    format!("{}/blobs/{}", root.trim_end_matches('/'), &sha[..2])
}
fn cover_remote_path(root: &str, hash: &str) -> String {
    format!("{}/covers/{}/{}", root.trim_end_matches('/'), &hash[..2], hash)
}
fn cover_prefix(root: &str, hash: &str) -> String {
    format!("{}/covers/{}", root.trim_end_matches('/'), &hash[..2])
}

/// 从图片二进制魔数推断扩展名（与 Dart `SyncEngine._coverExtForBytes` 对齐）。
/// 远端封面不带扩展名，B 端落地时按此决定文件名后缀，保证 UI 能按 coverPath 找到它。
pub fn cover_ext(bytes: &[u8]) -> &'static str {
    if bytes.len() >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
        ".jpg"
    } else if bytes.len() >= 8 && &bytes[0..8] == b"\x89PNG\r\n\x1a\n" {
        ".png"
    } else if bytes.len() >= 6 && &bytes[0..3] == b"GIF" {
        ".gif"
    } else if bytes.len() >= 12
        && &bytes[0..4] == b"RIFF"
        && &bytes[8..12] == b"WEBP"
    {
        ".webp"
    } else {
        ".jpg"
    }
}

fn nanos() -> u128 {
    SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0)
}

// ─────────────────────────── blobs 传输 ───────────────────────────

/// 跨端传输书籍原文件。逻辑逐条镜像 Dart `SyncEngine._transferBlobs`：
/// - 本地有文件、远端缺 → 上传并 `uploaded_books++`；
/// - 本地缺、远端有 → 下载 + sha256 校验 + 落盘，回调 `on_downloaded(sha, 本地路径)` 并 `downloaded_books++`；
/// - 校验不符 → 记 `errors` 并丢弃，绝不写入；
/// - 二次同步幂等（远端已有则跳过）。
///
/// 单本书失败不拖垮整轮：IO 错误被捕获并记入 `report.errors`，继续下一条。
pub fn transfer_blobs<F, B>(
    fs: &F,
    cfg: &WebDavConfig,
    remote_root: &str,
    books: &[BlobEntry],
    blob_store: &B,
    report: &mut SyncReport,
    mut on_downloaded: impl FnMut(&str, &Path),
) -> Result<()>
where
    F: DavFs,
    B: BlobStore,
{
    fs.mkcol_all(cfg, &format!("{}/blobs/", remote_root.trim_end_matches('/')))?;
    for entry in books {
        if let Err(e) = transfer_one_blob(fs, cfg, remote_root, entry, blob_store, report, &mut on_downloaded) {
            report.errors.push(format!("《{}》书籍传输失败: {e}", entry.title));
        }
    }
    Ok(())
}

fn transfer_one_blob<F, B>(
    fs: &F,
    cfg: &WebDavConfig,
    remote_root: &str,
    entry: &BlobEntry,
    blob_store: &B,
    report: &mut SyncReport,
    on_downloaded: &mut dyn FnMut(&str, &Path),
) -> Result<()>
where
    F: DavFs,
    B: BlobStore,
{
    let sha = &entry.sha256;
    if sha.is_empty() {
        return Ok(());
    }
    let remote = blob_remote_path(remote_root, sha);
    let remote_has = {
        let names = fs.list_names(cfg, &blob_prefix(remote_root, sha))?;
        names.iter().any(|n| n == sha)
    };

    // 本地是否有文件（显式路径优先，否则问仓库）
    let local = match &entry.local_path {
        Some(p) if p.exists() => Some(p.clone()),
        _ => match blob_store.path_for(sha)? {
            Some(p) if p.exists() => Some(p),
            _ => None,
        },
    };

    if let Some(local) = local {
        if !remote_has {
            let bytes = std::fs::read(&local)?;
            fs.put_atomic(cfg, &remote, bytes)?;
            report.uploaded_books += 1;
        }
        return Ok(());
    }

    // 下载分支
    if !remote_has {
        return Ok(());
    }
    let bytes = fs.get_bytes(cfg, &remote)?;
    let actual = sha256_bytes(&bytes);
    if actual != *sha {
        report.errors.push(format!(
            "《{}》书籍校验失败（期望 {sha}，实际 {actual}），已丢弃",
            entry.title
        ));
        return Ok(());
    }
    let tmp = std::env::temp_dir().join(format!("{}.tmp-{}", sha, nanos()));
    std::fs::write(&tmp, &bytes)?;
    let dest = blob_store.import_file(&tmp, sha)?;
    let _ = std::fs::remove_file(&tmp);
    on_downloaded(sha, &dest);
    report.downloaded_books += 1;
    Ok(())
}

// ─────────────────────────── covers 传输 ───────────────────────────

/// 跨端传输封面图片。与 blobs 完全镜像，差别只在：
/// - 按 `cover_hash` 内容寻址，远端 `covers/<hash[:2]>/<hash>`；
/// - 本地 `<root>/covers/<hash>.<ext>`（ext 由 `cover_ext` 魔数探测）；
/// - 计数走 `uploaded_covers` / `downloaded_covers`；
/// - 校验不符同样丢弃。
pub fn transfer_covers<F, C>(
    fs: &F,
    cfg: &WebDavConfig,
    remote_root: &str,
    books: &[CoverEntry],
    cover_store: &C,
    report: &mut SyncReport,
    mut on_downloaded: impl FnMut(&str, &Path),
) -> Result<()>
where
    F: DavFs,
    C: CoverStore,
{
    fs.mkcol_all(cfg, &format!("{}/covers/", remote_root.trim_end_matches('/')))?;
    for entry in books {
        if let Err(e) = transfer_one_cover(fs, cfg, remote_root, entry, cover_store, report, &mut on_downloaded) {
            report.errors.push(format!("《{}》封面传输失败: {e}", entry.title));
        }
    }
    Ok(())
}

fn transfer_one_cover<F, C>(
    fs: &F,
    cfg: &WebDavConfig,
    remote_root: &str,
    entry: &CoverEntry,
    cover_store: &C,
    report: &mut SyncReport,
    on_downloaded: &mut dyn FnMut(&str, &Path),
) -> Result<()>
where
    F: DavFs,
    C: CoverStore,
{
    let hash = &entry.cover_hash;
    if hash.is_empty() {
        return Ok(());
    }
    let remote = cover_remote_path(remote_root, hash);
    let remote_has = {
        let names = fs.list_names(cfg, &cover_prefix(remote_root, hash))?;
        names.iter().any(|n| n == hash)
    };

    let local = match &entry.local_path {
        Some(p) if p.exists() => Some(p.clone()),
        _ => match cover_store.path_for(hash)? {
            Some(p) if p.exists() => Some(p),
            _ => None,
        },
    };

    if let Some(local) = local {
        if !remote_has {
            let bytes = std::fs::read(&local)?;
            fs.put_atomic(cfg, &remote, bytes)?;
            report.uploaded_covers += 1;
        }
        return Ok(());
    }

    if !remote_has {
        return Ok(());
    }
    let bytes = fs.get_bytes(cfg, &remote)?;
    let actual = sha256_bytes(&bytes);
    if actual != *hash {
        report.errors.push(format!(
            "《{}》封面校验失败（期望 {hash}，实际 {actual}），已丢弃",
            entry.title
        ));
        return Ok(());
    }
    let ext = cover_ext(&bytes);
    let tmp = std::env::temp_dir().join(format!("{}.tmp-{}", hash, nanos()));
    std::fs::write(&tmp, &bytes)?;
    let dest = cover_store.import_file(&tmp, hash, ext)?;
    let _ = std::fs::remove_file(&tmp);
    on_downloaded(hash, &dest);
    report.downloaded_covers += 1;
    Ok(())
}

// ─────────────────────────── 落盘实现（供 CLI / UOS 原生同步） ───────────────────────────

/// 基于文件系统的 `BlobStore`：`<root>/blobs/<sha[:2]>/<sha>`。
pub struct FsBlobStore {
    pub root: PathBuf,
}

impl FsBlobStore {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }
}

impl BlobStore for FsBlobStore {
    fn path_for(&self, sha256: &str) -> Result<Option<PathBuf>> {
        if sha256.is_empty() {
            return Ok(None);
        }
        let p = self.root.join("blobs").join(&sha256[..2]).join(sha256);
        Ok(if p.exists() { Some(p) } else { None })
    }

    fn import_file(&self, source: &Path, sha256: &str) -> Result<PathBuf> {
        let dir = self.root.join("blobs").join(&sha256[..2]);
        std::fs::create_dir_all(&dir)?;
        let dest = dir.join(sha256);
        let tmp = dest.with_extension(format!("tmp-{}", nanos()));
        std::fs::copy(source, &tmp)?;
        std::fs::rename(&tmp, &dest)?;
        Ok(dest)
    }
}

/// 基于文件系统的 `CoverStore`：`<root>/covers/<hash>.<ext>`。
pub struct FsCoverStore {
    pub root: PathBuf,
}

impl FsCoverStore {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }
}

impl CoverStore for FsCoverStore {
    fn path_for(&self, cover_hash: &str) -> Result<Option<PathBuf>> {
        if cover_hash.is_empty() {
            return Ok(None);
        }
        let dir = self.root.join("covers");
        for ext in [".jpg", ".png", ".webp", ".gif"] {
            let p = dir.join(format!("{cover_hash}{ext}"));
            if p.exists() {
                return Ok(Some(p));
            }
        }
        Ok(None)
    }

    fn import_file(&self, source: &Path, cover_hash: &str, ext: &str) -> Result<PathBuf> {
        let dir = self.root.join("covers");
        std::fs::create_dir_all(&dir)?;
        let dest = dir.join(format!("{cover_hash}{ext}"));
        let tmp = dest.with_extension(format!("tmp-{}", nanos()));
        std::fs::copy(source, &tmp)?;
        std::fs::rename(&tmp, &dest)?;
        Ok(dest)
    }
}

// ─────────────────────────── 单测（内存 WebDAV + 内存仓库，无需真实服务器） ───────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::Error;
    use std::cell::RefCell;
    use std::collections::HashMap;

    struct MemDav {
        store: RefCell<HashMap<String, Vec<u8>>>,
    }

    impl DavFs for MemDav {
        fn mkcol_all(&self, _cfg: &WebDavConfig, _path: &str) -> Result<()> {
            Ok(())
        }
        fn list_names(&self, _cfg: &WebDavConfig, dir: &str) -> Result<Vec<String>> {
            let prefix = format!("{}/", dir.trim_end_matches('/'));
            Ok(self
                .store
                .borrow()
                .keys()
                .filter(|k| k.starts_with(&prefix))
                .map(|k| k[prefix.len()..].to_string())
                .filter(|rel| !rel.is_empty() && !rel.contains('/'))
                .collect())
        }
        fn get_bytes(&self, _cfg: &WebDavConfig, path: &str) -> Result<Vec<u8>> {
            self.store
                .borrow()
                .get(path)
                .cloned()
                .ok_or_else(|| Error::Dav { status: 404, message: format!("缺失 {path}") })
        }
        fn put_atomic(&self, _cfg: &WebDavConfig, path: &str, body: Vec<u8>) -> Result<()> {
            self.store.borrow_mut().insert(path.to_string(), body);
            Ok(())
        }
    }

    struct MemBlobStore {
        files: RefCell<HashMap<String, PathBuf>>,
    }
    impl BlobStore for MemBlobStore {
        fn path_for(&self, sha: &str) -> Result<Option<PathBuf>> {
            Ok(self.files.borrow().get(sha).cloned())
        }
        fn import_file(&self, source: &Path, sha: &str) -> Result<PathBuf> {
            let dest = std::env::temp_dir().join(sha);
            std::fs::copy(source, &dest)?;
            self.files.borrow_mut().insert(sha.to_string(), dest.clone());
            Ok(dest)
        }
    }

    struct MemCoverStore {
        files: RefCell<HashMap<String, PathBuf>>,
    }
    impl CoverStore for MemCoverStore {
        fn path_for(&self, h: &str) -> Result<Option<PathBuf>> {
            Ok(self.files.borrow().get(h).cloned())
        }
        fn import_file(&self, source: &Path, h: &str, ext: &str) -> Result<PathBuf> {
            let dest = std::env::temp_dir().join(format!("{h}{ext}"));
            std::fs::copy(source, &dest)?;
            self.files.borrow_mut().insert(h.to_string(), dest.clone());
            Ok(dest)
        }
    }

    fn cfg() -> WebDavConfig {
        WebDavConfig {
            base_url: "https://mock/".into(),
            username: String::new(),
            password: String::new(),
            accept_invalid_certs: false,
            user_agent: None,
        }
    }

    fn jpeg_cover() -> Vec<u8> {
        let mut b = vec![0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46];
        b.extend_from_slice(&[0u8; 200]);
        b
    }

    #[test]
    fn cover_cross_end_transfer_and_idempotent() {
        let dav = MemDav { store: RefCell::new(HashMap::new()) };
        let cfg = cfg();
        let cover = jpeg_cover();
        let hash = sha256_bytes(&cover);

        // A 端：封面字节在本地
        let a_file = std::env::temp_dir().join(format!("{hash}.jpg"));
        std::fs::write(&a_file, &cover).unwrap();
        let a_store = MemCoverStore { files: RefCell::new(HashMap::new()) };
        a_store.files.borrow_mut().insert(hash.clone(), a_file.clone());

        let mut rep_a = SyncReport::default();
        transfer_covers(
            &dav,
            &cfg,
            "inksync",
            &[CoverEntry { title: "有封面的书".into(), cover_hash: hash.clone(), local_path: Some(a_file.clone()) }],
            &a_store,
            &mut rep_a,
            |_, _| {},
        )
        .unwrap();
        assert_eq!(rep_a.uploaded_covers, 1, "A 应上传 1 张封面");
        assert!(
            dav.store.borrow().keys().any(|k| k.ends_with(&hash)),
            "远端应存在封面"
        );

        // B 端：只有 hash，无本地字节
        let b_store = MemCoverStore { files: RefCell::new(HashMap::new()) };
        let mut rep_b = SyncReport::default();
        let mut landed = PathBuf::new();
        transfer_covers(
            &dav,
            &cfg,
            "inksync",
            &[CoverEntry { title: "有封面的书".into(), cover_hash: hash.clone(), local_path: None }],
            &b_store,
            &mut rep_b,
            |_, p| landed = p.to_path_buf(),
        )
        .unwrap();
        assert_eq!(rep_b.downloaded_covers, 1, "B 应下载 1 张封面");
        assert!(b_store.files.borrow().contains_key(&hash), "B 仓库应含该 hash");
        let bytes = std::fs::read(&landed).unwrap();
        assert_eq!(sha256_bytes(&bytes), hash, "落地封面 sha256 应与原图一致");
        assert!(landed.to_string_lossy().ends_with(".jpg"), "扩展名应为 .jpg");

        // 幂等：二次同步不再重复上传/下载
        let mut rep_a2 = SyncReport::default();
        transfer_covers(
            &dav,
            &cfg,
            "inksync",
            &[CoverEntry { title: "有封面的书".into(), cover_hash: hash.clone(), local_path: Some(a_file.clone()) }],
            &a_store,
            &mut rep_a2,
            |_, _| {},
        )
        .unwrap();
        assert_eq!(rep_a2.uploaded_covers, 0, "幂等：A 不应重复上传");
        let mut rep_b2 = SyncReport::default();
        transfer_covers(
            &dav,
            &cfg,
            "inksync",
            &[CoverEntry { title: "有封面的书".into(), cover_hash: hash.clone(), local_path: None }],
            &b_store,
            &mut rep_b2,
            |_, _| {},
        )
        .unwrap();
        assert_eq!(rep_b2.downloaded_covers, 0, "幂等：B 不应重复下载");
    }

    #[test]
    fn blob_cross_end_transfer_and_checksum_reject() {
        let dav = MemDav { store: RefCell::new(HashMap::new()) };
        let cfg = cfg();
        let content = b"hello inksync book content".to_vec();
        let sha = sha256_bytes(&content);

        let a_file = std::env::temp_dir().join(&sha);
        std::fs::write(&a_file, &content).unwrap();
        let a_store = MemBlobStore { files: RefCell::new(HashMap::new()) };
        a_store.files.borrow_mut().insert(sha.clone(), a_file.clone());

        let mut rep_a = SyncReport::default();
        transfer_blobs(
            &dav,
            &cfg,
            "inksync",
            &[BlobEntry { title: "书A".into(), sha256: sha.clone(), local_path: Some(a_file.clone()) }],
            &a_store,
            &mut rep_a,
            |_, _| {},
        )
        .unwrap();
        assert_eq!(rep_a.uploaded_books, 1);

        // B 端下载
        let b_store = MemBlobStore { files: RefCell::new(HashMap::new()) };
        let mut rep_b = SyncReport::default();
        let mut landed = PathBuf::new();
        transfer_blobs(
            &dav,
            &cfg,
            "inksync",
            &[BlobEntry { title: "书A".into(), sha256: sha.clone(), local_path: None }],
            &b_store,
            &mut rep_b,
            |_, p| landed = p.to_path_buf(),
        )
        .unwrap();
        assert_eq!(rep_b.downloaded_books, 1);
        let bytes = std::fs::read(&landed).unwrap();
        assert_eq!(sha256_bytes(&bytes), sha, "落地书籍 sha256 应一致");

        // 篡改远端内容 → 下载分支应校验失败、丢弃、不计入下载
        dav.store
            .borrow_mut()
            .insert(format!("inksync/blobs/{}/{}", &sha[..2], sha), b"tampered".to_vec());
        let b_store2 = MemBlobStore { files: RefCell::new(HashMap::new()) };
        let mut rep_bad = SyncReport::default();
        transfer_blobs(
            &dav,
            &cfg,
            "inksync",
            &[BlobEntry { title: "书A".into(), sha256: sha.clone(), local_path: None }],
            &b_store2,
            &mut rep_bad,
            |_, _| {},
        )
        .unwrap();
        assert_eq!(rep_bad.downloaded_books, 0, "篡改内容不应被当作正常下载");
        assert!(!rep_bad.errors.is_empty(), "应记录校验错误");
    }

    #[test]
    fn cover_ext_detection() {
        assert_eq!(cover_ext(&[0xFF, 0xD8, 0xFF, 0xE0]), ".jpg");
        assert_eq!(cover_ext(b"\x89PNG\r\n\x1a\nrest"), ".png");
        assert_eq!(cover_ext(b"GIF89a"), ".gif");
        assert_eq!(cover_ext(b"RIFFxxxxWEBP"), ".webp");
        assert_eq!(cover_ext(b"????"), ".jpg"); // 未知兜底 jpg
    }
}
