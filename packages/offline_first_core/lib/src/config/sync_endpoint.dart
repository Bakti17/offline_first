/// HTTP method used when syncing an operation.
enum SyncMethod { post, put, patch, delete }

/// Per-feature endpoint description.
class SyncEndpoint {
  const SyncEndpoint({
    required this.path,
    this.method = SyncMethod.post,
    this.headers = const {},
  });

  /// Path appended to [OfflineFirstConfig.baseUrl], e.g. `/api/cart`.
  final String path;

  final SyncMethod method;

  /// Extra headers appended to every request for this feature.
  final Map<String, String> headers;

  /// Builds the full URL from [baseUrl].
  Uri uri(String baseUrl) {
    final base = Uri.parse(baseUrl);
    final basePath = base.path.endsWith('/')
        ? base.path.substring(0, base.path.length - 1)
        : base.path;
    final pathPart = path.startsWith('/') ? path : '/$path';
    return base.replace(path: '$basePath$pathPart');
  }
}
