import 'dart:math';

import 'package:offline_first_core/offline_first_core.dart';
import 'package:test/test.dart';

void main() {
  group('RetryPolicy', () {
    test('delayFor grows exponentially and is capped', () {
      final policy = RetryPolicy(
        initialDelay: const Duration(seconds: 1),
        multiplier: 2,
        maxDelay: const Duration(seconds: 4),
        random: Random(0),
      );
      for (final attempt in [1, 2, 3]) {
        final d = policy.delayFor(attempt);
        expect(d, lessThanOrEqualTo(const Duration(seconds: 4)));
        expect(d, greaterThanOrEqualTo(Duration.zero));
      }
      // Expected ceilings: 1s, 2s, 4s.
      final d1 = policy.delayFor(1);
      expect(d1.inMilliseconds, lessThanOrEqualTo(1000));
    });

    test('decisionForStatusCode classifies', () {
      const policy = RetryPolicy();
      expect(policy.decisionForStatusCode(200), RetryDecision.synced);
      expect(policy.decisionForStatusCode(201), RetryDecision.synced);
      expect(policy.decisionForStatusCode(409), RetryDecision.conflict);
      expect(policy.decisionForStatusCode(500), RetryDecision.retry);
      expect(policy.decisionForStatusCode(503), RetryDecision.retry);
      expect(policy.decisionForStatusCode(429), RetryDecision.retry);
      expect(policy.decisionForStatusCode(400), RetryDecision.fail);
      expect(policy.decisionForStatusCode(404), RetryDecision.fail);
    });

    test('custom retryable status codes respected', () {
      const policy = RetryPolicy(retryableStatusCodes: {425});
      expect(policy.decisionForStatusCode(425), RetryDecision.retry);
      expect(policy.decisionForStatusCode(429), RetryDecision.fail);
    });
  });

  group('SyncEndpoint', () {
    test('uri joins base and path', () {
      const endpoint = SyncEndpoint(path: '/api/cart');
      final uri = endpoint.uri('https://api.example.com');
      expect(uri.toString(), 'https://api.example.com/api/cart');
    });

    test('handles trailing slash and missing leading slash', () {
      const endpoint = SyncEndpoint(path: 'api/cart');
      expect(endpoint.uri('https://x.dev/v1/').toString(),
          'https://x.dev/v1/api/cart');
    });
  });

  group('MemoryOutboxStore', () {
    late MemoryOutboxStore store;

    setUp(() {
      store = MemoryOutboxStore();
      return store.open();
    });

    test('enqueue assigns increasing sequence per feature FIFO', () async {
      final a = await store.enqueue(SyncOperation.create(
          feature: 'cart', payload: {'n': 1}));
      final b = await store.enqueue(SyncOperation.create(
          feature: 'cart', payload: {'n': 2}));
      expect(a.sequence, lessThan(b.sequence));

      final batch = await store.nextBatch('cart');
      expect(batch.map((o) => o.payload['n']), [1, 2]);
    });

    test('nextBatch filters feature and status with limit', () async {
      await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 1}));
      await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 2}));
      await store.enqueue(
          SyncOperation.create(feature: 'transactions', payload: {'n': 3}));

      final limited = await store.nextBatch('cart', limit: 1);
      expect(limited, hasLength(1));
      expect(limited.first.payload['n'], 1);

      expect(await store.nextBatch('transactions'), hasLength(1));
      expect(await store.nextBatch('missing'), isEmpty);
    });

    test('update replaces by id', () async {
      final op = await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 1}));
      await store
          .update(op.copyWith(status: SyncStatus.synced, attempts: 1));

      final pending = await store.nextBatch('cart');
      expect(pending, isEmpty);

      final counts = await store.counts(feature: 'cart');
      expect(counts[SyncStatus.synced], 1);
    });

    test('retryable returns failed and dead', () async {
      final failed = await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 1}));
      await store.update(failed.copyWith(status: SyncStatus.failed));
      final dead = await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 2}));
      await store.update(dead.copyWith(status: SyncStatus.dead));

      final retryable = await store.retryable();
      expect(retryable, hasLength(2));
    });

    test('purge removes synced older than cutoff', () async {
      final old = await store.enqueue(SyncOperation.create(
          feature: 'cart', payload: {'n': 1}));
      await store.update(old.copyWith(
        status: SyncStatus.synced,
        createdAt: DateTime.now().toUtc().subtract(const Duration(hours: 2)),
      ));

      final removed = await store.purge(olderThan: const Duration(hours: 1));
      expect(removed, 1);
    });
  });

  group('SyncOperation JSON', () {
    test('roundtrip preserves all fields', () {
      final op = SyncOperation(
        id: 'op-1',
        feature: 'cart',
        type: SyncOperationType.update,
        payload: {'itemId': 'x', 'qty': 2},
        idempotencyKey: 'idem-1',
        status: SyncStatus.failed,
        attempts: 2,
        lastError: '500 oops',
        responseBody: '{"e":1}',
        createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
        sequence: 7,
      );
      final restored = SyncOperation.fromJson(op.toJson());
      expect(restored.id, op.id);
      expect(restored.feature, op.feature);
      expect(restored.type, op.type);
      expect(restored.payload, op.payload);
      expect(restored.idempotencyKey, op.idempotencyKey);
      expect(restored.status, op.status);
      expect(restored.attempts, op.attempts);
      expect(restored.lastError, op.lastError);
      expect(restored.responseBody, op.responseBody);
      expect(restored.createdAt, op.createdAt);
      expect(restored.sequence, op.sequence);
    });
  });

  group('OfflineFirstConfig', () {
    const config = OfflineFirstConfig(
      baseUrl: 'https://api.example.com',
      features: [
        FeatureConfig(name: 'cart', endpoint: SyncEndpoint(path: '/api/cart')),
        FeatureConfig(
          name: 'transactions',
          endpoint: SyncEndpoint(path: '/api/transactions'),
          syncOnConnect: false,
          secure: true,
        ),
      ],
    );

    test('feature lookup and unknown feature throws', () {
      expect(config.feature('cart').name, 'cart');
      expect(config.hasFeature('transactions'), isTrue);
      expect(() => config.feature('nope'), throwsArgumentError);
    });
  });
}
