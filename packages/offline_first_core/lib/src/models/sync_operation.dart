import 'sync_status.dart';

/// A single queued write in the outbox.
///
/// Operations are drained FIFO per feature, ordered by [sequence].
class SyncOperation {
  SyncOperation({
    required this.id,
    required this.feature,
    required this.type,
    required this.payload,
    DateTime? createdAt,
    this.idempotencyKey,
    this.status = SyncStatus.pending,
    this.attempts = 0,
    this.lastError,
    this.responseBody,
    this.nextAttemptAt,
    int? sequence,
  })  : createdAt = createdAt ?? DateTime.now().toUtc(),
        sequence = sequence ?? -1;

  /// Creates a [SyncOperation.type.create] operation.
  factory SyncOperation.create({
    required String feature,
    required Map<String, Object?> payload,
    String? idempotencyKey,
  }) =>
      SyncOperation(
        id: defaultIdGenerator(),
        feature: feature,
        type: SyncOperationType.create,
        payload: payload,
        idempotencyKey: idempotencyKey,
      );

  /// Creates a [SyncOperation.type.update] operation.
  factory SyncOperation.update({
    required String feature,
    required Map<String, Object?> payload,
    String? idempotencyKey,
  }) =>
      SyncOperation(
        id: defaultIdGenerator(),
        feature: feature,
        type: SyncOperationType.update,
        payload: payload,
        idempotencyKey: idempotencyKey,
      );

  /// Creates a [SyncOperation.type.delete] operation.
  factory SyncOperation.delete({
    required String feature,
    required Map<String, Object?> payload,
    String? idempotencyKey,
  }) =>
      SyncOperation(
        id: defaultIdGenerator(),
        feature: feature,
        type: SyncOperationType.delete,
        payload: payload,
        idempotencyKey: idempotencyKey,
      );

  /// Injectable clock/id source for tests.
  static String Function() defaultIdGenerator = _defaultId;

  static String _defaultId() {
    final now = DateTime.now().toUtc().microsecondsSinceEpoch;
    final rand = DateTime.now().toUtc().microsecondsSinceEpoch.remainder(1000);
    return '$now-$rand';
  }

  /// Unique operation id. Also used as the `Idempotency-Key` header when
  /// [idempotencyKey] is not set.
  final String id;

  /// Feature namespace, e.g. `cart`, `transactions`. Must match a
  /// [FeatureConfig] name.
  final String feature;

  final SyncOperationType type;

  /// Arbitrary JSON-encodable payload.
  final Map<String, Object?> payload;

  /// Optional explicit idempotency key sent as `Idempotency-Key` header.
  final String? idempotencyKey;

  final SyncStatus status;

  /// Number of send attempts made.
  final int attempts;

  /// Last error message, if any.
  final String? lastError;

  /// Raw response body of the last attempt, if any.
  final String? responseBody;

  /// Earliest time the next send attempt may run. Set by the engine after
  /// a retryable failure using [RetryPolicy.delayFor]. Null = eligible now.
  final DateTime? nextAttemptAt;

  final DateTime createdAt;

  /// Monotonic enqueue order within a feature. Assigned by the store.
  final int sequence;

  SyncOperation copyWith({
    String? id,
    String? feature,
    SyncOperationType? type,
    Map<String, Object?>? payload,
    String? idempotencyKey,
    SyncStatus? status,
    int? attempts,
    String? lastError,
    String? responseBody,
    DateTime? nextAttemptAt,
    DateTime? createdAt,
    int? sequence,
  }) =>
      SyncOperation(
        id: id ?? this.id,
        feature: feature ?? this.feature,
        type: type ?? this.type,
        payload: payload ?? this.payload,
        idempotencyKey: idempotencyKey ?? this.idempotencyKey,
        status: status ?? this.status,
        attempts: attempts ?? this.attempts,
        lastError: lastError ?? this.lastError,
        responseBody: responseBody ?? this.responseBody,
        nextAttemptAt: nextAttemptAt ?? this.nextAttemptAt,
        createdAt: createdAt ?? this.createdAt,
        sequence: sequence ?? this.sequence,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'feature': feature,
        'type': type.name,
        'payload': payload,
        'idempotencyKey': idempotencyKey,
        'status': status.name,
        'attempts': attempts,
        'lastError': lastError,
        'responseBody': responseBody,
        'nextAttemptAt': nextAttemptAt?.toIso8601String(),
        'createdAt': createdAt.toIso8601String(),
        'sequence': sequence,
      };

  static SyncOperation fromJson(Map<String, Object?> json) => SyncOperation(
        id: json['id']! as String,
        feature: json['feature']! as String,
        type: SyncOperationType.values.byName(json['type']! as String),
        payload: (json['payload']! as Map).cast<String, Object?>(),
        idempotencyKey: json['idempotencyKey'] as String?,
        status: SyncStatus.values
            .byName(json['status']! as String),
        attempts: json['attempts'] as int? ?? 0,
        lastError: json['lastError'] as String?,
        responseBody: json['responseBody'] as String?,
        nextAttemptAt: json['nextAttemptAt'] == null
            ? null
            : DateTime.parse(json['nextAttemptAt']! as String),
        createdAt:
            DateTime.parse(json['createdAt']! as String),
        sequence: json['sequence'] as int? ?? -1,
      );

  @override
  String toString() =>
      'SyncOperation($id, $feature/${type.name}, $status, attempts: $attempts)';
}

enum SyncOperationType { create, update, delete }
