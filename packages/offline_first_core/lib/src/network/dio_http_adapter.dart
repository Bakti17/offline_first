import 'package:dio/dio.dart';

import 'http_adapter.dart';

/// [HttpAdapter] backed by dio.
///
/// Inject a pre-configured [Dio] to reuse interceptors (auth tokens,
/// refresh, logging).
class DioHttpAdapter extends HttpAdapter {
  DioHttpAdapter({Dio? dio})
      : _owned = dio == null,
        dio = dio ?? Dio();

  final bool _owned;
  final Dio dio;

  @override
  Future<HttpResponse> send(HttpRequest request) async {
    final options = RequestOptions(
      path: request.url.toString(),
      method: request.method,
      headers: request.headers,
      contentType: 'application/json',
      sendTimeout: request.connectTimeout,
      receiveTimeout: request.receiveTimeout,
      // Status codes are returned, never thrown — the engine classifies.
      validateStatus: (_) => true,
    );
    options.data = request.body;

    final response = await dio.fetch<Object?>(options);
    return HttpResponse(
      statusCode: response.statusCode ?? 0,
      body: response.data?.toString(),
      headers: response.headers.map.map(
        (k, v) => MapEntry(k, v.isEmpty ? '' : v.first),
      ),
    );
  }

  /// Closes the underlying [Dio] when this adapter created it.
  void dispose() {
    if (_owned) dio.close();
  }
}
