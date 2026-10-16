// 测试用假传输层：记录请求并返回预设响应。
import 'package:danmu_float/net/http_transport.dart';

class FakeTransport implements HttpTransport {
  FakeTransport(this.handler);

  final Future<HttpResponseData> Function(Uri uri, Map<String, String> headers)
      handler;
  final List<Uri> requests = <Uri>[];
  final List<Map<String, String>> requestHeaders = <Map<String, String>>[];

  /// close 调用次数：用于验证「谁 new 谁 close」（#95）——
  /// 注入给别人的传输不该被对方关掉，自建的才该关。
  int closeCount = 0;

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
  void close() {
    closeCount++;
  }
}