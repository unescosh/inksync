import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:xml/xml.dart';

/// WebDAV 客户端（Dart 侧实现）。
///
/// 为什么同步传输放在 Dart 而不是 Rust：
///  · 需要把文件传输进度实时反馈到 UI（Rust 侧跨 FFI 回调很别扭）；
///  · 需要能被用户取消；
///  · 需要和系统代理 / 证书存储协同。
/// Rust 侧另有一份等价实现（`core/src/sync/webdav.rs`），
/// 供命令行工具与「UOS 非 x86 架构 → Qt 降级 UI」复用同一套协议逻辑。
///
/// 踩坑清单（每一条都对应下面的代码）：
///  1. 路径必须**逐段** percent-encode，中文书名/空格会 400 或直接 404；
///  2. PROPFIND 必须带 `Depth`，否则某些服务端返回空列表；
///  3. `Destination` 头必须是**绝对 URL**；
///  4. 关掉 `Expect: 100-continue`（很多网关实现有 bug）；
///  5. 不支持 MOVE 的服务端自动降级 COPY + DELETE；
///  6. 写文件一律「PUT 临时名 → MOVE 正式名」，避免半截文件与并发覆盖。
class WebDavConfig {
  const WebDavConfig({
    required this.baseUrl,
    required this.username,
    required this.password,
    this.acceptInvalidCerts = false,
    this.pinnedCertSha256,
  });

  final String baseUrl;
  final String username;
  final String password;

  /// 内网群晖/自签证书场景
  final bool acceptInvalidCerts;

  /// 证书指纹固定（比"信任一切"安全得多，推荐内网使用）
  final String? pinnedCertSha256;
}

class DavEntry {
  DavEntry({
    required this.path,
    required this.name,
    required this.isDir,
    this.size,
    this.etag,
    this.lastModified,
    this.contentType,
  });

  /// 相对 baseUrl 的路径（已 URL 解码）
  final String path;
  final String name;
  final bool isDir;
  final int? size;
  final String? etag;
  final String? lastModified;
  final String? contentType;

  @override
  String toString() => 'DavEntry($path, dir=$isDir, size=$size)';
}

/// 条件 GET 的结果：未变化时 [changed] 为 false（对应 HTTP 304）
class DavGetResult {
  DavGetResult({required this.bytes, required this.etag});

  final Uint8List bytes;
  final String? etag;
  bool get changed => true;
}

class WebDavException implements Exception {
  WebDavException(this.status, this.message);

  final int status;
  final String message;

  bool get isNotFound => status == 404;
  bool get isPreconditionFailed => status == 412;
  bool get isConflict => status == 409;
  bool get isLocked => status == 423;

  @override
  String toString() => 'WebDAV $status: $message';
}

class WebDavClient {
  WebDavClient(this.config) {
    _dio = Dio(
      BaseOptions(
        baseUrl: config.baseUrl,
        connectTimeout: const Duration(seconds: 20),
        receiveTimeout: const Duration(seconds: 180),
        sendTimeout: const Duration(seconds: 180),
        // 让 4xx/5xx 走我们的错误处理，而不是直接抛
        validateStatus: (s) => s != null && s >= 200 && s < 300,
        headers: <String, dynamic>{
          'User-Agent': 'inksync/1.0',
          // 关掉 Expect: 100-continue
          'Expect': '',
        },
      ),
    );

    if (config.username.isNotEmpty) {
      final basic = base64Encode(utf8.encode('${config.username}:${config.password}'));
      _dio.options.headers['Authorization'] = 'Basic $basic';
    }
  }

  final WebDavConfig config;
  late final Dio _dio;
  final math.Random _rng = math.Random.secure();

  static const String _propfindBody = '''<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:">
  <d:prop>
    <d:getetag/>
    <d:getlastmodified/>
    <d:getcontentlength/>
    <d:getcontenttype/>
    <d:resourcetype/>
  </d:prop>
</d:propfind>''';

  // ─────────────── URL 构造 ───────────────

  String _url(String path) {
    final segs = path
        .split('/')
        .where((s) => s.isNotEmpty)
        .map(Uri.encodeComponent)
        .join('/');
    final base = config.baseUrl.endsWith('/')
        ? config.baseUrl.substring(0, config.baseUrl.length - 1)
        : config.baseUrl;
    return segs.isEmpty ? '$base/' : '$base/$segs';
  }

  // ─────────────── 读 ───────────────

  /// Depth 0 = 只看自身；1 = 列一层
  Future<List<DavEntry>> propfind(String path, {int depth = 1}) async {
    final resp = await _do(
      () => _dio.request<String>(
        _url(path),
        options: Options(
          method: 'PROPFIND',
          headers: <String, dynamic>{'Depth': '$depth', 'Content-Type': 'application/xml'},
          responseType: ResponseType.plain,
          validateStatus: (s) => s != null && (s >= 200 && s < 300 || s == 207 || s == 404),
        ),
        data: _propfindBody,
      ),
      accept: const {207, 404},
    );
    if (resp.statusCode == 404) return const [];
    return _parseMultiStatus(resp.data ?? '');
  }

  Future<bool> exists(String path) async {
    final r = await propfind(path, depth: 0);
    return r.isNotEmpty;
  }

  Future<Uint8List> getBytes(String path, {void Function(int, int)? onProgress}) async {
    final resp = await _do(
      () => _dio.get<List<int>>(
        _url(path),
        options: Options(responseType: ResponseType.bytes),
        onReceiveProgress: onProgress,
      ),
    );
    return Uint8List.fromList(resp.data ?? const []);
  }

  /// 条件 GET。这是"低成本轮询"的关键：manifest 没变时服务端只回 304（约 200 字节）。
  Future<DavGetResult?> getIfChanged(String path, String? etag) async {
    final headers = <String, dynamic>{};
    if (etag != null && etag.isNotEmpty) headers['If-None-Match'] = '"$etag"';
    final resp = await _do(
      () => _dio.get<List<int>>(
        _url(path),
        options: Options(
          responseType: ResponseType.bytes,
          headers: headers,
          validateStatus: (s) => s != null && (s == 200 || s == 204 || s == 304 || s == 404),
        ),
      ),
      accept: const {200, 204, 304, 404},
    );
    if (resp.statusCode == 304) return null;
    if (resp.statusCode == 404) return null; // 首次同步：远端还没有 manifest，等同空（与 propfind 的 404 处理一致）
    final newEtag = resp.headers.value('etag')?.replaceAll('"', '');
    return DavGetResult(bytes: Uint8List.fromList(resp.data ?? const []), etag: newEtag);
  }

  // ─────────────── 写 ───────────────

  Future<void> put(
    String path,
    List<int> body, {
    void Function(int, int)? onProgress,
  }) async {
    await _do(
      () => _dio.put<List<int>>(
        _url(path),
        data: body,
        options: Options(
          headers: <String, dynamic>{'Content-Type': 'application/octet-stream'},
          validateStatus: (s) => s != null && (s == 200 || s == 201 || s == 204),
        ),
        onSendProgress: onProgress,
      ),
      accept: const {200, 201, 204},
    );
  }

  /// 带 ETag 的条件写。返回 false = 412（别人先改了），调用方应重新拉取后重试。
  Future<bool> putIfMatch(String path, List<int> body, String? etag) async {
    final headers = <String, dynamic>{'Content-Type': 'application/json'};
    if (etag != null && etag.isNotEmpty) headers['If-Match'] = '"$etag"';
    final resp = await _do(
      () => _dio.put<List<int>>(
        _url(path),
        data: body,
        options: Options(
          headers: headers,
          validateStatus: (s) =>
              s != null && (s == 200 || s == 201 || s == 204 || s == 412),
        ),
      ),
      accept: const {200, 201, 204, 412},
    );
    return resp.statusCode != 412;
  }

  /// 原子写入：PUT 临时名 → MOVE 正式名。
  /// 同步协议里**所有**写入都走这里，这是不产生半截文件、不被并发覆盖的根本保证。
  Future<void> putAtomic(
    String path,
    List<int> body, {
    void Function(int, int)? onProgress,
  }) async {
    final tmp = '$path.tmp-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}-${_rng.nextInt(1 << 20)}';
    await put(tmp, body, onProgress: onProgress);
    try {
      await move(tmp, path);
    } catch (e) {
      await deleteQuietly(tmp);
      rethrow;
    }
  }

  /// 递归创建目录。405 = 已存在，视为成功。
  Future<void> mkcolAll(String path) async {
    final segs = path.split('/').where((s) => s.isNotEmpty).toList();
    final buf = StringBuffer();
    for (final s in segs) {
      buf.write('/$s');
      final code = await _do(
        () => _dio.request<String>(
          _url(buf.toString()),
          options: Options(
            method: 'MKCOL',
            validateStatus: (c) => c != null && (c == 200 || c == 201 || c == 405 || c == 301),
          ),
        ),
        accept: const {200, 201, 405, 301},
      ).then((r) => r.statusCode ?? 0);
      if (code != 200 && code != 201 && code != 405 && code != 301) {
        throw WebDavException(code, '创建目录失败: ${buf.toString()}');
      }
    }
  }

  Future<void> delete(String path) => deleteQuietly(path);

  Future<void> deleteQuietly(String path) async {
    try {
      await _do(
        () => _dio.delete<String>(
          _url(path),
          options: Options(validateStatus: (s) => s != null && (s == 200 || s == 204 || s == 404)),
        ),
        accept: const {200, 204, 404},
      );
    } on WebDavException catch (e) {
      if (!e.isNotFound) rethrow;
    }
  }

  /// MOVE；405/501 说明服务端不支持 → 降级 COPY + DELETE
  Future<void> move(String from, String to) async {
    final dest = _url(to);
    final resp = await _do(
      () => _dio.request<String>(
        _url(from),
        options: Options(
          method: 'MOVE',
          headers: <String, dynamic>{'Destination': dest, 'Overwrite': 'T'},
          validateStatus: (s) => s != null && (s == 200 || s == 201 || s == 204 || s == 405 || s == 501),
        ),
      ),
      accept: const {200, 201, 204, 405, 501},
    );
    final code = resp.statusCode ?? 0;
    if (code == 405 || code == 501) {
      await _copy(from, to);
      await delete(from);
    }
  }

  Future<void> _copy(String from, String to) async {
    await _do(
      () => _dio.request<String>(
        _url(from),
        options: Options(
          method: 'COPY',
          headers: <String, dynamic>{'Destination': _url(to), 'Overwrite': 'T'},
          validateStatus: (s) => s != null && (s == 200 || s == 201 || s == 204),
        ),
      ),
      accept: const {200, 201, 204},
    );
  }

  // ─────────────── 207 Multi-Status 解析 ───────────────

  List<DavEntry> _parseMultiStatus(String xml) {
    if (xml.trim().isEmpty) return const [];
    final doc = XmlDocument.parse(xml);
    final out = <DavEntry>[];

    for (final resp in doc.findAllElements('d:response')) {
      final href = _childText(resp, 'd:href') ?? '';
      var isDir = false;
      int? size;
      String? etag;
      String? lastModified;
      String? contentType;

      for (final ps in resp.findElements('d:propstat')) {
        final status = _childText(ps, 'd:status') ?? '';
        if (!status.contains('200')) continue;
        for (final prop in ps.findElements('d:prop')) {
          for (final child in prop.children.whereType<XmlElement>()) {
            switch (child.name.local) {
              case 'getetag':
                etag = child.innerText.replaceAll('"', '');
              case 'getcontentlength':
                size = int.tryParse(child.innerText);
              case 'getlastmodified':
                lastModified = child.innerText;
              case 'getcontenttype':
                contentType = child.innerText;
              case 'resourcetype':
                isDir = child.children
                    .whereType<XmlElement>()
                    .any((e) => e.name.local == 'collection');
            }
          }
        }
      }

      // href 可能是完整 URL（各服务端实现不一），统一取 path 部分
      final decoded = _decodePath(href);
      final name = decoded.split('/').where((s) => s.isNotEmpty).lastOrNullSafe;
      out.add(
        DavEntry(
          path: decoded,
          name: name,
          isDir: isDir,
          size: size,
          etag: etag,
          lastModified: lastModified,
          contentType: contentType,
        ),
      );
    }
    return out;
  }

  static String? _childText(XmlElement el, String name) {
    final matches = el.findElements(name);
    if (matches.isEmpty) return null;
    return matches.first.innerText;
  }

  static String _decodePath(String href) {
    String p = href;
    final uri = Uri.tryParse(href);
    if (uri != null && uri.hasScheme) p = uri.path;
    return Uri.decodeComponent(p);
  }

  // ─────────────── 退避重试 ───────────────

  /// 只对"可恢复"错误重试：网络层异常、5xx、429、423(LOCKED)。
  /// 4xx（401/403/404/405...）重试没有意义，直接抛出。
  Future<Response<T>> _do<T>(
    Future<Response<T>> Function() f, {
    Set<int> accept = const {},
    int attempts = 4,
  }) async {
    Object? lastError;
    for (var i = 0; i < attempts; i++) {
      try {
        return await f();
      } on DioException catch (e) {
        final status = e.response?.statusCode ?? 0;
        final ok = accept.contains(status);
        if (ok) {
          // 即使是非 2xx，只要是我们显式接受的码，也把它当"成功响应"返回
          final resp = e.response;
          if (resp != null) return resp as Response<T>;
        }
        final retryable =
            e.type == DioExceptionType.connectionTimeout ||
            e.type == DioExceptionType.receiveTimeout ||
            e.type == DioExceptionType.sendTimeout ||
            e.type == DioExceptionType.connectionError ||
            e.type == DioExceptionType.unknown ||
            status >= 500 ||
            status == 429 ||
            status == 423;
        if (!retryable || i == attempts - 1) {
          lastError = WebDavException(status, e.message ?? e.type.name);
          break;
        }
        final delayMs = (300 * math.pow(2, i)).toInt() + _rng.nextInt(250);
        await Future<void>.delayed(Duration(milliseconds: delayMs.clamp(0, 8000)));
        lastError = e;
      }
    }
    if (lastError is WebDavException) throw lastError;
    throw WebDavException(0, lastError?.toString() ?? '请求失败');
  }
}

extension _LastOrNull on Iterable<String> {
  String? get lastOrNullSafe => isEmpty ? null : last;
}
