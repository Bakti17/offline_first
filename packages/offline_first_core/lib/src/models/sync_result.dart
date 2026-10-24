import 'sync_operation.dart';
import 'sync_status.dart';

/// Result of draining one operation through the sync engine.
class SyncResult {
  const SyncResult({
    required this.operation,
    required this.status,
    this.error,
    this.responseBody,
    this.statusCode,
  });

  final SyncOperation operation;
  final SyncStatus status;

  /// Error message when [status] is [SyncStatus.failed] or [SyncStatus.dead].
  final String? error;

  /// Raw response body of the attempt.
  final String? responseBody;
  final int? statusCode;

  bool get isSuccess => status == SyncStatus.synced;

  @override
  String toString() =>
      'SyncResult(${operation.id}, $status${statusCode != null ? ', $statusCode' : ''})';
}
