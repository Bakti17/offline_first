/// Wire-level HTTP request the sync engine hands to an [HttpAdapter].
class HttpRequest {
  const HttpRequest({
    required this.method,
    required this.url,
    this.headers = const {},
    this.body,
    this.connectTimeout = const Duration(seconds: 15),
    this.receiveTimeout = const Duration(seconds: 30),
  });

  /// One of GET/POST/PUT/PATCH/DELETE.
  final String method;
  final Uri url;
  final Map<String, String> headers;

  /// UTF-8 JSON encoded body, or null for no body.
  final String? body;

  final Duration connectTimeout;
  final Duration receiveTimeout;
}

/// Wire-level HTTP response from an [HttpAdapter].
class HttpResponse {
  const HttpResponse({
    required this.statusCode,
    this.body,
    this.headers = const {},
  });

  final int statusCode;
  final String? body;
  final Map<String, String> headers;
}

/// Pluggable HTTP transport for the sync engine.
///
/// Default: [DioHttpAdapter]. Swap for mocks in tests or a custom client
/// with your own auth plumbing.
abstract class HttpAdapter {
  const HttpAdapter();

  /// Sends [request]. Throws for transport failures (timeouts, socket
  /// errors) — the engine treats any thrown error as retryable.
  ///
  /// HTTP status codes are returned, not thrown. The engine classifies
  /// 2xx as success, 5xx/429 as retryable, other 4xx as terminal failure.
  Future<HttpResponse> send(HttpRequest request);
}
