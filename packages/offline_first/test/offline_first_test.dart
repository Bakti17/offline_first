import 'package:flutter_test/flutter_test.dart';
import 'package:offline_first/offline_first.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('SqfliteOutboxStore', () {
    late SqfliteOutboxStore store;

    setUp(() async {
      store = SqfliteOutboxStore(dbName: 'test_${DateTime.now().microsecondsSinceEpoch}.db');
      await store.open();
    });

    tearDown(() => store.close());

    test('enqueue assigns auto-increment sequence, FIFO order preserved',
        () async {
      final a = await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 1}));
      final b = await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 2}));
      final c = await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 3}));

      expect(a.sequence, lessThan(b.sequence));
      expect(b.sequence, lessThan(c.sequence));

      final batch = await store.nextBatch('cart');
      expect(batch.map((o) => o.payload['n']).toList(), [1, 2, 3]);
    });

    test('roundtrip preserves all fields', () async {
      final op = await store.enqueue(SyncOperation(
        id: 'op-1',
        feature: 'transactions',
        type: SyncOperationType.update,
        payload: {'__ciphertext': 'abc123'},
        idempotencyKey: 'idem',
        attempts: 3,
        lastError: 'HTTP 500',
        responseBody: '{"e":1}',
        nextAttemptAt: DateTime.utc(2026, 1, 2),
        createdAt: DateTime.utc(2026, 1, 1),
      ));
      await store.update(
          op.copyWith(status: SyncStatus.pending, attempts: 3));

      final batch = await store.nextBatch('transactions');
      final restored = batch.single;
      expect(restored.id, 'op-1');
      expect(restored.type, SyncOperationType.update);
      expect(restored.payload, {'__ciphertext': 'abc123'});
      expect(restored.idempotencyKey, 'idem');
      expect(restored.attempts, 3);
      expect(restored.lastError, 'HTTP 500');
      expect(restored.responseBody, '{"e":1}');
      expect(restored.nextAttemptAt, DateTime.utc(2026, 1, 2));
      expect(restored.createdAt, DateTime.utc(2026, 1, 1));
    });

    test('nextBatch filters status and feature with limit', () async {
      await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 1}));
      final other = await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 2}));
      await store.enqueue(
          SyncOperation.create(feature: 'wishlist', payload: {'n': 3}));

      await store.update(
          other.copyWith(status: SyncStatus.synced));

      final pending = await store.nextBatch('cart');
      expect(pending, hasLength(1));
      expect(pending.single.payload['n'], 1);

      final synced = await store.nextBatch('cart',
          statuses: [SyncStatus.synced]);
      expect(synced.single.id, other.id);

      expect(await store.nextBatch('wishlist'), hasLength(1));
      expect(await store.nextBatch('missing'), isEmpty);

      final limited = await store.nextBatch('cart',
          statuses: [SyncStatus.pending, SyncStatus.synced], limit: 1);
      expect(limited, hasLength(1));
    });

    test('counts grouped by status per feature', () async {
      final op = await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 1}));
      await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 2}));
      await store.enqueue(
          SyncOperation.create(feature: 'wishlist', payload: {'n': 3}));
      await store.update(op.copyWith(status: SyncStatus.failed));

      final cartCounts = await store.counts(feature: 'cart');
      expect(cartCounts[SyncStatus.failed], 1);
      expect(cartCounts[SyncStatus.pending], 1);

      final all = await store.counts();
      expect(all[SyncStatus.pending], 2);
    });

    test('purge removes synced older than cutoff', () async {
      final old = await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 1}));
      await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 2}));
      await store.update(old.copyWith(
        status: SyncStatus.synced,
        createdAt:
            DateTime.now().toUtc().subtract(const Duration(hours: 2)),
      ));

      final removed = await store.purge(olderThan: const Duration(hours: 1));
      expect(removed, 1);
      expect(await store.counts(feature: 'cart'), {
        SyncStatus.pending: 1,
      });
    });

    test('retryable returns failed and dead', () async {
      final failed = await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 1}));
      final dead = await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 2}));
      await store.update(failed.copyWith(status: SyncStatus.failed));
      await store.update(dead.copyWith(status: SyncStatus.dead));

      final retryable = await store.retryable();
      expect(retryable, hasLength(2));
    });
  });

  // FlutterSecurePayloadCipher and ConnectivityPlusAdapter need platform
  // channels (secure storage, connectivity) — cover them in integration
  // tests on device/emulator, not unit tests.
}
