import '../models/sync_operation.dart';
import '../models/sync_status.dart';
import 'outbox_store.dart';

/// In-memory [OutboxStore]. Tests, examples, and non-persistent use.
class MemoryOutboxStore extends OutboxStore {
  final List<SyncOperation> _ops = [];
  int _sequence = 0;

  @override
  Future<void> open() async {}

  @override
  Future<void> close() async {}

  @override
  Future<SyncOperation> enqueue(SyncOperation operation) async {
    final stored = operation.copyWith(sequence: _sequence++);
    _ops.add(stored);
    return stored;
  }

  @override
  Future<List<SyncOperation>> nextBatch(
    String feature, {
    int limit = 20,
    List<SyncStatus> statuses = const [SyncStatus.pending],
  }) async {
    final ops = _ops
        .where((o) => o.feature == feature && statuses.contains(o.status))
        .toList()
      ..sort((a, b) => a.sequence.compareTo(b.sequence));
    return ops.take(limit).toList();
  }

  @override
  Future<List<SyncOperation>> retryable({int limit = 50}) async {
    final failed = _ops
        .where((o) =>
            o.status == SyncStatus.failed || o.status == SyncStatus.dead)
        .toList()
      ..sort((a, b) => a.sequence.compareTo(b.sequence));
    return failed.take(limit).toList();
  }

  @override
  Future<void> update(SyncOperation operation) async {
    final index = _ops.indexWhere((o) => o.id == operation.id);
    if (index == -1) return;
    _ops[index] = operation;
  }

  @override
  Future<int> purge({
    SyncStatus status = SyncStatus.synced,
    Duration olderThan = const Duration(hours: 24),
  }) async {
    final cutoff = DateTime.now().toUtc().subtract(olderThan);
    final before = _ops.length;
    _ops.removeWhere((o) => o.status == status && o.createdAt.isBefore(cutoff));
    return before - _ops.length;
  }

  @override
  Future<Map<SyncStatus, int>> counts({String? feature}) async {
    final counts = <SyncStatus, int>{};
    for (final o in _ops) {
      if (feature != null && o.feature != feature) continue;
      counts[o.status] = (counts[o.status] ?? 0) + 1;
    }
    return counts;
  }
}
