use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::error::{Error, Result};

/// 混合逻辑时钟（Hybrid Logical Clock）。
///
/// 为什么不用墙上时钟：三台设备的系统时间可能差好几分钟，NTP 也不保证同步，
/// 用时间戳做 LWW 会出现"新修改被旧修改覆盖"。
/// 为什么不用纯 Lamport/向量时钟：向量时钟无法按字典序排序，
/// 而我们希望 **文件名排序 = 时间排序**，这样 WebDAV 一次 PROPFIND 就能拿到时序。
///
/// 编码：`{wall_ms:013X}-{counter:04X}-{node:8}`
///   例：`0000018A5F3C1A0-0003-7f3a2b91`
///   13 位十六进制毫秒 ≈ 可用到公元 10889 年；定长 → 字典序即全序。
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Hlc {
    pub wall_ms: u64,
    pub counter: u16,
    /// 设备 ID（8 位 hex），仅用于打破平局
    pub node: String,
}

impl Hlc {
    pub fn new(wall_ms: u64, counter: u16, node: &str) -> Self {
        Self { wall_ms, counter, node: node.to_string() }
    }

    pub fn zero(node: &str) -> Self {
        Self::new(0, 0, node)
    }

    pub fn encode(&self) -> String {
        format!("{:013X}-{:04X}-{}", self.wall_ms, self.counter, self.node)
    }

    pub fn parse(s: &str) -> Result<Self> {
        let parts: Vec<&str> = s.split('-').collect();
        if parts.len() != 3 {
            return Err(Error::BadHlc(s.to_string()));
        }
        let wall_ms = u64::from_str_radix(parts[0], 16).map_err(|_| Error::BadHlc(s.to_string()))?;
        let counter = u16::from_str_radix(parts[1], 16).map_err(|_| Error::BadHlc(s.to_string()))?;
        Ok(Self::new(wall_ms, counter, parts[2]))
    }
}

/// 进程内唯一的时钟源。所有写操作必须先 `tick()` 拿到 HLC 再落库。
pub struct HlcClock {
    node: String,
    last: Mutex<Hlc>,
    /// 允许的最大时钟回拨/漂移告警阈值
    drift_warn_ms: u64,
}

impl HlcClock {
    pub fn new(node: &str) -> Self {
        let node = if node.len() >= 8 { node[..8].to_string() } else { format!("{node:0>8}") };
        Self {
            last: Mutex::new(Hlc::zero(&node)),
            node,
            drift_warn_ms: 60_000,
        }
    }

    pub fn node(&self) -> &str {
        &self.node
    }

    /// 本地事件发生：生成一个新的 HLC
    pub fn tick(&self) -> Hlc {
        let now = now_ms();
        let mut last = self.last.lock().unwrap();
        let wall = last.wall_ms.max(now);
        let counter = if wall == last.wall_ms { last.counter + 1 } else { 0 };
        *last = Hlc::new(wall, counter, &self.node);
        last.clone()
    }

    /// 收到远端 HLC：把自己的时钟推到能"容纳"它的位置。
    /// 返回值可直接作为后续本地事件的基准。
    pub fn observe(&self, remote: &Hlc) -> Hlc {
        let now = now_ms();
        let mut last = self.last.lock().unwrap();
        let wall = last.wall_ms.max(remote.wall_ms).max(now);
        let counter = match (wall == last.wall_ms, wall == remote.wall_ms) {
            (true, true) => last.counter.max(remote.counter) + 1,
            (true, false) => last.counter + 1,
            (false, true) => remote.counter + 1,
            (false, false) => 0,
        };
        *last = Hlc::new(wall, counter, &self.node);
        last.clone()
    }

    /// 当前时钟与系统时间偏差过大时返回提示文案（UI 展示"系统时间可能不准"）
    pub fn drift_warning(&self) -> Option<String> {
        let last = self.last.lock().unwrap();
        let now = now_ms();
        let diff = now.abs_diff(last.wall_ms);
        if diff > self.drift_warn_ms {
            Some(format!("本端系统时间与同步时钟相差 {} 秒，请校准系统时间", diff / 1000))
        } else {
            None
        }
    }
}

pub fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_is_fixed_width_and_sortable() {
        let a = Hlc::new(1, 0, "aaaaaaaa");
        let b = Hlc::new(2, 0, "aaaaaaaa");
        let c = Hlc::new(1, 1, "aaaaaaaa");
        assert_eq!(a.encode().len(), 13 + 1 + 4 + 1 + 8);
        assert!(a.encode() < c.encode());
        assert!(c.encode() < b.encode());
        assert_eq!(Hlc::parse(&b.encode()).unwrap(), b);
    }

    #[test]
    fn tick_monotonic() {
        let clock = HlcClock::new("devA");
        let a = clock.tick();
        let b = clock.tick();
        let c = clock.tick();
        assert!(a <= b && b <= c);
        assert!(a.encode() < c.encode());
    }

    #[test]
    fn observe_advances_past_remote() {
        let a = HlcClock::new("devA");
        let b = HlcClock::new("devB");
        let ra = a.tick();
        b.observe(&ra);
        let rb = b.tick();
        assert!(rb > ra);
    }

    #[test]
    fn concurrent_same_millis_ordered_by_counter_then_node() {
        // 同一毫秒内两端各自 tick，靠 counter 推进；观测后用 node 打破平局
        let a = HlcClock::new("devA");
        let b = HlcClock::new("devB");
        let ra = a.tick();
        let rb = b.observe(&ra);
        let ra2 = a.observe(&rb);
        assert!(ra2 > rb);
    }
}
