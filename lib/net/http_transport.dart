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

class IoHttpTransport implements HttpTransport {
  IoHttpTransport({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;

  @override
  Future<HttpResponseData> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
  }) async {
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