import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:offline_first_core/offline_first_core.dart';
import 'package:test/test.dart';

/// Records requests, returns scripted responses.
class FakeHttp extends HttpAdapter {
  FakeHttp(this.responses, {this.onError});

  /// Response per request, consumed in order. Last one repeats.
  final List<HttpResponse> responses;
  final Object? Function()? onError;
  final List<HttpRequest> requests = [];
  int _cursor = 0;

  @override
  Future<HttpResponse> send(HttpRequest request) async {
    requests.add(request);
    final error = onError?.call();
    if (error != null) throw error;
    if (_cursor >= responses.length - 1) {
      return responses[responses.length - 1];
    }
    return responses[_cursor++];
  }
}

/// Cipher that flips bytes, so roundtrip proves encrypt/decrypt happened.
class XorCipher extends PayloadCipher {
  const XorCipher();

  @override
  Future<List<int>> encrypt(List<int> plaintext, {required String feature}) =>
      Future.value(plaintext.map((b) => b ^ 0xFF).toList());

  @override
  Future<List<int>> decrypt(List<int> ciphertext, {required String feature}) =>
      Future.value(ciphertext.map((b) => b ^ 0xFF).toList());
}

SyncEngine buildEngine({
  required OutboxStore store,
  required HttpAdapter http,
  List<FeatureConfig> features = const [
    FeatureConfig(name: 'cart', endpoint: SyncEndpoint(path: '/api/cart')),
  ],
  RetryPolicy retryPolicy = const RetryPolicy(),
  ConflictResolver conflictResolver = const LastWriteWinsResolver(),
  PayloadCipher? cipher,
  DateTime Function()? clock,
}) {
  return SyncEngine(
    config: OfflineFirstConfig(baseUrl: 'https://api.test', features: features),
    store: store,
    http: http,
    cipher: cipher,
    conflictResolver: conflictResolver,
    retryPolicy: retryPolicy,
    clock: clock ?? FixedClock().call,
  );
}

FixedClock fixedClock([DateTime? start]) => FixedClock(start);

class FixedClock {
  FixedClock([DateTime? start]) : now = start ?? DateTime.utc(2026, 1, 1);

  DateTime now;

  DateTime call() => now;
}

void main() {
  group('SyncEngine', () {
    late MemoryOutboxStore store;

    setUp(() async {
      store = MemoryOutboxStore();
      await store.open();
    });

    test('drains FIFO and marks synced', () async {
      final http = FakeHttp([HttpResponse(statusCode: 201)]);
      final engine = buildEngine(store: store, http: http);
      await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 1}));
      await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 2}));

      final results = await engine.syncFeature('cart');

      expect(results, hasLength(2));
      expect(results.every((r) => r.isSuccess), isTrue);
      expect(http.requests[0].url.toString(), 'https://api.test/api/cart');
      expect(http.requests[0].headers['idempotency-key'],
          results[0].operation.id);
      expect(jsonDecode(http.requests[0].body!), {'n': 1});
      expect(jsonDecode(http.requests[1].body!), {'n': 2});

      final counts = await store.counts(feature: 'cart');
      expect(counts[SyncStatus.synced], 2);
      await engine.dispose();
    });

    test('retryable 500 schedules backoff then succeeds', () async {
      final clock = fixedClock();
      final http = FakeHttp(
          [HttpResponse(statusCode: 500), HttpResponse(statusCode: 201)]);
      final engine = buildEngine(
        store: store,
        http: http,
        retryPolicy: RetryPolicy(
          maxAttempts: 3,
          initialDelay: const Duration(minutes: 1),
          random: Random(0),
        ),
        clock: clock.call,
      );
      await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 1}));

      // Cycle 1: fails, schedules retry.
      final r1 = await engine.syncFeature('cart');
      expect(r1.single.status, SyncStatus.pending);
      expect(r1.single.operation.attempts, 1);
      expect(r1.single.operation.nextAttemptAt, isNotNull);

      // Backoff not elapsed: nothing attempted, FIFO preserved.
      final r2 = await engine.syncFeature('cart');
      expect(r2, isEmpty);
      expect(http.requests, hasLength(1));

      // Advance past backoff: succeeds.
      clock.now = clock.now.add(const Duration(minutes: 2));
      final r3 = await engine.syncFeature('cart');
      expect(r3.single.status, SyncStatus.synced);
      expect(http.requests, hasLength(2));
      await engine.dispose();
    });

    test('exhausted attempts go dead', () async {
      final clock = fixedClock();
      final http = FakeHttp([HttpResponse(statusCode: 500)]);
      final engine = buildEngine(
        store: store,
        http: http,
        retryPolicy: const RetryPolicy(maxAttempts: 2),
        clock: clock.call,
      );
      await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 1}));

      await engine.syncFeature('cart'); // attempt 1 -> pending + backoff
      clock.now = clock.now.add(const Duration(minutes: 10));
      final r2 = await engine.syncFeature('cart'); // attempt 2 -> dead
      expect(r2.single.status, SyncStatus.dead);
      expect(r2.single.operation.attempts, 2);

      final counts = await store.counts(feature: 'cart');
      expect(counts[SyncStatus.dead], 1);
      await engine.dispose();
    });

    test('4xx fails terminally without retry', () async {
      final http = FakeHttp([HttpResponse(statusCode: 422)]);
      final engine = buildEngine(store: store, http: http);
      await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 1}));

      final results = await engine.syncFeature('cart');
      expect(results.single.status, SyncStatus.failed);
      expect(results.single.operation.attempts, 0);
      expect(http.requests, hasLength(1));

      final counts = await store.counts(feature: 'cart');
      expect(counts[SyncStatus.failed], 1);
      await engine.dispose();
    });

    test('failed head-of-line blocks later ops within cycle', () async {
      final http = FakeHttp([HttpResponse(statusCode: 422)]);
      final engine = buildEngine(store: store, http: http);
      await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 1}));
      await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 2}));

      final results = await engine.syncFeature('cart');
      expect(results, hasLength(1)); // only first attempted
      expect(http.requests, hasLength(1));

      final counts = await store.counts(feature: 'cart');
      expect(counts[SyncStatus.failed], 1);
      expect(counts[SyncStatus.pending], 1);
      await engine.dispose();
    });

    test('transport error treated as retryable', () async {
      final http = FakeHttp([HttpResponse(statusCode: 201)], onError: () => Exception('socket'));
      final engine = buildEngine(
        store: store,
        http: http,
        clock: fixedClock().call,
      );
      await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 1}));

      final results = await engine.syncFeature('cart');
      expect(results.single.status, SyncStatus.pending);
      expect(results.single.operation.lastError, contains('socket'));
      await engine.dispose();
    });

    test('409 with server-wins drops operation', () async {
      final http = FakeHttp([HttpResponse(statusCode: 409, body: '{}')]);
      final engine = buildEngine(
        store: store,
        http: http,
        conflictResolver: const ServerWinsResolver(),
      );
      await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 1}));

      final results = await engine.syncFeature('cart');
      expect(results.single.status, SyncStatus.failed);
      expect(results.single.error, contains('409'));

      final counts = await store.counts(feature: 'cart');
      expect(counts[SyncStatus.failed], 1);
      await engine.dispose();
    });

    test('409 with last-write-wins marks synced', () async {
      final http = FakeHttp([HttpResponse(statusCode: 409)]);
      final engine = buildEngine(store: store, http: http);
      await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 1}));

      final results = await engine.syncFeature('cart');
      expect(results.single.status, SyncStatus.synced);
      await engine.dispose();
    });

    test('secure feature decrypts ciphertext marker for send', () async {
      final http = FakeHttp([HttpResponse(statusCode: 201)]);
      final engine = buildEngine(
        store: store,
        http: http,
        features: [
          FeatureConfig(
            name: 'cart',
            endpoint: SyncEndpoint(path: '/api/cart'),
            secure: true,
          ),
        ],
        cipher: const XorCipher(),
      );

      // What the facade stores: payload replaced by ciphertext marker.
      final plaintext = utf8.encode(jsonEncode({'secret': 'data'}));
      final ciphertext = await const XorCipher()
          .encrypt(plaintext, feature: 'cart');
      await store.enqueue(SyncOperation(
        id: 'op-enc',
        feature: 'cart',
        type: SyncOperationType.create,
        payload: {ciphertextKey: base64Encode(ciphertext)},
      ));

      await engine.syncFeature('cart');

      // Wire: plaintext JSON restored.
      final body = jsonDecode(http.requests.single.body!)
          as Map<String, Object?>;
      expect(body, {'secret': 'data'});

      final counts = await store.counts(feature: 'cart');
      expect(counts[SyncStatus.synced], 1);
      await engine.dispose();
    });

    test('plain payload on secure feature passes through unmarked', () async {
      // Ops enqueued directly (bypassing the facade) with no marker are
      // sent as-is — the marker is the encryption discriminator.
      final http = FakeHttp([HttpResponse(statusCode: 201)]);
      final engine = buildEngine(
        store: store,
        http: http,
        features: [
          FeatureConfig(
            name: 'cart',
            endpoint: SyncEndpoint(path: '/api/cart'),
            secure: true,
          ),
        ],
        cipher: const XorCipher(),
      );
      await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 1}));

      await engine.syncFeature('cart');
      expect(jsonDecode(http.requests.single.body!), {'n': 1});
      await engine.dispose();
    });

    test('secure feature without cipher throws at construction', () {
      expect(
        () => SyncEngine(
          config: const OfflineFirstConfig(
            baseUrl: 'https://api.test',
            features: [
              FeatureConfig(
                name: 'cart',
                endpoint: SyncEndpoint(path: '/c'),
                secure: true,
              ),
            ],
          ),
          store: store,
          http: FakeHttp([]),
        ),
        throwsA(isA<Error>()),
      );
    });

    test('status stream emits phases', () async {
      final http = FakeHttp([HttpResponse(statusCode: 201)]);
      final engine = buildEngine(store: store, http: http);
      final phases = <SyncPhase>[];
      final sub = engine.statusStream.listen((e) => phases.add(e.phase));
      await Future<void>.delayed(Duration.zero); // let listener attach

      await store.enqueue(
          SyncOperation.create(feature: 'cart', payload: {'n': 1}));
      engine.notifyEnqueued(
          (await store.nextBatch('cart')).first);
      await engine.syncFeature('cart');
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(phases, contains(SyncPhase.enqueued));
      expect(phases, contains(SyncPhase.cycleStarted));
      expect(phases, contains(SyncPhase.opSynced));
      expect(phases, contains(SyncPhase.cycleEnded));
      await sub.cancel();
      await engine.dispose();
    });

    test('unknown feature throws', () {
      final engine = buildEngine(store: store, http: FakeHttp([]));
      expect(() => engine.syncFeature('nope'), throwsArgumentError);
      // dispose via microtask, engine unused further
      unawaited(engine.dispose());
    });
  });
}

class Unawaited {}

void unawaited(Future<void> f) {}
