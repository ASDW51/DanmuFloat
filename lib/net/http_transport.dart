// 网络层最小 HTTP 抽象：便于离线注入假响应做单测（真实实现基于 dart:io）。
import 'dart:convert';
import 'dart:io';

class HttpResponseData {
  const HttpResponseData({
    required this.statusCode,
    required this.body,
    this.setCookie = const <String>[],
  });

  final int statusCode;
  final String body;

  /// set-cookie 头列表（dart:io 已按 cookie 逐个拆分，不做二次切分）。
  final List<String> setCookie;
}

abstract class HttpTransport {
  Future<HttpResponseData> get(Uri uri, {Map<String, String> headers});

  void close();
}

/// TCP 建连超时：DNS 挂起 / SYN 无响应时不设这个阈值，请求会一直挂在连接阶段（#76）。
const Duration defaultHttpConnectTimeout = Duration(seconds: 10);

/// 单次请求的读取超时：连上了但服务端不返回响应时的兜底（#76）。
const Duration defaultHttpReadTimeout = Duration(seconds: 10);

class IoHttpTransport implements HttpTransport {
  IoHttpTransport({
    HttpClient? client,
    this.connectTimeout = defaultHttpConnectTimeout,
    this.readTimeout = defaultHttpReadTimeout,
  }) : _client = client ?? HttpClient() {
    // 建连超时由 HttpClient 自身兜底；读取超时由 get() 的 Future.timeout 兜底。
    _client.connectionTimeout = connectTimeout;
  }

  final HttpClient _client;

  /// 建连超时（测试注入更短的值）。
  final Duration connectTimeout;

  /// 读取超时（测试注入更短的值）。
  final Duration readTimeout;

  @override
  Future<HttpResponseData> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
  }) {
    // 整条链路共用一个读取超时：任何一步不返回都不能把调用方永久挂住（#76）。
    // 超时后残留的半开请求由 close() 的 force 关闭兜底。
    return _get(uri, headers).timeout(readTimeout);
  }

  Future<HttpResponseData> _get(
    Uri uri,
    Map<String, String> headers,
  ) async {
    final HttpClientRequest request = await _client.getUrl(uri);
    headers.forEach((String key, String value) => request.headers.set(key, value));
    final HttpClientResponse response = await request.close();
    final String body = await response.transform(utf8.decoder).join();
    return HttpResponseData(
      statusCode: response.statusCode,
      body: body,
      setCookie: response.headers[HttpHeaders.setCookieHeader] ?? const <String>[],
    );
  }

  @override
  void close() => _client.close(force: true);
}