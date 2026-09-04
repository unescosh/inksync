/// 混合逻辑时钟（Hybrid Logical Clock）—— 与 Rust 侧 `core/src/sync/hlc.rs` **完全同构**。
///
/// 为什么不用墙上时钟：三台设备系统时间可能差好几分钟，NTP 也不保证同步，
/// 用时间戳做 LWW 会出现"新修改被旧修改覆盖"。
///
/// 编码 `{wallMs:013X}-{counter:04X}-{node:8}` 的关键性质是**定长**，
/// 因此 **字符串字典序 == 全局时间序**。
/// 这让我们可以直接用「文件名排序」拿到变更时序，WebDAV 一次 PROPFIND 就够了。
library;

class Hlc implements Comparable<Hlc> {
  final int wallMs;
  final int counter;
  final String node; // 设备 ID（8 位 hex），仅用于打破平局

  const Hlc({required this.wallMs, required this.counter, required this.node});

  static final Hlc zero = Hlc(wallMs: 0, counter: 0, node: '00000000');

  String encode() =>
      '${wallMs.toRadixString(16).toUpperCase().padLeft(13, '0')}-'
      '${counter.toRadixString(16).toUpperCase().padLeft(4, '0')}-$node';

  static Hlc parse(String s) {
    final parts = s.split('-');
    if (parts.length != 3) {
      throw FormatException('非法 HLC: $s');
    }
    return Hlc(
      wallMs: int.parse(parts[0], radix: 16),
      counter: int.parse(parts[1], radix: 16),
      node: parts[2],
    );
  }

  @override
  int compareTo(Hlc other) {
    final a = wallMs.compareTo(other.wallMs);
    if (a != 0) return a;
    final b = counter.compareTo(other.counter);
    if (b != 0) return b;
    return node.compareTo(other.node);
  }

  @override
  bool operator ==(Object other) =>
      other is Hlc && wallMs == other.wallMs && counter == other.counter && node == other.node;

  @override
  int get hashCode => Object.hash(wallMs, counter, node);

  @override
  String toString() => encode();
}

/// 进程内唯一时钟源。所有写库操作必须先 [tick] 拿到 HLC 再落库。
class HlcClock {
  HlcClock(this.node) {
    assert(node.length == 8, 'node 必须是 8 位十六进制设备 ID');
    _last = Hlc(wallMs: 0, counter: 0, node: node);
  }

  final String node;
  late Hlc _last;

  /// 本地事件发生
  Hlc tick() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final wall = _last.wallMs > now ? _last.wallMs : now;
    final counter = wall == _last.wallMs ? _last.counter + 1 : 0;
    _last = Hlc(wallMs: wall, counter: counter, node: node);
    return _last;
  }

  /// 收到远端 HLC：把本地时钟推到能容纳它的位置
  Hlc observe(Hlc remote) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final wall = [_last.wallMs, remote.wallMs, now].reduce((a, b) => a > b ? a : b);
    int counter;
    if (wall == _last.wallMs && wall == remote.wallMs) {
      counter = (_last.counter > remote.counter ? _last.counter : remote.counter) + 1;
    } else if (wall == _last.wallMs) {
      counter = _last.counter + 1;
    } else if (wall == remote.wallMs) {
      counter = remote.counter + 1;
    } else {
      counter = 0;
    }
    _last = Hlc(wallMs: wall, counter: counter, node: node);
    return _last;
  }

  /// 系统时间与同步时钟偏差超过 60s → 提示校准（否则 HLC 会被远端长时间牵着走）
  String? driftWarning() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final diff = (now - _last.wallMs).abs();
    if (diff > 60000) {
      return '本端系统时间与同步时钟相差 ${diff ~/ 1000} 秒，建议校准系统时间';
    }
    return null;
  }
}
