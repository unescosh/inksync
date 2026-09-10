// 真·WebDAV 集成测试（docs/03 §5）。
//
// 三个"虚拟节点" = 三个 WebDavClient 实例，全部指向同一个共享目录（由 wsgidav 提供服务端）。
// 节点并发读写、各自改名，最后任一节点拉取目录清单，断言所有人都看到同一份最终状态
// （跨节点可见 + 无丢文件 = 最终一致）。这是"三端同步"协议层的最小可用验证。
//
// 服务端约定（与 .github/workflows/build.yml 的 `test` 作业一致）：
//   · wsgidav 监听 http://127.0.0.1:8080/（匿名访问）
//   · 共享根目录由 WEBDAV_ROOT 指定（默认 inksync-ci）
// 本地手动跑：
//   pip install wsgidav && (wsgidav --root /tmp/wsgidav --auth anonymous --port 8080 --host 0.0.0.0 &)
//   WEBDAV_BASE_URL=http://127.0.0.1:8080/ flutter test test/webdav_live_test.dart

import 'dart:convert';
import 'dart:io';

import 'package:inksync/sync/webdav_client.dart';
import 'package:test/test.dart';

final String _baseUrl =
    Platform.environment['WEBDAV_BASE_URL'] ?? 'http://127.0.0.1:8080/';
final String _root = Platform.environment['WEBDAV_ROOT'] ?? 'inksync-ci';
final String _user = Platform.environment['WEBDAV_USER'] ?? '';
final String _pass = Platform.environment['WEBDAV_PASS'] ?? '';

late final String session; // 每次运行的隔离子目录，避免多作业互相污染
late final List<WebDavClient> nodes;

WebDavClient _node() => WebDavClient(
      WebDavConfig(
        baseUrl: '$_baseUrl$_root/',
        username: _user,
        password: _pass,
      ),
    );

void main() {
  setUpAll(() {
    session = 'run-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    nodes = List.generate(3, (_) => _node());
  });

  test('三个节点并发写入各自 manifest，最终互相可见且内容一致', () async {
    await nodes[0].mkcolAll(session); // 确保共享目录存在（幂等）

    final contents = <String>[
      for (var i = 0; i < 3; i++)
        jsonEncode({'node': i, 'ts': DateTime.now().toIso8601String()}),
    ];

    // 并发写入：三个节点同时对同一共享目录写自己的文件（PUT 临时名 → MOVE 正式名）
    await Future.wait([
      for (var i = 0; i < 3; i++)
        nodes[i].putAtomic('$session/node-$i.json', utf8.encode(contents[i])),
    ]);

    // 节点 0 拉取目录清单，应看到全部 3 个文件
    final listing = await nodes[0].propfind(session, depth: 1);
    final names = listing.where((e) => !e.isDir).map((e) => e.name).toList();
    expect(
      names,
      containsAll(['node-0.json', 'node-1.json', 'node-2.json']),
      reason: '节点 0 应能看到三个节点写入的全部文件',
    );

    // 跨节点可见性：每个节点都能读到"其它"节点的文件且内容一致（= 最终一致）
    for (var i = 0; i < 3; i++) {
      final reader = nodes[(i + 1) % 3]; // 由另一个节点来读
      final bytes = await reader.getBytes('$session/node-$i.json');
      expect(utf8.decode(bytes), equals(contents[i]),
          reason: '节点 $i 写入的内容应被节点 ${(i + 1) % 3} 读到');
    }
  });

  test('并发 MOVE 重命名不丢文件', () async {
    await Future.wait([
      for (var i = 0; i < 3; i++)
        nodes[i].putAtomic('$session/mv-$i.json', utf8.encode('mv-$i')),
    ]);

    // 各节点并发把自己的文件改名（MOVE；服务端不支持时客户端自动降级 COPY+DELETE）
    await Future.wait([
      for (var i = 0; i < 3; i++)
        nodes[i].move('$session/mv-$i.json', '$session/renamed-$i.json'),
    ]);

    final listing = await nodes[0].propfind(session, depth: 1);
    final names = listing.where((e) => !e.isDir).map((e) => e.name).toList();
    expect(names, containsAll(['renamed-0.json', 'renamed-1.json', 'renamed-2.json']));
    expect(names, isNot(contains('mv-0.json')),
        reason: '改名后旧名不应残留');
  });

  test('条件写 putIfMatch：正确 etag 成功落盘', () async {
    const bodyV1 = 'v1';
    await nodes[0].putAtomic('$session/cond.json', utf8.encode(bodyV1));

    final first = await nodes[0].getIfChanged('$session/cond.json', null);
    expect(first, isNotNull);

    // 带正确 etag 的条件写应成功，且内容更新
    final ok = await nodes[0].putIfMatch(
      '$session/cond.json',
      utf8.encode('v2'),
      first!.etag,
    );
    expect(ok, isTrue);
    final after = utf8.decode(await nodes[0].getBytes('$session/cond.json'));
    expect(after, equals('v2'));

    // 错误 etag 走 412 分支（部分服务端不强制 If-Match，此处仅冒烟验证不抛异常）
    await nodes[0].putIfMatch('$session/cond.json', utf8.encode('v3'), 'deadbeef');
  });

  tearDownAll(() async {
    // 清理本次会话写入的文件（目录本身留空，无害）
    for (var i = 0; i < 3; i++) {
      await nodes[i].deleteQuietly('$session/node-$i.json');
      await nodes[i].deleteQuietly('$session/mv-$i.json');
      await nodes[i].deleteQuietly('$session/renamed-$i.json');
    }
    await nodes[0].deleteQuietly('$session/cond.json');
  });
}
