// 测试用假传输层：记录请求并返回预设响应。
import 'package:danmu_float/net/http_transport.dart';

class FakeTransport implements HttpTransport {
  FakeTransport(this.handler);

  final Future<HttpResponseData> Function(Uri uri, Map<String, String> headers)
      handler;
  final List<Uri> requests = <Uri>[];
  final List<Map<String, String>> requestHeaders = <Map<String, String>>[];

  @override
  Future<HttpResponseData> get(
    Uri uri, {
    Map<String, String> headers = const <String, String>{},
  }) {
    requests.add(uri);
    requestHeaders.add(headers);
    return handler(uri, headers);
  }

  @override
  void close() {}
}