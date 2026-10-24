import 'dart:async';
import 'dart:convert';

import 'config/offline_first_config.dart';
import 'crypto/payload_cipher.dart';
import 'models/sync_operation.dart';
import 'models/sync_result.dart';
import 'models/sync_status.dart';
import 'network/connectivity_adapter.dart';
import 'network/http_adapter.dart';
import 'outbox/outbox_store.dart';
import 'sync/conflict_resolver.dart';
import 'sync/retry_policy.dart';
import 'sync/sync_engine.dart';
import 'sync/sync_events.dart';
import 'sync/sync_scheduler.dart';

/// Facade for the offline-first engine.
///
/// Usage: construct with config + injected adapters, call [initialize],
/// then [enqueue] writes locally and let triggers drain the queue —
/// or force with [syncNow] / [syncAll].
class OfflineFirst {
  OfflineFirst({
    required this.config,
    required this.store,
    required this.http,
    this.connectivity,
    this.cipher,
    this.conflictResolver = const LastWriteWinsResolver(),
    this.retryPolicy = const RetryPolicy(),
  }) {
    _checkSecureConfig();
    _engine = SyncEngine(
      config: config,
      store: store,
      http: http,
      cipher: cipher,
      conflictResolver: conflictResolver,
      retryPolicy: retryPolicy,
    );
    _scheduler = SyncScheduler(_engine, connectivity);
  }

  final OfflineFirstConfig config;
  final OutboxStore store;
  final HttpAdapter http;
  final ConnectivityAdapter? connectivity;
  final PayloadCipher? cipher;
  final ConflictResolver conflictResolver;
  final RetryPolicy retryPolicy;

  late final SyncEngine _engine;
  late final SyncScheduler _scheduler;
  bool _initialized = false;

  /// Engine state changes for UI binding.
  Stream<SyncStatusEvent> get statusStream => _engine.statusStream;

  /// Per-feature handle: `offline.forFeature('cart').enqueue(...)`.
  FeatureHandle forFeature(String name) {
    _ensureInitialized();
    config.feature(name); // throws for unknown feature
    return FeatureHandle(this, name);
  }

  /// Opens the store and starts automatic triggers.
  Future<void> initialize() async {
    await store.open();
    await _scheduler.start();
    _initialized = true;
  }

  /// Throws when any feature is `secure` but no cipher was provided —
  /// fail fast at construction, never store plaintext for secure data.
  void _checkSecureConfig() {
    final secureNoCipher =
        config.features.any((f) => f.secure) && cipher == null;
    if (secureNoCipher) {
      throw StateError(
          'Features marked secure require a cipher. '
          'Provide one via OfflineFirst(cipher: ...).');
    }
  }

  void _ensureInitialized() {
    if (!_initialized) {
      throw StateError('Call initialize() before using OfflineFirst.');
    }
  }

  /// Queues [operation] locally. Encrypts before storage for secure
  /// features. Returns the stored operation (with assigned sequence).
  Future<SyncOperation> enqueue(SyncOperation operation) async {
    _ensureInitialized();
    final feature = config.feature(operation.feature);
    var toStore = operation;
    if (feature.secure && cipher != null) {
      final plaintext = utf8.encode(jsonEncode(operation.payload));
      final encrypted = await cipher!.encrypt(plaintext, feature: feature.name);
      toStore = operation.copyWith(
        payload: {
          ciphertextKey: base64Encode(encrypted),
        },
      );
    }
    final stored = await store.enqueue(toStore);
    _engine.notifyEnqueued(stored);
    return stored;
  }

  /// Manual sync of one feature. Waits for the drain cycle to finish.
  Future<List<SyncResult>> syncNow(String featureName) {
    _ensureInitialized();
    config.feature(featureName);
    return _engine.syncFeature(featureName);
  }

  /// Manual sync of every configured feature, in parallel.
  Future<List<SyncResult>> syncAll() async {
    _ensureInitialized();
    final all = await Future.wait(
        config.features.map((f) => _engine.syncFeature(f.name)));
    return all.expand((r) => r).toList();
  }

  /// Queue counts per status for one feature or all features.
  Future<Map<SyncStatus, int>> queueCounts({String? feature}) {
    _ensureInitialized();
    if (feature != null) config.feature(feature);
    return store.counts(feature: feature);
  }

  /// Removes synced operations older than [olderThan].
  Future<int> purgeSynced({
    Duration olderThan = const Duration(hours: 24),
  }) {
    _ensureInitialized();
    return store.purge(olderThan: olderThan);
  }

  /// Requeues failed/dead operations so the next drain retries them.
  ///
  /// With [featureName], only that feature's ops are requeued; [opIds]
  /// targets specific operations. Resets attempts and backoff. Returns
  /// requeued count.
  Future<int> retryFailed({String? featureName, Iterable<String>? opIds}) async {
    _ensureInitialized();
    if (featureName != null) config.feature(featureName);
    final ops = await store.retryable(limit: 1000);
    var requeued = 0;
    for (final op in ops) {
      if (featureName != null && op.feature != featureName) continue;
      if (opIds != null && !opIds.contains(op.id)) continue;
      await store.update(op.copyWith(
        status: SyncStatus.pending,
        attempts: 0,
        lastError: null,
        responseBody: null,
        nextAttemptAt: null,
      ));
      requeued++;
    }
    return requeued;
  }

  /// Stops triggers and releases engine resources. The store stays open.
  Future<void> dispose() async {
    await _scheduler.stop();
    await _engine.dispose();
    _initialized = false;
  }
}

/// Feature-scoped convenience wrapper around [OfflineFirst].
class FeatureHandle {
  FeatureHandle(this._parent, this.name);

  final OfflineFirst _parent;
  final String name;

  Future<SyncOperation> enqueue(SyncOperation operation) =>
      _parent.enqueue(operation);

  Future<SyncOperation> create(Map<String, Object?> payload,
          {String? idempotencyKey}) =>
      _parent.enqueue(SyncOperation.create(
        feature: name,
        payload: payload,
        idempotencyKey: idempotencyKey,
      ));

  Future<SyncOperation> update(Map<String, Object?> payload,
          {String? idempotencyKey}) =>
      _parent.enqueue(SyncOperation.update(
        feature: name,
        payload: payload,
        idempotencyKey: idempotencyKey,
      ));

  Future<SyncOperation> delete(Map<String, Object?> payload,
          {String? idempotencyKey}) =>
      _parent.enqueue(SyncOperation.delete(
        feature: name,
        payload: payload,
        idempotencyKey: idempotencyKey,
      ));

  Future<List<SyncResult>> syncNow() => _parent.syncNow(name);

  Future<Map<SyncStatus, int>> counts() =>
      _parent.queueCounts(feature: name);
}
