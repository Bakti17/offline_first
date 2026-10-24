/// Resolves 409 conflicts during sync. Default: last-write-wins — the
/// queued operation wins and the request is re-sent with force semantics
/// left to the API; the result is recorded as synced.
///
/// Replace for merge logic, server-wins, or user prompts.
abstract class ConflictResolver {
  const ConflictResolver();

  /// Returns true when the queued operation should be retried/forced after
  /// a 409 (last-write-wins), false when the server version wins (drop).
  Future<bool> shouldKeepLocal({
    required String feature,
    required Map<String, Object?> payload,
    required String? responseBody,
  });
}

class LastWriteWinsResolver extends ConflictResolver {
  const LastWriteWinsResolver();

  @override
  Future<bool> shouldKeepLocal({
    required String feature,
    required Map<String, Object?> payload,
    required String? responseBody,
  }) async =>
      true;
}

class ServerWinsResolver extends ConflictResolver {
  const ServerWinsResolver();

  @override
  Future<bool> shouldKeepLocal({
    required String feature,
    required Map<String, Object?> payload,
    required String? responseBody,
  }) async =>
      false;
}
