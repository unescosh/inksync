# 09 · 无头 CLI 使用指南（UOS / 服务器 / CI 备份）

`core/examples/cli_backup.rs` 是一个**不依赖 Flutter 引擎**的 Rust 入口，用来把本地书目录 +
封面目录按内容寻址备份到 WebDAV（或反向拉回）。本文档面向运维 / 自托管用户，讲清楚怎么编译、
配置、跑、以及怎么排期成定时备份。

> 它复用的传输逻辑与 App 内 Dart `SyncEngine` 完全一致（`core/src/sync/transfer.rs`）：内容寻址、
> sha256 校验、幂等、免冲突。所以 CLI 备份出来的远端布局（`blobs/<sha[:2]>/<sha>`、
> `covers/<hash[:2]>/<hash>`）与手机/桌面端互通。

## 1. 编译

CLI 需要联网（要 `WebDavClient`），因此门控在 `sync` feature，编译机需带完整 mingw
（Windows 上需 `gcc.exe`/`as.exe`；UOS 20 用系统 `gcc` + `pkg-config` 即可）：

```bash
cd inksync/core
cargo build --release --features sync --example cli_backup
# 产物：target/release/examples/cli_backup
```

> 沙箱 / CI 的 Rust job 跑默认 features（不编 `sync`），故 CLI 二进制不在 CI 编译范围内；
> 其底层传输逻辑由 `core/src/sync/transfer.rs` 的 `cli_scan_pair_and_transfer` 等内存单测在
> 默认 features 下覆盖，`.env` 解析由 `core/src/cli.rs` 单测覆盖。

## 2. 配置文件（推荐，避免命令行明文密码）

建一个 `inksync.env`（权限设 `600`）：

```text
INKSYNC_URL=https://dav.example.com/inksync/
INKSYNC_USER=alice
INKSYNC_PASS=secret
INKSYNC_BOOKS=/srv/inksync/books
INKSYNC_COVERS=/srv/inksync/covers
INKSYNC_STORE=/srv/inksync/store
# INKSYNC_REMOTE=inksync   # 可选，默认 inksync
```

命令行参数优先级高于配置文件；两者可混用（例如配置文件给凭据、命令行临时覆盖目录）。

## 3. 用法

```bash
# 先试跑：只打印将要上传的书/封面（含 sha256/coverHash），不碰远端
./cli_backup push --config ./inksync.env --dry-run

# 正式推送（本地书+封面 → 远端；本地有远端缺才传，幂等）
./cli_backup push --config ./inksync.env

# 把远端有、本地仓库缺的拉回本地 store（用于换机/恢复）
./cli_backup pull --config ./inksync.env

# 不带配置、全命令行（不推荐，密码会进 shell 历史）
./cli_backup push \
    --books /srv/inksync/books --covers /srv/inksync/covers \
    --store /srv/inksync/store \
    --url https://dav.example.com/inksync/ --user alice --pass secret
```

### 目录与产物
- `--books` / `--covers`：待备份的源目录（递归扫描，书名=文件名去扩展名）。
- `--store`：本地仓库根。推送后写入：
  - `store/blobs/<sha[:2]>/<sha>`：书籍原文件（内容寻址）；
  - `store/cache/covers/<hash>.<ext>`：封面（扩展名按魔数）；
  - `store/book_index.json`：人类可读清单（sha256/coverHash 映射回书名），便于核对"备份了哪些书"。
- 远端：与 App 共用的 `inksync/blobs/...`、`inksync/covers/...`。

### 本地仓库校验（verify，不需要网络）

备份不是"传完就完"——磁盘静默损坏、半截文件会在需要恢复时才发现读不了。`verify`
逐个重算 `store/blobs` 与 `store/cache/covers` 里每个文件的 sha256，与内容寻址文件名比对，
抓出"文件名 hash 与内容不符"的损坏项；全部通过退出码 0，有损坏退出码 1（便于定时任务判定）：

```bash
./cli_backup verify --store /srv/inksync/store
# 输出示例：
# 本地仓库完整性校验：blob 12 个（完好 12）/ 封面 8 个（完好 7）
# ❌ 发现 1 处损坏（文件名 sha256 与内容不符）：
#   /srv/inksync/store/cache/covers/<hash>.jpg  预期=<hash> 实际=<实际sha>
```

实现见 `core/src/sync/transfer.rs` 的 `verify_store`（默认 features、可在沙箱/CI 单测，
`verify_store_detects_corruption` 用例覆盖"完好放过 / 损坏抓出"）。建议把 `verify` 接在
定时备份之后跑，损坏即告警。

### 孤儿回收（gc，不需要网络）

删书 / 换书后，本地仓库里会留下"没有任何书引用"的孤立 blob 与封面（内容寻址文件名仍
在，但没有对应的 `book_index.json` 条目）。`gc` 以 `store/book_index.json` 为白名单，
删除白名单之外的 blob / 封面，回收磁盘空间——**只删无引用文件、绝不删白名单内文件、不动远端**：

```bash
./cli_backup gc --store /srv/inksync/store
# 输出示例：
# 已回收 2 个无引用条目（3/ ……/blobs 本书仍被保留）。
```

安全边界（实现见 `core/src/sync/transfer.rs` 的 `gc_store`，默认 features、可在沙箱/CI 单测，
`gc_store_removes_only_orphans` 用例覆盖"只删孤儿 / 保住在用书 / 跳过 .tmp- 临时文件"）：

- **白名单来源**：`<store>/book_index.json`。索引为空或不存在时 `gc` 直接中止（exit 1），避免误删
  全部内容——所以请先 `push`/`pull` 生成索引再 `gc`。
- **匹配方式**：blob 文件名（内容寻址 sha256）必须在某条目的 `sha256` 中；封面文件名（去扩展名）
  必须在某条目的 `cover_hash` 中。否则视为孤儿。
- **建议顺序**：先 `verify` 确认无损坏，再 `gc`；因为 `gc` 只看白名单、不校验内容，若某文件
  内容已损坏但文件名恰好在白名单里，它会被"保住"而非删除（损坏交给 `verify` 告警）。
- **幂等**：再跑一次 `gc`，白名单外的文件已删光，返回 0，不会重复删除或报错。

### 与 App 本地仓库对齐（关键）
CLI 的落盘布局**刻意与 App 对齐**，这样把 `--store` 指向 App 的文档目录后，CLI 拉回的内容
App 能直接读到，无需改数据库：

| 内容 | CLI 落盘（`--store` 为根） | App 查找路径（`DefaultBlobStore`/`DefaultCoverStore`） |
|---|---|---|
| 书籍 | `<store>/blobs/<sha[:2]>/<sha>` | `<appDocDir>/blobs/<sha[:2]>/<sha>` |
| 封面 | `<store>/cache/covers/<hash>.<ext>` | `<appDocDir>/cache/covers/<hash>.<ext>` |

做法：把 `--store` 设为 App 的 `getApplicationDocumentsDirectory()` 返回路径（桌面端通常是
`$XDG_DATA_HOME/<bundleId>/` 或 `~/.config/<app>/`，Android/iOS 为应用私有目录）。`pull` 之后，
App 通过 `pathFor(sha256/coverHash)` 即可命中本地文件（即便 `Books.localPath`/`coverPath`
这两列还是空——它们是可选缓存列，`pathFor` 是兜底查找）。若要让书架 UI 直接显示为"已下载"，
需要把命中的路径回写进 `localPath`/`coverPath`：

- **自动**：`SyncEngine.reconcileLocalRepo()` 已在 `_syncOnce` 的 5c 步调用，下一次 App 同步时自动补齐；
- **即时**：无头 `pull` 完成后（或在 App 启动、恢复本地仓库时）直接调一次 `reconcileLocalRepo()`，
  立即遍历 `books` 表，按 `pathFor` 命中回写。实现与回归测试见 `docs/02` §5.2.2 与 `app/test/cross_end_test.dart` 的 **T8**。

`book_index.json` 示例：

```json
{
  "entries": [
    { "title": "我的漫画", "sha256": "ab12…", "cover_hash": "cd34…" }
  ]
}
```

## 4. 排期成定时备份（UOS / Linux）

### 4.1 systemd 定时器（推荐服务器常驻）

`/etc/systemd/system/inksync-backup.service`：

```ini
[Unit]
Description=inksync headless backup to WebDAV

[Service]
Type=oneshot
User=inksync
# 假设二进制与 inksync.env 放在 /opt/inksync/
ExecStart=/opt/inksync/cli_backup push --config /opt/inksync/inksync.env
# 失败才告警，不影响定时
```

`/etc/systemd/system/inksync-backup.timer`：

```ini
[Unit]
Description=Daily inksync backup

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
RandomizedDelaySec=900

[Install]
WantedBy=timers.target
```

启用：

```bash
systemctl daemon-reload
systemctl enable --now inksync-backup.timer
systemctl status inksync-backup.timer
# 手动跑一次看效果：
systemctl start inksync-backup.service
journalctl -u inksync-backup.service -e
```

### 4.2 cron（无 systemd 的旧环境）

```cron
# 每天 03:07 跑，输出进日志
7 3 * * *  /opt/inksync/cli_backup push --config /opt/inksync/inksync.env >> /var/log/inksync-backup.log 2>&1
```

## 5. 容错与幂等
- 单次失败不中断整轮：某本书传输报错只记进 `SyncReport.errors` 并继续下一本；退出码非零且
   stderr 打印错误清单，便于定时任务监控。
- 幂等：远端已有则跳过，可放心高频/重复跑；内容变了（sha256 不同）才会重新传。
- 校验：从远端下载的书/封面都做 sha256 校验，不符即丢弃，绝不写坏本地文件。
- 自签名证书：加 `--accept-invalid-certs`（仅测试/内网自签服务端用）。

## 6. 与 App 的关系
- CLI 只动**书籍原文件 + 封面字节**（`blobs/` `covers/`），与 App 的 `changes/` 元数据同步互不冲突；
  两者可并存。App 负责进度/分组/高亮等元数据的三方合并，CLI 负责大二进制的无头备份/恢复。
- 恢复场景：新机器上 `pull` 把 `blobs/` `covers/` 拉回 `--store`，App 首次同步元数据后按
  `coverHash`/`sha256` 从本地 store 找到字节，无需重新从网络拉整本。
