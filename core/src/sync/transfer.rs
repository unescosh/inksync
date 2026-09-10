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

use std::collections::HashSet;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use serde::{Deserialize, Serialize};

use crate::error::Result;
use crate::model::{SyncReport, WebDavConfig};

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

    /// 流式上传：把本地文件 `local`（字节数 `len`）直接推到远端，**不整文件进内存**。
    ///
    /// 这是大书（cbz / pdf 动辄几百 MB）不 OOM 的关键，与 Dart 侧
    /// `putAtomicStream` 对齐。小数据（manifest / 变更批次）继续用 [DavFs::put_atomic]。
    fn put_file(&self, cfg: &WebDavConfig, path: &str, local: &Path, len: u64) -> Result<()>;

    /// 流式下载：边收边写进本地文件 `dest`，**不整文件进内存**（与 Dart 侧
    /// `getBytesStream` 对齐）。
    ///
    /// 完整性交给调用方用 sha256 校验——比对 Content-Length 更可靠，
    /// 也避开「开了 gzip 后声明长度与实际解码字节数不一致」的坑。
    fn get_to_file(&self, cfg: &WebDavConfig, path: &str, dest: &Path) -> Result<()>;
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
    /// 把 `source` 复制为 `<root>/cache/covers/<hash>.<ext>`（与 App 的
    /// `DefaultCoverStore` 对齐；`FsCoverStore` 经 `cover_dir()` 落盘到此），返回最终路径。
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

/// 从文件头部魔数推断封面扩展名：只读前 12 字节，不把整张图读进内存。
///
/// 流式下载落地后用它决定文件名后缀——避免为了探测格式又把整文件加载一遍，
/// 否则"流式"省下的内存会在这一步被吃回去。
fn cover_ext_of_file(path: &Path) -> Result<&'static str> {
    let mut f = std::fs::File::open(path)?;
    let mut head = [0u8; 12];
    let n = f.read(&mut head)?;
    Ok(cover_ext(&head[..n]))
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
            // 流式上传：不再 `std::fs::read` 整文件（几百 MB 的 cbz 会直接吃满内存），
            // 而是把文件长度 + 路径交给传输层，由它流式推送（Dart 侧 putAtomicStream 同款）。
            let len = std::fs::metadata(&local)?.len();
            fs.put_file(cfg, &remote, &local, len)?;
            report.uploaded_books += 1;
        }
        return Ok(());
    }

    // 下载分支（流式：边收边落盘 → 流式回读校验 sha256 → 入库，全程不整文件进内存）
    if !remote_has {
        return Ok(());
    }
    let tmp = std::env::temp_dir().join(format!("{}.tmp-{}", sha, nanos()));
    if let Err(e) = fs.get_to_file(cfg, &remote, &tmp) {
        let _ = std::fs::remove_file(&tmp);
        return Err(e);
    }
    // sha256_file 本身是流式分块读的（见 lib.rs），不会把书重新读进内存
    let actual = match crate::sha256_file(&tmp) {
        Ok(v) => v,
        Err(e) => {
            let _ = std::fs::remove_file(&tmp);
            return Err(e);
        }
    };
    if actual != *sha {
        let _ = std::fs::remove_file(&tmp);
        report.errors.push(format!(
            "《{}》书籍校验失败（期望 {sha}，实际 {actual}），已丢弃",
            entry.title
        ));
        return Ok(());
    }
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
            // 同 blobs：流式上传，不整文件进内存
            let len = std::fs::metadata(&local)?.len();
            fs.put_file(cfg, &remote, &local, len)?;
            report.uploaded_covers += 1;
        }
        return Ok(());
    }

    if !remote_has {
        return Ok(());
    }
    // 同 blobs：流式下载落盘 → 流式回读校验 → 魔数只取文件头 12 字节定扩展名
    let tmp = std::env::temp_dir().join(format!("{}.tmp-{}", hash, nanos()));
    if let Err(e) = fs.get_to_file(cfg, &remote, &tmp) {
        let _ = std::fs::remove_file(&tmp);
        return Err(e);
    }
    let actual = match crate::sha256_file(&tmp) {
        Ok(v) => v,
        Err(e) => {
            let _ = std::fs::remove_file(&tmp);
            return Err(e);
        }
    };
    if actual != *hash {
        let _ = std::fs::remove_file(&tmp);
        report.errors.push(format!(
            "《{}》封面校验失败（期望 {hash}，实际 {actual}），已丢弃",
            entry.title
        ));
        return Ok(());
    }
    let ext = cover_ext_of_file(&tmp)?;
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

/// 基于文件系统的 `CoverStore`。
///
/// **刻意与 App 的 `DefaultCoverStore` 对齐**：App 把封面存在
/// `<appDocDir>/cache/covers/<hash>.<ext>`，书籍原文件存在 `<appDocDir>/blobs/...`
/// （见 `FsBlobStore`）。所以把 CLI 的 `--store` 指向 App 的文档目录后，CLI `pull`
/// 拉回的封面正好落在 `<store>/cache/covers/...`、书落在 `<store>/blobs/...`，
/// 与 App 的 `pathFor(coverHash/sha256)` 查找路径一致——App 无需改 DB 即可直接读到。
pub struct FsCoverStore {
    pub root: PathBuf,
}

impl FsCoverStore {
    pub fn new(root: impl Into<PathBuf>) -> Self {
        Self { root: root.into() }
    }

    /// 对齐 App：`DefaultCoverStore` 的本地根 = `<appDocDir>/cache`。
    fn cover_dir(&self) -> PathBuf {
        self.root.join("cache").join("covers")
    }
}

impl CoverStore for FsCoverStore {
    fn path_for(&self, cover_hash: &str) -> Result<Option<PathBuf>> {
        if cover_hash.is_empty() {
            return Ok(None);
        }
        let dir = self.cover_dir();
        for ext in [".jpg", ".png", ".webp", ".gif"] {
            let p = dir.join(format!("{cover_hash}{ext}"));
            if p.exists() {
                return Ok(Some(p));
            }
        }
        Ok(None)
    }

    fn import_file(&self, source: &Path, cover_hash: &str, ext: &str) -> Result<PathBuf> {
        let dir = self.cover_dir();
        std::fs::create_dir_all(&dir)?;
        let dest = dir.join(format!("{cover_hash}{ext}"));
        let tmp = dest.with_extension(format!("tmp-{}", nanos()));
        std::fs::copy(source, &tmp)?;
        std::fs::rename(&tmp, &dest)?;
        Ok(dest)
    }
}

// ─────────────────────────── 本地仓库完整性校验（verify） ───────────────────────────
//
// 无头备份不是"传完就完"——磁盘静默损坏、半截文件、中断残留都会让备份在
// 需要恢复的关键时刻才发现读不了。内容寻址天然提供自检手段：blob 文件名本身
// 就是 sha256，封面文件名（去扩展名）也是 coverHash。逐个重算 sha256 比对，
// 不符即损坏。供 CLI `verify` 子命令与未来的"备份健康检查"调用。

/// 本地仓库完整性校验结果。
#[derive(Debug, Default, Clone)]
pub struct StoreVerify {
    pub blobs_total: usize,
    pub blobs_ok: usize,
    pub covers_total: usize,
    pub covers_ok: usize,
    /// (预期哈希, 实际哈希, 绝对路径) —— 文件名（内容寻址键）与内容不符 = 损坏
    pub corrupted: Vec<(String, String, PathBuf)>,
}

impl StoreVerify {
    pub fn ok(&self) -> bool {
        self.corrupted.is_empty()
    }
}

/// 校验本地仓库：每个 blob 文件的内容 sha256 必须等于其文件名，每个封面文件的
/// 内容 sha256 必须等于其文件名（去扩展名）。返回统计与损坏清单（损坏信息不写库，
/// 让调用方决定是删是修）。
pub fn verify_store(blob_store: &FsBlobStore, cover_store: &FsCoverStore) -> Result<StoreVerify> {
    let mut v = StoreVerify::default();

    let blobs_root = blob_store.root.join("blobs");
    for e in walk_files(&blobs_root)? {
        let name = e.file_name().to_string_lossy().to_string();
        if name.contains(".tmp-") {
            continue; // 跳过 import_file 的临时文件
        }
        v.blobs_total += 1;
        let actual = crate::sha256_file(&e.path())?;
        if actual == name {
            v.blobs_ok += 1;
        } else {
            v.corrupted.push((name, actual, e.path()));
        }
    }

    let covers_root = cover_store.cover_dir();
    for e in walk_files(&covers_root)? {
        let name = e.file_name().to_string_lossy().to_string();
        if name.contains(".tmp-") {
            continue;
        }
        // 封面文件名是 <hash>.<ext>，去扩展名得到内容寻址键
        let expected = match name.rfind('.') {
            Some(i) => name[..i].to_string(),
            None => name.clone(),
        };
        v.covers_total += 1;
        let actual = crate::sha256_file(&e.path())?;
        if actual == expected {
            v.covers_ok += 1;
        } else {
            v.corrupted.push((expected, actual, e.path()));
        }
    }

    Ok(v)
}

/// 递归收集目录下所有普通文件（目录不存在时返回空，不报错）。
fn walk_files(dir: &Path) -> Result<Vec<std::fs::DirEntry>> {
    let mut out = Vec::new();
    if !dir.exists() {
        return Ok(out);
    }
    let mut stack = vec![dir.to_path_buf()];
    while let Some(cur) = stack.pop() {
        for entry in std::fs::read_dir(&cur)? {
            let entry = entry?;
            let p = entry.path();
            if p.is_dir() {
                stack.push(p);
            } else {
                out.push(entry);
            }
        }
    }
    Ok(out)
}

// ─────────────────────────── 本地仓库孤儿回收（gc） ───────────────────────────
//
// 书被删除后，其 blob / 封面不会自动从本地仓库消失——内容寻址决定一个文件可能被多本书
// 共享，删某本书不能贸然删文件。以 `BookIndex` 为"仍被引用"的白名单做 GC：文件名
// （内容寻址键）不在白名单中的即孤儿，删除。建议先 `verify` 再 `gc`。

/// 回收本地仓库里"没有任何书引用"的孤立 blob / 封面。
///
/// 以 [BookIndex] 为白名单：文件名（内容寻址键）不在白名单中的文件即孤儿，删除。
/// 返回移除的条目数。安全边界：只删白名单外文件、绝不删白名单内文件、不动远端。
pub fn gc_store(blob_store: &FsBlobStore, cover_store: &FsCoverStore, index: &BookIndex) -> Result<usize> {
    let referenced_blobs: HashSet<&str> =
        index.entries.iter().map(|e| e.sha256.as_str()).collect();
    let referenced_covers: HashSet<&str> = index
        .entries
        .iter()
        .filter_map(|e| e.cover_hash.as_deref())
        .collect();

    let mut removed = 0;

    for e in walk_files(&blob_store.root.join("blobs"))? {
        let name = e.file_name().to_string_lossy().to_string();
        if name.contains(".tmp-") {
            continue;
        }
        if !referenced_blobs.contains(name.as_str()) {
            std::fs::remove_file(e.path())?;
            removed += 1;
        }
    }

    for e in walk_files(&cover_store.cover_dir())? {
        let name = e.file_name().to_string_lossy().to_string();
        if name.contains(".tmp-") {
            continue;
        }
        let hash = match name.rfind('.') {
            Some(i) => name[..i].to_string(),
            None => name.clone(),
        };
        if !referenced_covers.contains(hash.as_str()) {
            std::fs::remove_file(e.path())?;
            removed += 1;
        }
    }

    Ok(removed)
}

// ─────────────────────────── 无头 CLI 辅助（扫描本地目录 → 传输条目） ───────────────────────────
//
// 给 UOS / CLI 路径一个最小可用的入口：扫描本地书目录与封面目录，按内容寻址构建
// 传输条目，再交给 transfer_blobs / transfer_covers。无需数据库或完整 SyncEngine。

/// 书籍文件扩展名（与 core 解析支持的格式对齐）
pub fn is_book_file(path: &Path) -> bool {
    matches!(
        path.extension()
            .and_then(|e| e.to_str())
            .map(|s| s.to_ascii_lowercase())
            .as_deref(),
        Some("epub")
            | Some("mobi")
            | Some("azw")
            | Some("azw3")
            | Some("txt")
            | Some("pdf")
            | Some("cbz")
            | Some("cbr")
    )
}

/// 封面图片扩展名
pub fn is_cover_file(path: &Path) -> bool {
    matches!(
        path.extension()
            .and_then(|e| e.to_str())
            .map(|s| s.to_ascii_lowercase())
            .as_deref(),
        Some("jpg") | Some("jpeg") | Some("png") | Some("webp") | Some("gif")
    )
}

/// 递归扫描目录下的书籍文件，按内容寻址构建传输条目。
/// 书名取文件名（去扩展名）；sha256 用流式计算（大文件不整体读内存）。
pub fn scan_book_dir(dir: &Path) -> Result<Vec<BlobEntry>> {
    let mut out = Vec::new();
    collect_books(dir, &mut out)?;
    Ok(out)
}

fn collect_books(dir: &Path, out: &mut Vec<BlobEntry>) -> Result<()> {
    for ent in std::fs::read_dir(dir)? {
        let ent = ent?;
        let path = ent.path();
        if path.is_dir() {
            collect_books(&path, out)?;
        } else if is_book_file(&path) {
            let sha = crate::sha256_file(&path)?;
            let title = path
                .file_stem()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_default();
            out.push(BlobEntry { title, sha256: sha, local_path: Some(path) });
        }
    }
    Ok(())
}

/// 把封面目录里的图片按「文件名（去扩展名）」与书籍配对，构建封面传输条目。
/// 封面按 coverHash 内容寻址（字节 sha256）。
pub fn pair_covers(books: &[BlobEntry], covers_dir: &Path) -> Result<Vec<CoverEntry>> {
    if !covers_dir.is_dir() {
        return Ok(Vec::new());
    }
    let mut out = Vec::new();
    for ent in std::fs::read_dir(covers_dir)? {
        let ent = ent?;
        let path = ent.path();
        if path.is_dir() || !is_cover_file(&path) {
            continue;
        }
        let stem = match path.file_stem() {
            Some(s) => s.to_string_lossy().into_owned(),
            None => continue,
        };
        if books.iter().any(|b| b.title == stem) {
            let hash = crate::sha256_file(&path)?;
            out.push(CoverEntry { title: stem, cover_hash: hash, local_path: Some(path) });
        }
    }
    Ok(out)
}

/// 枚举远端 `blobs/` 与 `covers/` 下所有内容寻址条目（用于 pull/restore 模式：
/// 把本地没有的书/封面也按 sha256 拉回来）。返回 `(blob_sha 列表, cover_hash 列表)`。
pub fn list_remote<F: DavFs>(
    fs: &F,
    cfg: &WebDavConfig,
    remote_root: &str,
) -> Result<(Vec<String>, Vec<String>)> {
    let root = remote_root.trim_end_matches('/');
    let mut blobs = Vec::new();
    let mut covers = Vec::new();
    for i in 0..256u32 {
        let bp = format!("{root}/blobs/{i:02x}");
        for n in fs.list_names(cfg, &bp)? {
            if !n.is_empty() && !n.contains('/') {
                blobs.push(n);
            }
        }
        let cp = format!("{root}/covers/{i:02x}");
        for n in fs.list_names(cfg, &cp)? {
            if !n.is_empty() && !n.contains('/') {
                covers.push(n);
            }
        }
    }
    Ok((blobs, covers))
}

// ─────────────────────────── 端到端编排（供 CLI / 未来 Rust SyncEngine 复用） ───────────────────────────

/// 本地目录 → 远端 的一次完整推送编排：scan_book_dir → pair_covers →
/// transfer_blobs → transfer_covers。返回扫描到的书籍/封面条目，供调用方写本地索引。
/// 纯 `DavFs` 抽象，故可用内存实现单测；真实 CLI 传 `WebDavClient`（`sync` feature）。
pub fn sync_local_books<F, B, C>(
    fs: &F,
    cfg: &WebDavConfig,
    remote_root: &str,
    books_dir: &Path,
    covers_dir: &Path,
    blob_store: &B,
    cover_store: &C,
    report: &mut SyncReport,
    mut on_downloaded: impl FnMut(&str, &Path),
) -> Result<(Vec<BlobEntry>, Vec<CoverEntry>)>
where
    F: DavFs,
    B: BlobStore,
    C: CoverStore,
{
    let books = scan_book_dir(books_dir)?;
    let covers = pair_covers(&books, covers_dir)?;
    transfer_blobs(fs, cfg, remote_root, &books, blob_store, report, &mut on_downloaded)?;
    transfer_covers(fs, cfg, remote_root, &covers, cover_store, report, &mut on_downloaded)?;
    Ok((books, covers))
}

/// 远端 → 本地仓库 的一次完整拉取编排：list_remote 枚举内容寻址条目 →
/// 构造 `local_path=None` 条目 → transfer_blobs / transfer_covers 把本地缺的拉回。
pub fn pull_remote<F, B, C>(
    fs: &F,
    cfg: &WebDavConfig,
    remote_root: &str,
    blob_store: &B,
    cover_store: &C,
    report: &mut SyncReport,
    mut on_downloaded: impl FnMut(&str, &Path),
) -> Result<()>
where
    F: DavFs,
    B: BlobStore,
    C: CoverStore,
{
    let (blob_shas, cover_hashes) = list_remote(fs, cfg, remote_root)?;
    let books: Vec<_> = blob_shas
        .iter()
        .map(|s| BlobEntry { title: s.clone(), sha256: s.clone(), local_path: None })
        .collect();
    let covers: Vec<_> = cover_hashes
        .iter()
        .map(|h| CoverEntry { title: h.clone(), cover_hash: h.clone(), local_path: None })
        .collect();
    transfer_blobs(fs, cfg, remote_root, &books, blob_store, report, &mut on_downloaded)?;
    transfer_covers(fs, cfg, remote_root, &covers, cover_store, report, &mut on_downloaded)?;
    Ok(())
}

/// 本地书籍索引清单（push 后写入 `<store>/book_index.json`）：把内容寻址的
/// sha256 / coverHash 映射回人类可读的书名，便于无头备份后核对"备份了哪些书"。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BookIndexEntry {
    pub title: String,
    pub sha256: String,
    #[serde(default)]
    pub cover_hash: Option<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct BookIndex {
    #[serde(default)]
    pub entries: Vec<BookIndexEntry>,
}

impl BookIndex {
    /// 由扫描结果构造（封面按书名配对到书）。
    pub fn from_scan(books: &[BlobEntry], covers: &[CoverEntry]) -> Self {
        let mut entries = Vec::with_capacity(books.len());
        for b in books {
            let cover_hash = covers
                .iter()
                .find(|c| c.title == b.title)
                .map(|c| c.cover_hash.clone());
            entries.push(BookIndexEntry {
                title: b.title.clone(),
                sha256: b.sha256.clone(),
                cover_hash,
            });
        }
        Self { entries }
    }

    /// 写入 `<dir>/book_index.json`（覆盖式，原子：先 tmp 再 rename）。
    pub fn write_to(&self, dir: &Path) -> Result<()> {
        std::fs::create_dir_all(dir)?;
        let json = serde_json::to_vec_pretty(self)
            .map_err(|e| crate::error::Error::Other(format!("序列化索引失败：{e}")))?;
        let dest = dir.join("book_index.json");
        let tmp = dest.with_extension(format!("tmp-{}", nanos()));
        std::fs::write(&tmp, &json)?;
        std::fs::rename(&tmp, &dest)?;
        Ok(())
    }

    /// 读取 `<dir>/book_index.json`；文件不存在返回空索引。
    pub fn read_from(dir: &Path) -> Result<Self> {
        let p = dir.join("book_index.json");
        if !p.exists() {
            return Ok(Self::default());
        }
        let s = std::fs::read_to_string(&p)?;
        serde_json::from_str(&s).map_err(|e| crate::error::Error::Other(format!("解析索引失败：{e}")))
    }
}

// ─────────────────────────── 单测（内存 WebDAV + 内存仓库，无需真实服务器） ───────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::Error;
    // 非测试代码已全部改用流式 `crate::sha256_file`，这里只在断言里需要整段哈希
    use crate::sha256_bytes;
    use std::cell::{Cell, RefCell};
    use std::collections::HashMap;

    struct MemDav {
        store: RefCell<HashMap<String, Vec<u8>>>,
        /// 流式方法的命中计数：用来断言大文件确实走 `put_file` / `get_to_file`，
        /// 而不是退回"整文件进内存"的 `put_atomic(Vec<u8>)` / `get_bytes`
        /// （对应 Dart 侧 MockWebDavClient 的 streamPutCount / streamGetCount）。
        put_file_calls: Cell<u32>,
        get_to_file_calls: Cell<u32>,
    }

    impl MemDav {
        fn new() -> Self {
            Self {
                store: RefCell::new(HashMap::new()),
                put_file_calls: Cell::new(0),
                get_to_file_calls: Cell::new(0),
            }
        }
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

        fn put_file(&self, cfg: &WebDavConfig, path: &str, local: &Path, len: u64) -> Result<()> {
            self.put_file_calls.set(self.put_file_calls.get() + 1);
            // 内存实现无法真流式，但依然"按文件"读，并校验调用方给的长度，
            // 保证生产实现拿到的是真实的字节数（流式 PUT 要带 Content-Length）。
            let bytes = std::fs::read(local)?;
            if bytes.len() as u64 != len {
                return Err(Error::Other(format!(
                    "put_file 长度不符：实际 {} 字节，声明 {len}",
                    bytes.len()
                )));
            }
            self.put_atomic(cfg, path, bytes)
        }

        fn get_to_file(&self, cfg: &WebDavConfig, path: &str, dest: &Path) -> Result<()> {
            self.get_to_file_calls.set(self.get_to_file_calls.get() + 1);
            let bytes = self.get_bytes(cfg, path)?;
            std::fs::write(dest, &bytes)?;
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
        let dav = MemDav::new();
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
        let dav = MemDav::new();
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

    /// 流式路径守卫：书籍上传/下载**必须**走 `put_file` / `get_to_file`，
    /// 而不是退回"整文件进内存"的 `put_atomic(Vec<u8>)` / `get_bytes`。
    ///
    /// 这是 Rust 侧对齐 Dart P1（避免大书 OOM）的回归锁：若有人把
    /// `transfer_one_blob` 改回 `std::fs::read` + `put_atomic`，此测试立即挂。
    #[test]
    fn blob_transfer_uses_streaming_paths() {
        let dav = MemDav::new();
        let cfg = cfg();
        // 用一份"不小"的书文件，才谈得上流式改造的意义
        let content: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
        let sha = sha256_bytes(&content);

        let a_file = std::env::temp_dir().join(format!("{sha}.epub"));
        std::fs::write(&a_file, &content).unwrap();
        let a_store = MemBlobStore { files: RefCell::new(HashMap::new()) };
        a_store.files.borrow_mut().insert(sha.clone(), a_file.clone());

        // 上传：应命中 put_file（且长度声明正确）
        let mut rep_a = SyncReport::default();
        transfer_blobs(
            &dav,
            &cfg,
            "inksync",
            &[BlobEntry { title: "大书".into(), sha256: sha.clone(), local_path: Some(a_file.clone()) }],
            &a_store,
            &mut rep_a,
            |_, _| {},
        )
        .unwrap();
        assert_eq!(rep_a.uploaded_books, 1);
        assert_eq!(dav.put_file_calls.get(), 1, "上传必须走流式 put_file，而非整文件读进内存");

        // 下载：应命中 get_to_file，且落地字节 sha256 与原书一致
        let b_store = MemBlobStore { files: RefCell::new(HashMap::new()) };
        let mut rep_b = SyncReport::default();
        let mut landed = PathBuf::new();
        transfer_blobs(
            &dav,
            &cfg,
            "inksync",
            &[BlobEntry { title: "大书".into(), sha256: sha.clone(), local_path: None }],
            &b_store,
            &mut rep_b,
            |_, p| landed = p.to_path_buf(),
        )
        .unwrap();
        assert_eq!(rep_b.downloaded_books, 1);
        assert_eq!(dav.get_to_file_calls.get(), 1, "下载必须走流式 get_to_file");
        assert_eq!(crate::sha256_file(&landed).unwrap(), sha, "落地书文件 sha256 应与原书一致");

        // 幂等：远端已有，二次上传不再走传输
        let mut rep_a2 = SyncReport::default();
        transfer_blobs(
            &dav,
            &cfg,
            "inksync",
            &[BlobEntry { title: "大书".into(), sha256: sha.clone(), local_path: Some(a_file.clone()) }],
            &a_store,
            &mut rep_a2,
            |_, _| {},
        )
        .unwrap();
        assert_eq!(dav.put_file_calls.get(), 1, "幂等：不应重复上传");

        let _ = std::fs::remove_file(&a_file);
    }

    #[test]
    fn cover_ext_detection() {
        assert_eq!(cover_ext(&[0xFF, 0xD8, 0xFF, 0xE0]), ".jpg");
        assert_eq!(cover_ext(b"\x89PNG\r\n\x1a\nrest"), ".png");
        assert_eq!(cover_ext(b"GIF89a"), ".gif");
        assert_eq!(cover_ext(b"RIFFxxxxWEBP"), ".webp");
        assert_eq!(cover_ext(b"????"), ".jpg"); // 未知兜底 jpg
    }

    /// 端到端跑通「CLI 扫描本地目录 → 配对封面 → 推到远端」的最小路径，
    /// 验证 scan_book_dir / pair_covers / transfer_blobs / transfer_covers 串起来可用。
    #[test]
    fn cli_scan_pair_and_transfer() {
        let base = std::env::temp_dir().join(format!("inksync_cli_{}", nanos()));
        let books_dir = base.join("books");
        let covers_dir = base.join("covers");
        std::fs::create_dir_all(&books_dir).unwrap();
        std::fs::create_dir_all(&covers_dir).unwrap();

        let book_path = books_dir.join("我的漫画.epub");
        std::fs::write(&book_path, b"inksync cli book payload").unwrap();
        let cover_path = covers_dir.join("我的漫画.jpg");
        std::fs::write(&cover_path, jpeg_cover()).unwrap();

        // 扫描 + 配对
        let books = scan_book_dir(&books_dir).unwrap();
        assert_eq!(books.len(), 1, "应扫到 1 本书");
        assert_eq!(books[0].title, "我的漫画");
        let covers = pair_covers(&books, &covers_dir).unwrap();
        assert_eq!(covers.len(), 1, "应按书名配对到 1 张封面");
        assert_eq!(covers[0].title, "我的漫画");

        // 推到远端（MemDav 模拟 WebDAV）
        let dav = MemDav::new();
        let cfg = cfg();
        let store = FsBlobStore::new(base.join("local_store"));
        let cover_store = FsCoverStore::new(base.join("local_store"));
        let mut rep = SyncReport::default();
        transfer_blobs(&dav, &cfg, "inksync", &books, &store, &mut rep, |_, _| {}).unwrap();
        transfer_covers(&dav, &cfg, "inksync", &covers, &cover_store, &mut rep, |_, _| {}).unwrap();

        assert_eq!(rep.uploaded_books, 1, "应上传 1 本书");
        assert_eq!(rep.uploaded_covers, 1, "应上传 1 张封面");
        assert_eq!(rep.errors.len(), 0, "不应有错误");
        assert!(
            dav.store.borrow().keys().any(|k| k.contains("/blobs/")),
            "远端应有 blobs 条目"
        );
        assert!(
            dav.store.borrow().keys().any(|k| k.contains("/covers/")),
            "远端应有 covers 条目"
        );

        // 幂等：二次推送不再重复上传
        let mut rep2 = SyncReport::default();
        transfer_blobs(&dav, &cfg, "inksync", &books, &store, &mut rep2, |_, _| {}).unwrap();
        transfer_covers(&dav, &cfg, "inksync", &covers, &cover_store, &mut rep2, |_, _| {}).unwrap();
        assert_eq!(rep2.uploaded_books, 0, "幂等：不应重复上传书");
        assert_eq!(rep2.uploaded_covers, 0, "幂等：不应重复上传封面");

        let _ = std::fs::remove_dir_all(&base);
    }

    /// 回归方向 2：`FsCoverStore` 落盘路径必须与 App 的 `DefaultCoverStore` 对齐，
    /// 即 `<root>/cache/covers/<hash>.<ext>`（而非旧的 `<root>/covers/...`）。
    /// 把 CLI 的 `--store` 指向 App 文档目录后，pull 拉回的封面才能被 App 的
    /// `pathFor(coverHash)` 直接命中。若有人把路径改回 `<root>/covers`，此测试立即挂。
    #[test]
    fn fs_cover_store_lands_in_cache_covers() {
        let root = std::env::temp_dir().join(format!("inksync_covalign_{}", nanos()));
        std::fs::create_dir_all(&root).unwrap();
        let cs = FsCoverStore::new(root.clone());

        // 造一张"封面"源文件（字节内容无所谓，ext 由调用方按魔数决定，这里直接传 .jpg）
        let src = root.join("src_cover.bin");
        std::fs::write(&src, jpeg_cover()).unwrap();

        let hash = "deadbeef00c0ffee00face";
        let dest = cs.import_file(&src, hash, ".jpg").unwrap();

        // 关键断言：落盘路径必须含 cache/covers
        let want = root.join("cache").join("covers").join(format!("{hash}.jpg"));
        assert_eq!(dest, want, "封面必须落在 <root>/cache/covers/<hash>.<ext>");
        assert!(dest.exists(), "封面文件应真实写出");

        // path_for 能在同一路径命中
        let found = cs.path_for(hash).unwrap();
        assert_eq!(found, Some(want), "path_for 应在 cache/covers 找到封面");

        // 回归守护：旧的 <root>/covers/<hash>.jpg 绝不应存在
        let old = root.join("covers").join(format!("{hash}.jpg"));
        assert!(!old.exists(), "回归：不应再落到 <root>/covers（与 App 不对齐）");

        let _ = std::fs::remove_dir_all(&root);
    }

    /// 校验应抓出"文件名 sha256 与内容不符"的损坏 blob / 封面，且放过完好文件。
    #[test]
    fn verify_store_detects_corruption() {
        let base = std::env::temp_dir().join(format!("inksync_verify_{}", nanos()));
        std::fs::create_dir_all(&base).unwrap();
        let bs = FsBlobStore::new(base.join("store"));
        let cs = FsCoverStore::new(base.join("store"));

        // 完好的 blob
        let good = base.join("good.bin");
        std::fs::write(&good, b"hello inksync").unwrap();
        let good_sha = crate::sha256_file(&good).unwrap();
        let _ = bs.import_file(&good, &good_sha).unwrap();

        // 损坏的 blob：文件名是"正确 sha"、内容却不同
        let bad_sha = "de".repeat(32);
        let bad_dir = base.join("store").join("blobs").join(&bad_sha[..2]);
        std::fs::create_dir_all(&bad_dir).unwrap();
        std::fs::write(bad_dir.join(&bad_sha), b"TAMPERED").unwrap();

        // 完好的封面
        let cover_src = base.join("cover.bin");
        std::fs::write(&cover_src, jpeg_cover()).unwrap();
        let cover_hash = sha256_bytes(&jpeg_cover());
        let _ = cs.import_file(&cover_src, &cover_hash, ".jpg").unwrap();

        // 损坏的封面
        let bad_cover_hash = "c0".repeat(32);
        let cover_bad_dir = base.join("store").join("cache").join("covers");
        std::fs::create_dir_all(&cover_bad_dir).unwrap();
        std::fs::write(cover_bad_dir.join(format!("{bad_cover_hash}.jpg")), b"TAMPERED-COVER").unwrap();

        let v = verify_store(&bs, &cs).unwrap();
        assert_eq!(v.blobs_total, 2, "应扫到 2 个 blob");
        assert_eq!(v.blobs_ok, 1, "1 完好 1 损坏");
        assert_eq!(v.covers_total, 2, "应扫到 2 个封面");
        assert_eq!(v.covers_ok, 1, "1 完好 1 损坏");
        assert!(!v.ok(), "存在损坏，ok() 应为 false");
        assert_eq!(v.corrupted.len(), 2, "损坏清单应有 2 条");

        let _ = std::fs::remove_dir_all(&base);
    }

    /// 孤儿回收：只删白名单（BookIndex）外的孤立 blob / 封面，保住被引用的，返回移除数。
    /// 删书后未清理的本地仓库，`gc` 应把多余内容寻址文件回收掉，且绝不误删在用书。
    #[test]
    fn gc_store_removes_only_orphans() {
        let base = std::env::temp_dir().join(format!("inksync_gc_{}", nanos()));
        std::fs::create_dir_all(&base).unwrap();
        let bs = FsBlobStore::new(base.join("store"));
        let cs = FsCoverStore::new(base.join("store"));

        // 被引用的 blob（文件名 == sha256）
        let good = base.join("good.bin");
        std::fs::write(&good, b"keep me").unwrap();
        let good_sha = crate::sha256_file(&good).unwrap();
        let _ = bs.import_file(&good, &good_sha).unwrap();

        // 被引用的封面
        let cover_src = base.join("cover.bin");
        std::fs::write(&cover_src, jpeg_cover()).unwrap();
        let cover_hash = sha256_bytes(&jpeg_cover());
        let _ = cs.import_file(&cover_src, &cover_hash, ".jpg").unwrap();

        // 孤儿 blob：不在白名单里
        let orphan_sha = "ab".repeat(32);
        let orphan_blob_dir = base.join("store").join("blobs").join(&orphan_sha[..2]);
        std::fs::create_dir_all(&orphan_blob_dir).unwrap();
        std::fs::write(orphan_blob_dir.join(&orphan_sha), b"orphan blob").unwrap();

        // 孤儿封面
        let orphan_cover_hash = "cd".repeat(32);
        let orphan_cover_dir = cs.cover_dir();
        std::fs::create_dir_all(&orphan_cover_dir).unwrap();
        std::fs::write(orphan_cover_dir.join(format!("{orphan_cover_hash}.jpg")), b"orphan cover").unwrap();

        // 白名单只有被引用的那一本
        let index = BookIndex {
            entries: vec![BookIndexEntry {
                title: "保留的书".into(),
                sha256: good_sha.clone(),
                cover_hash: Some(cover_hash.clone()),
            }],
        };

        let removed = gc_store(&bs, &cs, &index).unwrap();
        assert_eq!(removed, 2, "应移除 2 个孤儿（1 blob + 1 封面）");

        // 被引用的完好无损
        assert!(bs.path_for(&good_sha).unwrap().is_some(), "被引用的 blob 应保留");
        assert!(cs.path_for(&cover_hash).unwrap().is_some(), "被引用的封面应保留");
        // 孤儿已删
        assert!(!orphan_blob_dir.join(&orphan_sha).exists(), "孤儿 blob 应被删除");
        assert!(
            !orphan_cover_dir.join(format!("{orphan_cover_hash}.jpg")).exists(),
            "孤儿封面应被删除"
        );

        let _ = std::fs::remove_dir_all(&base);
    }

    /// `sync_local_books` 串起扫描→配对→推，并产出可读的本地索引清单。
    #[test]
    fn sync_local_books_writes_index() {
        let base = std::env::temp_dir().join(format!("inksync_sync_{}", nanos()));
        let books_dir = base.join("books");
        let covers_dir = base.join("covers");
        let store_dir = base.join("store");
        std::fs::create_dir_all(&books_dir).unwrap();
        std::fs::create_dir_all(&covers_dir).unwrap();
        std::fs::write(books_dir.join("我的漫画.epub"), b"payload").unwrap();
        std::fs::write(covers_dir.join("我的漫画.jpg"), jpeg_cover()).unwrap();

        let dav = MemDav::new();
        let cfg = cfg();
        let bs = FsBlobStore::new(store_dir.clone());
        let cs = FsCoverStore::new(store_dir.clone());
        let mut rep = SyncReport::default();
        let (books, covers) = sync_local_books(
            &dav, &cfg, "inksync", &books_dir, &covers_dir, &bs, &cs, &mut rep, |_, _| {},
        )
        .unwrap();
        assert_eq!(rep.uploaded_books, 1);
        assert_eq!(rep.uploaded_covers, 1);

        let idx = BookIndex::from_scan(&books, &covers);
        idx.write_to(&store_dir).unwrap();
        let back = BookIndex::read_from(&store_dir).unwrap();
        assert_eq!(back.entries.len(), 1, "索引应有 1 条");
        assert_eq!(back.entries[0].title, "我的漫画");
        assert_eq!(back.entries[0].sha256, books[0].sha256);
        assert!(back.entries[0].cover_hash.is_some(), "索引应带封面哈希");
        // 缺文件时读回空索引，不报错
        assert!(BookIndex::read_from(&base.join("nope")).unwrap().entries.is_empty());

        let _ = std::fs::remove_dir_all(&base);
    }

    /// `pull_remote` 把远端有、本地缺的拉回，且幂等。
    #[test]
    fn pull_remote_downloads_missing_and_idempotent() {
        let dav = MemDav::new();
        let cfg = cfg();
        let base = std::env::temp_dir().join(format!("inksync_pull_{}", nanos()));
        let books_dir = base.join("books");
        let covers_dir = base.join("covers");
        std::fs::create_dir_all(&books_dir).unwrap();
        std::fs::create_dir_all(&covers_dir).unwrap();
        std::fs::write(books_dir.join("书A.epub"), b"remote payload").unwrap();
        std::fs::write(covers_dir.join("书A.jpg"), jpeg_cover()).unwrap();
        let src_store = FsBlobStore::new(base.join("src_store"));
        let src_cstore = FsCoverStore::new(base.join("src_store"));
        let mut rep1 = SyncReport::default();
        sync_local_books(
            &dav, &cfg, "inksync", &books_dir, &covers_dir, &src_store, &src_cstore, &mut rep1, |_, _| {},
        )
        .unwrap();
        assert_eq!(rep1.uploaded_books, 1);
        assert_eq!(rep1.uploaded_covers, 1);

        let dst_store = FsBlobStore::new(base.join("dst_store"));
        let dst_cstore = FsCoverStore::new(base.join("dst_store"));
        let mut rep2 = SyncReport::default();
        pull_remote(&dav, &cfg, "inksync", &dst_store, &dst_cstore, &mut rep2, |_, _| {}).unwrap();
        assert_eq!(rep2.downloaded_books, 1);
        assert_eq!(rep2.downloaded_covers, 1);
        let mut rep3 = SyncReport::default();
        pull_remote(&dav, &cfg, "inksync", &dst_store, &dst_cstore, &mut rep3, |_, _| {}).unwrap();
        assert_eq!(rep3.downloaded_books, 0, "幂等：不应重复下载");
        assert_eq!(rep3.downloaded_covers, 0);

        let _ = std::fs::remove_dir_all(&base);
    }
}
