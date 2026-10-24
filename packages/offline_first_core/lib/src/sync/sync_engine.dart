import 'dart:async';
import 'dart:convert';

import '../config/feature_config.dart';
import '../config/offline_first_config.dart';
import '../crypto/payload_cipher.dart';
import '../models/sync_operation.dart';
import '../models/sync_result.dart';
import '../models/sync_status.dart';
import '../network/http_adapter.dart';
import '../outbox/outbox_store.dart';
import 'conflict_resolver.dart';
import 'retry_policy.dart';
import 'sync_events.dart';

/// Marker key under which encrypted payloads are stored at rest.
const ciphertextKey = '__ciphertext';

/// Drains the outbox FIFO per feature and sends operations to their
/// feature endpoint.
///
/// One cycle per feature: fetch next eligible batch, send operations one
/// by one preserving order, apply [RetryPolicy] on failure, resolve 409s
/// via [ConflictResolver]. Features can run in parallel — call
/// [syncFeature] concurrently; ordering is only guaranteed within a
/// feature.
class SyncEngine {
  SyncEngine({
    required this.config,
    required this.store,
    required this.http,
    this.cipher,
    this.conflictResolver = const LastWriteWinsResolver(),
    this.retryPolicy = const RetryPolicy(),
    this.clock = defaultClock,
  })  : assert(cipher != null || !_hasSecure(config)),
        _statusController = StreamController.broadcast();

  final OfflineFirstConfig config;
  final OutboxStore store;
  final HttpAdapter http;
  final PayloadCipher? cipher;
  final ConflictResolver conflictResolver;
  final RetryPolicy retryPolicy;

  /// Injectable clock for deterministic backoff tests.
  final DateTime Function() clock;

  final StreamController<SyncStatusEvent> _statusController;

  /// Broadcast stream of engine state changes, per feature.
  Stream<SyncStatusEvent> get statusStream => _statusController.stream;

  /// Operations currently being sent, by feature. An op is skipped when
  /// its feature is already syncing it (guards concurrent cycles).
  final Set<String> _inFlightOpIds = {};

  /// Features with a cycle currently running.
  final Set<String> _activeCycles = {};

  static bool _hasSecure(OfflineFirstConfig c) =>
      c.features.any((f) => f.secure);

  static DateTime defaultClock() => DateTime.now().toUtc();

  /// Emits [SyncPhase.enqueued] for [operation].
  void notifyEnqueued(SyncOperation operation) {
    _emit(operation.feature, SyncPhase.enqueued, operation);
  }

  /// Drains pending operations for a single feature until the queue is
  /// empty or blocked.
  ///
  /// Blocking conditions (FIFO preserved — a blocked head blocks the
  /// feature):
  /// - head op waiting on backoff (`nextAttemptAt` in the future)
  /// - head op failed retryably or terminally — later ops stop until it
  ///   syncs or is dropped
  ///
  /// Concurrent calls for the same feature coalesce into the running
  /// cycle.
  Future<List<SyncResult>> syncFeature(String featureName) async {
    final feature = config.feature(featureName);

    if (_activeCycles.contains(featureName)) return const [];
    _activeCycles.add(featureName);
    try {
      return await _runCycle(feature);
    } finally {
      _activeCycles.remove(featureName);
    }
  }

  Future<List<SyncResult>> _runCycle(FeatureConfig feature) async {
    final results = <SyncResult>[];
    _emit(feature.name, SyncPhase.cycleStarted, null);

    while (true) {
      final batch = await store.nextBatch(feature.name,
          limit: config.batchSize);
      if (batch.isEmpty) break;

      var attemptedAny = false;
      var blocked = false;
      for (final op in batch) {
        if (_inFlightOpIds.contains(op.id)) continue;
        if (op.nextAttemptAt != null &&
            op.nextAttemptAt!.isAfter(clock())) {
          blocked = true;
          break;
        }

        _inFlightOpIds.add(op.id);
        try {
          final result = await _send(op, feature);
          results.add(result);
          attemptedAny = true;
          if (result.status != SyncStatus.synced) {
            // Head failed — stop cycle, FIFO holds for remaining ops.
            blocked = true;
            break;
          }
        } finally {
          _inFlightOpIds.remove(op.id);
        }
      }
      if (blocked || !attemptedAny) break;
    }

    _emit(feature.name, SyncPhase.cycleEnded, null);
    return results;
  }

  Future<SyncResult> _send(SyncOperation op, FeatureConfig feature) async {
    var body = await _outboundBody(op, feature);

    final request = HttpRequest(
      method: feature.endpoint.method.name.toUpperCase(),
      url: feature.endpoint.uri(config.baseUrl),
      headers: {
        'content-type': 'application/json',
        'idempotency-key': op.idempotencyKey ?? op.id,
        ...feature.endpoint.headers,
      },
      body: body,
    );

    final HttpResponse response;
    try {
      response = await http.send(request);
    } catch (error) {
      return _handleFailure(op, feature, error.toString(), null);
    }

    final decision = retryPolicy.decisionForStatusCode(response.statusCode);
    switch (decision) {
      case RetryDecision.synced:
        return _handleSynced(op, feature, response);
      case RetryDecision.conflict:
        return _handleConflict(op, feature, response);
      case RetryDecision.retry:
        return _handleFailure(op, feature,
            'HTTP ${response.statusCode}', response.body);
      case RetryDecision.fail:
        return _handleTerminalFailure(op, feature, response);
    }
  }

  Future<SyncResult> _handleSynced(
    SyncOperation op,
    FeatureConfig feature,
    HttpResponse response,
  ) async {
    final synced = op.copyWith(
      status: SyncStatus.synced,
      attempts: op.attempts + 1,
      responseBody: response.body,
      lastError: null,
      nextAttemptAt: null,
    );
    await store.update(synced);
    _emit(feature.name, SyncPhase.opSynced, synced);
    return SyncResult(
      operation: synced,
      status: SyncStatus.synced,
      responseBody: response.body,
      statusCode: response.statusCode,
    );
  }

  Future<SyncResult> _handleConflict(
    SyncOperation op,
    FeatureConfig feature,
    HttpResponse response,
  ) async {
    final keepLocal = await conflictResolver.shouldKeepLocal(
      feature: feature.name,
      payload: op.payload,
      responseBody: response.body,
    );
    if (keepLocal) {
      return _handleSynced(op, feature, response);
    }
    final dropped = op.copyWith(
      status: SyncStatus.failed,
      lastError: 'Conflict 409 — server version wins',
      responseBody: response.body,
      nextAttemptAt: null,
    );
    await store.update(dropped);
    _emit(feature.name, SyncPhase.opFailed, dropped);
    return SyncResult(
      operation: dropped,
      status: SyncStatus.failed,
      error: dropped.lastError,
      responseBody: response.body,
      statusCode: response.statusCode,
    );
  }

  Future<SyncResult> _handleFailure(
    SyncOperation op,
    FeatureConfig feature,
    String error,
    String? responseBody,
  ) async {
    final attempts = op.attempts + 1;
    if (attempts >= retryPolicy.maxAttempts) {
      final dead = op.copyWith(
        status: SyncStatus.dead,
        attempts: attempts,
        lastError: error,
        responseBody: responseBody,
        nextAttemptAt: null,
      );
      await store.update(dead);
      _emit(feature.name, SyncPhase.opDead, dead);
      return SyncResult(
        operation: dead,
        status: SyncStatus.dead,
        error: error,
        responseBody: responseBody,
      );
    }

    final delay = retryPolicy.delayFor(attempts);
    final scheduled = op.copyWith(
      status: SyncStatus.pending,
      attempts: attempts,
      lastError: error,
      responseBody: responseBody,
      nextAttemptAt: clock().add(delay),
    );
    await store.update(scheduled);
    _emit(feature.name, SyncPhase.opRetry, scheduled);
    return SyncResult(
      operation: scheduled,
      status: SyncStatus.pending,
      error: error,
      responseBody: responseBody,
    );
  }

  Future<SyncResult> _handleTerminalFailure(
    SyncOperation op,
    FeatureConfig feature,
    HttpResponse response,
  ) async {
    final failed = op.copyWith(
      status: SyncStatus.failed,
      lastError: 'HTTP ${response.statusCode} — not retryable',
      responseBody: response.body,
      nextAttemptAt: null,
    );
    await store.update(failed);
    _emit(feature.name, SyncPhase.opFailed, failed);
    return SyncResult(
      operation: failed,
      status: SyncStatus.failed,
      error: failed.lastError,
      responseBody: response.body,
      statusCode: response.statusCode,
    );
  }

  void _emit(String feature, SyncPhase phase, SyncOperation? operation) {
    if (!_statusController.hasListener) return;
    // Fire-and-forget: never block the engine on slow listeners.
    store.counts(feature: feature).then((counts) {
      if (_statusController.isClosed) return;
      _statusController.add(SyncStatusEvent(
        feature: feature,
        counts: counts,
        phase: phase,
        operation: operation,
      ));
    });
  }

  /// Builds the outbound body: decrypts at-rest ciphertext back to
  /// plaintext JSON (TLS covers transit). Plain payloads pass through.
  Future<String> _outboundBody(SyncOperation op, FeatureConfig feature) async {
    final ciphertext = op.payload[ciphertextKey];
    if (feature.secure && ciphertext is String && cipher != null) {
      final plaintext =
          await cipher!.decrypt(base64Decode(ciphertext), feature: feature.name);
      return utf8.decode(plaintext);
    }
    return jsonEncode(op.payload);
  }

  /// Stops emitting. In-flight cycles finish naturally.
  Future<void> dispose() async {
    await _statusController.close();
  }
}
