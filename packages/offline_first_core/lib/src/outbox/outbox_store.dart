import '../models/sync_operation.dart';
import '../models/sync_status.dart';

/// Persistence contract for the outbox queue.
///
/// Implementations must preserve FIFO order via [sequence] and be safe
/// to call while a sync cycle is running.
abstract class OutboxStore {
  const OutboxStore();

  /// Prepares the store (open DB, run migrations). Called once from
  /// `initialize()`.
  Future<void> open();

  /// Releases resources. No-op for in-memory stores.
  Future<void> close();

  /// Appends [operation] to the queue, assigns [SyncOperation.sequence],
  /// returns the stored operation.
  Future<SyncOperation> enqueue(SyncOperation operation);

  /// Next [limit] operations for [feature] ordered FIFO, filtered by
  /// [statuses] (default: [SyncStatus.pending]).
  ///
  /// No time filtering here — the engine enforces backoff eligibility so
  /// FIFO ordering is preserved (a blocked head blocks the whole feature).
  Future<List<SyncOperation>> nextBatch(
    String feature, {
    int limit = 20,
    List<SyncStatus> statuses = const [SyncStatus.pending],
  });

  /// Operations across all features eligible for retry.
  ///
  /// Returns operations with status [SyncStatus.failed] or
  /// [SyncStatus.dead] that [RetryPolicy] would retry again.
  Future<List<SyncOperation>> retryable({
    int limit = 50,
  });

  /// Updates mutable fields of the operation with [operation.id].
  Future<void> update(SyncOperation operation);

  /// Removes operations with [status] (default: synced) older than [olderThan].
  /// Returns removed count.
  Future<int> purge({
    SyncStatus status = SyncStatus.synced,
    Duration olderThan = const Duration(hours: 24),
  });

  /// Count of operations per status for a feature, or all features when
  /// [feature] is null.
  Future<Map<SyncStatus, int>> counts({String? feature});
}
