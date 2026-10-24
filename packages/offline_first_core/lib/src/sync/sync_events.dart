import '../models/sync_operation.dart';
import '../models/sync_status.dart';

/// Emitted after every meaningful engine state change for a feature.
class SyncStatusEvent {
  const SyncStatusEvent({
    required this.feature,
    required this.counts,
    required this.phase,
    this.operation,
  });

  final String feature;

  /// Queue counts by status for the feature at emit time.
  final Map<SyncStatus, int> counts;

  final SyncPhase phase;

  /// Operation the phase refers to, when applicable.
  final SyncOperation? operation;

  @override
  String toString() =>
      'SyncStatusEvent($feature, ${phase.name}, pending: ${counts[SyncStatus.pending]})';
}

enum SyncPhase {
  /// Operation accepted into the outbox.
  enqueued,

  /// Drain cycle for the feature started.
  cycleStarted,

  /// Operation acknowledged by the API.
  opSynced,

  /// Operation failed terminally (4xx) or conflict dropped.
  opFailed,

  /// Operation scheduled for retry after backoff.
  opRetry,

  /// Operation exceeded max attempts — dead-lettered.
  opDead,

  /// Drain cycle finished; queue empty or blocked on backoff.
  cycleEnded,
}
