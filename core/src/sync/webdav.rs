use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use reqwest::blocking::Client;
use reqwest::header::{HeaderMap, HeaderValue, CONTENT_TYPE, IF_MATCH, IF_NONE_MATCH};
use reqwest::{Method, StatusCode};
use url::Url;

use crate::error::{Error, Result};
use crate::model::WebDavConfig;
use crate::sync::transfer::DavFs;

/// PROPFIND 请求的默认属性集
const PROPFIND_BODY: &str = r#"<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:getetag/>
    <d:getlastmodified/>
    <d:getcontentlength/>
    <d:getcontenttype/>
    <d:resourcetype/>
  </d:prop>
</d:propfind>"#;

#[derive(Debug, Clone)]
pub struct DavEntry {
    /// 相对 base 的路径，已 URL 解码
    pub path: String,
    /// 最后一段文件名
    pub name: String,
    pub is_dir: bool,
    pub size: Option<u64>,
    pub etag: Option<String>,
    pub last_modified: Option<String>,
    pub content_type: Option<String>,
}

/// WebDAV 客户端（阻塞版）。
///
/// 设计要点（全是踩过的坑）：
/// 1. **只追加不覆盖**：所有写入都先 PUT 到临时名，再 MOVE 到正式名，
///    避免中断产生半截文件、也避免并发覆盖。
/// 2. **能力降级**：不支持 MOVE 的服务端（部分网盘网关）自动降级为 COPY + DELETE。
/// 3. **路径逐段编码**：中文书名/空格必须编码，但 `/` 要保留。
/// 4. **幂等**：MKCOL 遇到 405 视为目录已存在；GET 带 If-None-Match 命中 304 返回 None。
/// 5. **退避重试**：5xx / 429 / 423(LOCKED) 才重试，4xx 直接失败。
pub struct WebDavClient {
    base: Url,
    client: Client,
}

impl WebDavClient {
    pub fn new(cfg: &WebDavConfig) -> Result<Self> {
        let mut base = Url::parse(&cfg.base_url).map_err(|e| Error::Other(format!("URL 非法: {e}")))?;
        if !base.path().ends_with('/') {
            let p = format!("{}/", base.path());
            base.set_path(&p);
        }

        let mut headers = HeaderMap::new();
        headers.insert(
            "User-Agent",
            HeaderValue::from_str(
                cfg.user_agent.as_deref().unwrap_or("inksync/1.0 (WebDAV sync)"),
            )
            .unwrap_or(HeaderValue::from_static("inksync/1.0")),
        );

        let mut builder = Client::builder()
            .default_headers(headers)
            .timeout(Duration::from_secs(180))
            .connect_timeout(Duration::from_secs(20))
            .gzip(true);

        if cfg.accept_invalid_certs {
            builder = builder.danger_accept_invalid_certs(true);
        }

        let client = builder.build()?;

        // Basic Auth 放到请求级 header，避免 base_url 里带凭据时被 reqwest 拒绝
        Ok(Self { base, client })
    }

    fn auth(&self, cfg: &WebDavConfig) -> (String, String) {
        (cfg.username.clone(), cfg.password.clone())
    }

    /// 逐段 percent-encode，保留 `/`
    fn url(&self, path: &str) -> Result<Url> {
        let trimmed = path.trim_matches('/');
        let encoded: String = trimmed
            .split('/')
            .filter(|s| !s.is_empty())
            .map(encode_segment)
            .collect::<Vec<_>>()
            .join("/");
        let full = if encoded.is_empty() {
            self.base.as_str().to_string()
        } else {
            format!("{}/{}", self.base.as_str().trim_end_matches('/'), encoded)
        };
        Url::parse(&full).map_err(|e| Error::Other(format!("URL 拼接失败: {e}")))
    }

    fn req(&self, cfg: &WebDavConfig, method: Method, path: &str) -> reqwest::blocking::RequestBuilder {
        let url = self.url(path).unwrap_or_else(|_| self.base.clone());
        let (u, p) = self.auth(cfg);
        self.client
            .request(method, url)
            .basic_auth(u, Some(p))
            // 关掉 Expect: 100-continue —— 很多 WebDAV 服务端实现有 bug，会导致 1s 延迟或直接失败
            .header(reqwest::header::EXPECT, HeaderValue::from_static(""))
    }

    // ─────────────────── 读 ───────────────────

    /// Depth: 1 列出一层；Depth: 0 只看自身
    pub fn list(&self, cfg: &WebDavConfig, path: &str, depth: u32) -> Result<Vec<DavEntry>> {
        let body = retry(4, || {
            let resp = self
                .req(cfg, Method::from_bytes(b"PROPFIND").unwrap(), path)
                .header("Depth", depth.to_string())
                .header(CONTENT_TYPE, "application/xml; charset=utf-8")
                .body(PROPFIND_BODY)
                .send()?;
            let status = resp.status();
            if !status.is_success() && status.as_u16() != 207 {
                // 404 是合法的"目录不存在"，不该重试
                if status == StatusCode::NOT_FOUND {
                    return Ok(None);
                }
                return Err(Error::Dav { status: status.as_u16(), message: status.to_string() });
            }
            Ok(Some(resp.bytes()?.to_vec()))
        })?;

        let Some(bytes) = body else { return Ok(Vec::new()) };
        parse_propfind(&String::from_utf8_lossy(&bytes))
    }

    pub fn exists(&self, cfg: &WebDavConfig, path: &str) -> Result<bool> {
        Ok(!self.list(cfg, path, 0)?.is_empty())
    }

    pub fn get_bytes(&self, cfg: &WebDavConfig, path: &str) -> Result<Vec<u8>> {
        retry(4, || {
            let resp = self.req(cfg, Method::GET, path).send()?;
            let status = resp.status();
            if !status.is_success() {
                return Err(Error::Dav { status: status.as_u16(), message: status.to_string() });
            }
            let expected = resp
                .headers()
                .get("Content-Length")
                .and_then(|v| v.to_str().ok())
                .and_then(|s| s.parse::<usize>().ok());
            let bytes = resp.bytes()?.to_vec();
            if let Some(n) = expected {
                if bytes.len() != n {
                    return Err(Error::Other(format!("下载不完整: {}/{} 字节", bytes.len(), n)));
                }
            }
            Ok(bytes)
        })
    }

    /// 带 ETag 的条件 GET：未变化时返回 None（省流量，这也是轮询能低成本的原因）
    pub fn get_if_changed(
        &self,
        cfg: &WebDavConfig,
        path: &str,
        etag: Option<&str>,
    ) -> Result<Option<(Vec<u8>, String)>> {
        let mut r = self.req(cfg, Method::GET, path);
        if let Some(e) = etag {
            r = r.header(IF_NONE_MATCH, e);
        }
        let resp = retry(4, || Ok(r.try_clone().unwrap().send()?))?;
        if resp.status() == StatusCode::NOT_MODIFIED {
            return Ok(None);
        }
        let status = resp.status();
        if !status.is_success() {
            if status == StatusCode::NOT_FOUND {
                return Ok(None);
            }
            return Err(Error::Dav { status: status.as_u16(), message: status.to_string() });
        }
        let new_etag = resp
            .headers()
            .get("ETag")
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .trim_matches('"')
            .to_string();
        Ok(Some((resp.bytes()?.to_vec(), new_etag)))
    }

    // ─────────────────── 写 ───────────────────

    pub fn put(&self, cfg: &WebDavConfig, path: &str, body: Vec<u8>) -> Result<()> {
        retry(4, || {
            let resp = self.req(cfg, Method::PUT, path).body(body.clone()).send()?;
            let status = resp.status();
            if !status.is_success() && status.as_u16() != 201 {
                return Err(Error::Dav { status: status.as_u16(), message: status.to_string() });
            }
            Ok(())
        })
    }

    /// 条件写：ETag 不匹配（412）说明别人先改了 → 调用方应重新拉取再重试
    pub fn put_if_match(
        &self,
        cfg: &WebDavConfig,
        path: &str,
        body: Vec<u8>,
        etag: Option<&str>,
    ) -> Result<bool> {
        let mut r = self.req(cfg, Method::PUT, path).body(body);
        if let Some(e) = etag {
            r = r.header(IF_MATCH, format!("\"{e}\""));
        }
        let resp = retry(4, || Ok(r.try_clone().unwrap().send()?))?;
        let status = resp.status();
        if status == StatusCode::PRECONDITION_FAILED {
            return Ok(false);
        }
        if !status.is_success() && status.as_u16() != 201 && status.as_u16() != 204 {
            return Err(Error::Dav { status: status.as_u16(), message: status.to_string() });
        }
        Ok(true)
    }

    /// 原子写入：PUT 临时名 → MOVE 到正式名。
    /// 这是整个同步协议不产生半截文件与并发覆盖的关键。
    pub fn put_atomic(&self, cfg: &WebDavConfig, path: &str, body: Vec<u8>) -> Result<()> {
        let tmp = format!("{path}.tmp-{}", tmp_suffix());
        self.put(cfg, &tmp, body)?;
        match self.rename(cfg, &tmp, path) {
            Ok(()) => Ok(()),
            Err(e) => {
                let _ = self.delete(cfg, &tmp);
                Err(e)
            }
        }
    }

    /// 递归创建目录；405 = 已存在，视为成功
    pub fn mkcol_all(&self, cfg: &WebDavConfig, path: &str) -> Result<()> {
        let parts: Vec<&str> = path.trim_matches('/').split('/').filter(|s| !s.is_empty()).collect();
        let mut cur = String::new();
        for p in parts {
            cur.push('/');
            cur.push_str(p);
            let status = retry(2, || {
                let resp = self
                    .req(cfg, Method::from_bytes(b"MKCOL").unwrap(), &cur)
                    .send()?;
                Ok(resp.status())
            })?;
            if !status.is_success() && status.as_u16() != 405 && status.as_u16() != 301 {
                return Err(Error::Dav { status: status.as_u16(), message: format!("创建目录失败: {cur}") });
            }
        }
        Ok(())
    }

    pub fn delete(&self, cfg: &WebDavConfig, path: &str) -> Result<()> {
        retry(3, || {
            let resp = self.req(cfg, Method::DELETE, path).send()?;
            let status = resp.status();
            if !status.is_success() && status != StatusCode::NOT_FOUND {
                return Err(Error::Dav { status: status.as_u16(), message: status.to_string() });
            }
            Ok(())
        })
    }

    /// MOVE；不支持的服务端自动降级为 COPY + DELETE
    pub fn rename(&self, cfg: &WebDavConfig, from: &str, to: &str) -> Result<()> {
        let dest = self.url(to)?.to_string();
        let resp = retry(3, || {
            Ok(self
                .req(cfg, Method::MOVE, from)
                .header("Destination", &dest)
                .header("Overwrite", "T")
                .send()?)
        })?;
        let status = resp.status();
        if status.is_success() || status.as_u16() == 204 {
            return Ok(());
        }
        if status.as_u16() == 405 || status.as_u16() == 501 {
            // 降级路径
            self.copy(cfg, from, to)?;
            return self.delete(cfg, from);
        }
        Err(Error::Dav { status: status.as_u16(), message: format!("MOVE {from} -> {to} 失败") })
    }

    pub fn copy(&self, cfg: &WebDavConfig, from: &str, to: &str) -> Result<()> {
        let dest = self.url(to)?.to_string();
        let resp = retry(3, || {
            Ok(self
                .req(cfg, Method::from_bytes(b"COPY").unwrap(), from)
                .header("Destination", &dest)
                .header("Overwrite", "T")
                .send()?)
        })?;
        let status = resp.status();
        if status.is_success() || status.as_u16() == 204 {
            return Ok(());
        }
        Err(Error::Dav { status: status.as_u16(), message: format!("COPY {from} -> {to} 失败") })
    }
}

// ─────────────────────── 207 Multi-Status 解析 ───────────────────────

fn parse_propfind(xml: &str) -> Result<Vec<DavEntry>> {
    let doc = roxmltree::Document::parse(xml)?;
    let mut out = Vec::new();
    for resp in doc.descendants().filter(|n| n.is_element() && n.tag_name().name() == "response") {
        let href = resp
            .children()
            .find(|c| c.is_element() && c.tag_name().name() == "href")
            .and_then(|h| h.text())
            .unwrap_or("")
            .to_string();

        let mut is_dir = false;
        let mut size = None;
        let mut etag = None;
        let mut last_modified = None;
        let mut content_type = None;

        for propstat in resp.children().filter(|c| c.is_element() && c.tag_name().name() == "propstat") {
            let ok = propstat
                .children()
                .find(|c| c.is_element() && c.tag_name().name() == "status")
                .and_then(|s| s.text())
                .map(|s| s.contains("200"))
                .unwrap_or(false);
            if !ok {
                continue;
            }
            let Some(prop) = propstat.children().find(|c| c.is_element() && c.tag_name().name() == "prop") else {
                continue;
            };
            for p in prop.children().filter(|c| c.is_element()) {
                match p.tag_name().name() {
                    "getetag" => etag = p.text().map(|s| s.trim_matches('"').to_string()),
                    "getcontentlength" => size = p.text().and_then(|s| s.parse::<u64>().ok()),
                    "getlastmodified" => last_modified = p.text().map(String::from),
                    "getcontenttype" => content_type = p.text().map(String::from),
                    "resourcetype" => {
                        is_dir = p
                            .children()
                            .any(|c| c.is_element() && c.tag_name().name() == "collection");
                    }
                    _ => {}
                }
            }
        }

        let path = decode_path(&href);
        let name = path.rsplit('/').find(|s| !s.is_empty()).unwrap_or("").to_string();
        out.push(DavEntry { path, name, is_dir, size, etag, last_modified, content_type });
    }
    Ok(out)
}

/// href 可能是完整 URL，也可能是服务端改写过的路径。
/// 统一：取 path 部分 → URL 解码。
fn decode_path(href: &str) -> String {
    let p = if let Ok(u) = Url::parse(href) {
        u.path().to_string()
    } else {
        href.to_string()
    };
    percent_decode(&p)
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let (Some(h), Some(l)) = (hex_val(bytes[i + 1]), hex_val(bytes[i + 2])) {
                out.push(h << 4 | l);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hex_val(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'f' => Some(c - b'a' + 10),
        b'A'..=b'F' => Some(c - b'A' + 10),
        _ => None,
    }
}

fn encode_segment(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 2);
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => out.push(b as char),
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

fn tmp_suffix() -> String {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos() as u64)
        .unwrap_or(0);
    format!("{:x}-{:x}", nanos, std::process::id())
}

// ─────────────────────── 退避重试 ───────────────────────

/// 只对"可恢复"的错误重试：5xx、429、423(LOCKED)，以及网络层错误。
/// 4xx（401/403/404/405...）重试没有意义，直接失败。
fn retry<T, F>(attempts: u32, mut f: F) -> Result<T>
where
    F: FnMut() -> Result<T>,
{
    let mut last: Option<Error> = None;
    for i in 0..attempts {
        match f() {
            Ok(v) => return Ok(v),
            Err(e) => {
                let retryable = match &e {
                    Error::Http(he) => he
                        .status()
                        .map(|s| s.is_server_error() || s.as_u16() == 429)
                        .unwrap_or(true),
                    Error::Dav { status, .. } => *status >= 500 || *status == 429 || *status == 423,
                    _ => false,
                };
                if !retryable || i + 1 == attempts {
                    last = Some(e);
                    break;
                }
                let base = 300u64 * 2u64.pow(i);
                let jitter = (Instant::now().elapsed().subsec_nanos() % 250) as u64;
                std::thread::sleep(Duration::from_millis((base + jitter).min(8_000)));
            }
        }
    }
    Err(last.unwrap_or_else(|| Error::Other("重试耗尽".into())))
}

// ─────────────────────── DavFs 接缝（供 sync/transfer 复用） ───────────────────────
//
// transfer 模块的编排逻辑通过 `DavFs` trait 与具体 WebDAV 实现解耦；
// 这里把真实 `WebDavClient` 接进 trait，仅在 `sync` feature 下编译
// （WebDavClient 本身也只在 sync 下存在）。transfer 模块本体不门控，
// 故默认 `cargo test` 也能编译并单测编排逻辑。

#[cfg(feature = "sync")]
impl DavFs for WebDavClient {
    fn mkcol_all(&self, cfg: &WebDavConfig, path: &str) -> Result<()> {
        WebDavClient::mkcol_all(self, cfg, path)
    }

    fn list_names(&self, cfg: &WebDavConfig, dir: &str) -> Result<Vec<String>> {
        let entries = WebDavClient::list(self, cfg, dir, 1)?;
        Ok(entries.into_iter().filter(|e| !e.is_dir).map(|e| e.name).collect())
    }

    fn get_bytes(&self, cfg: &WebDavConfig, path: &str) -> Result<Vec<u8>> {
        WebDavClient::get_bytes(self, cfg, path)
    }

    fn put_atomic(&self, cfg: &WebDavConfig, path: &str, body: Vec<u8>) -> Result<()> {
        WebDavClient::put_atomic(self, cfg, path, body)
    }
}
