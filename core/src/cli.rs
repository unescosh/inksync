//! 无头 CLI 用的小工具：解析 `.env` / 配置文件的 `KEY=VALUE` 内容。
//!
//! 放在 core lib（默认 features，纯 std）而非 example 内，目的是让解析逻辑
//! 能在沙箱/CI 的默认 `cargo test`（不编 `sync`）下被单测覆盖——example 本身
//! 因依赖 `WebDavClient` 被 `sync` feature 门控，无法在默认构建编译。
//!
//! 约定：CLI 读取的配置键为 `INKSYNC_URL` / `INKSYNC_USER` / `INKSYNC_PASS` /
//! `INKSYNC_BOOKS` / `INKSYNC_COVERS` / `INKSYNC_STORE` / `INKSYNC_REMOTE`，
//! 命令行参数优先级高于配置文件（命令行给了就用命令行的）。

use std::collections::HashMap;
use std::path::Path;

use crate::error::Result;

/// 解析一段 `KEY=VALUE` 文本（`.env` 风格）：
/// - 空行与 `#` 开头的注释行忽略；
/// - `KEY=VALUE` 两侧空白被 trim；
/// - 值若被单/双引号包裹则去引号；
/// - 不以 `=` 开头的行忽略（容错，不报错）。
pub fn parse_env(content: &str) -> HashMap<String, String> {
    let mut out = HashMap::new();
    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((k, v)) = line.split_once('=') else {
            continue;
        };
        let key = k.trim().to_string();
        if key.is_empty() {
            continue;
        }
        let mut val = v.trim().to_string();
        if (val.starts_with('"') && val.ends_with('"') && val.len() >= 2)
            || (val.starts_with('\'') && val.ends_with('\'') && val.len() >= 2)
        {
            val = val[1..val.len() - 1].to_string();
        }
        out.insert(key, val);
    }
    out
}

/// 从文件读取并解析配置。文件不存在返回 `Err`。
pub fn load_env_file(path: &Path) -> Result<HashMap<String, String>> {
    let content = std::fs::read_to_string(path)?;
    Ok(parse_env(&content))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_env_basic_and_comments() {
        let txt = "# 注释行\nINKSYNC_URL=https://dav.example.com/inksync/\nINKSYNC_USER=alice\n\nINKSYNC_PASS=secret\n";
        let m = parse_env(txt);
        assert_eq!(m.get("INKSYNC_URL").unwrap(), "https://dav.example.com/inksync/");
        assert_eq!(m.get("INKSYNC_USER").unwrap(), "alice");
        assert_eq!(m.get("INKSYNC_PASS").unwrap(), "secret");
        assert_eq!(m.len(), 3, "注释与空行不应计入");
    }

    #[test]
    fn parse_env_strips_quotes_and_spaces() {
        let m = parse_env("INKSYNC_BOOKS =  /books \nINKSYNC_PASS = \"quoted pass\"\nINKSYNC_REMOTE='covers-root'");
        assert_eq!(m.get("INKSYNC_BOOKS").unwrap(), "/books");
        assert_eq!(m.get("INKSYNC_PASS").unwrap(), "quoted pass");
        assert_eq!(m.get("INKSYNC_REMOTE").unwrap(), "covers-root");
    }

    #[test]
    fn parse_env_ignores_malformed_lines() {
        let m = parse_env("no equals sign\n=novalue\nGOOD=1\n");
        assert_eq!(m.get("GOOD").unwrap(), "1");
        assert_eq!(m.len(), 1, "无=或空键的行应忽略");
    }
}
