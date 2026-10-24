import 'dart:async';
import 'dart:convert';

import 'package:offline_first_core/offline_first_core.dart';
import 'package:test/test.dart';

import 'sync_engine_test.dart' show FakeHttp, XorCipher;

class FakeConnectivity extends ConnectivityAdapter {
  FakeConnectivity({this.initiallyOnline = false});

  final _controller = StreamController<bool>.broadcast();
  bool _online = false;
  bool initiallyOnline;

  @override
  Future<bool> isOnline() async => _online;

  @override
  Stream<bool> get onConnectivityChanged => _controller.stream;

  void goOnline() {
    _online = true;
    _controller.add(true);
  }
}

/// Engine tests already cover drain semantics; these cover the facade:
/// lifecycle, encryption-at-rest boundary, triggers.
void main() {
  late MemoryOutboxStore store;

  setUp(() async {
    store = MemoryOutboxStore();
    await store.open();
  });

  OfflineFirst build(OfflineFirst framework) => framework;

  group('OfflineFirst facade', () {
    test('requires initialize before use', () async {
      final offline = build(OfflineFirst(
        config: const OfflineFirstConfig(
          baseUrl: 'https://api.test',
          features: [
            FeatureConfig(name: 'cart', endpoint: SyncEndpoint(path: '/cart')),
          ],
        ),
        store: store,
        http: FakeHttp([HttpResponse(statusCode: 201)]),
      ));

      expect(() => offline.syncNow('cart'), throwsStateError);
      expect(() => offline.forFeature('cart'), throwsStateError);
      await offline.dispose();
    });

    test('secure feature without cipher fails at construction', () {
      expect(
        () => build(OfflineFirst(
          config: const OfflineFirstConfig(
            baseUrl: 'https://api.test',
            features: [
              FeatureConfig(
                name: 'transactions',
                endpoint: SyncEndpoint(path: '/tx'),
                secure: true,
              ),
            ],
          ),
          store: store,
          http: FakeHttp([]),
        )),
        throwsStateError,
      );
    });

    test('enqueue encrypts at rest, send decrypts to plaintext', () async {
      final http = FakeHttp([HttpResponse(statusCode: 201)]);
      final offline = build(OfflineFirst(
        config: const OfflineFirstConfig(
          baseUrl: 'https://api.test',
          features: [
            FeatureConfig(
              name: 'transactions',
              endpoint: SyncEndpoint(path: '/tx'),
              secure: true,
            ),
          ],
        ),
        store: store,
        http: http,
        cipher: const XorCipher(),
      ));
      await offline.initialize();

      final stored = await offline
          .forFeature('transactions')
          .create({'account': 'x', 'amount': 42});

      // At rest: ciphertext marker, no plaintext.
      expect(stored.payload.containsKey(ciphertextKey), isTrue);
      expect(jsonEncode(stored.payload), isNot(contains('account')));

      // Wire: plaintext JSON restored.
      await offline.syncNow('transactions');
      final body = jsonDecode(http.requests.single.body!)
          as Map<String, Object?>;
      expect(body, {'account': 'x', 'amount': 42});

      final counts = await offline.queueCounts(feature: 'transactions');
      expect(counts[SyncStatus.synced], 1);
      await offline.dispose();
    });

    test('plain feature stores payload as-is', () async {
      final http = FakeHttp([HttpResponse(statusCode: 200)]);
      final offline = build(OfflineFirst(
        config: const OfflineFirstConfig(
          baseUrl: 'https://api.test',
          features: [
            FeatureConfig(name: 'cart', endpoint: SyncEndpoint(path: '/cart')),
          ],
        ),
        store: store,
        http: http,
      ));
      await offline.initialize();

      final stored =
          await offline.forFeature('cart').create({'item': 'socks'});
      expect(stored.payload, {'item': 'socks'});

      await offline.syncAll();
      expect(http.requests.single.url.toString(), 'https://api.test/cart');
      await offline.dispose();
    });

    test('syncAll drains every feature', () async {
      final http = FakeHttp([HttpResponse(statusCode: 201)]);
      final offline = build(OfflineFirst(
        config: const OfflineFirstConfig(
          baseUrl: 'https://api.test',
          features: [
            FeatureConfig(name: 'cart', endpoint: SyncEndpoint(path: '/cart')),
            FeatureConfig(name: 'wishlist', endpoint: SyncEndpoint(path: '/wl')),
          ],
        ),
        store: store,
        http: http,
      ));
      await offline.initialize();

      await offline.forFeature('cart').create({'n': 1});
      await offline.forFeature('wishlist').create({'n': 2});
      final results = await offline.syncAll();

      expect(results, hasLength(2));
      expect(results.every((r) => r.isSuccess), isTrue);
      expect(http.requests.map((r) => r.url.path).toSet(),
          {'/cart', '/wl'});
      await offline.dispose();
    });

    test('scheduler fires on offline->online edge', () async {
      final http = FakeHttp([HttpResponse(statusCode: 201)]);
      final connectivity = FakeConnectivity();
      final offline = build(OfflineFirst(
        config: const OfflineFirstConfig(
          baseUrl: 'https://api.test',
          features: [
            FeatureConfig(
              name: 'cart',
              endpoint: SyncEndpoint(path: '/cart'),
              syncOnConnect: true,
            ),
            FeatureConfig(
              name: 'manual',
              endpoint: SyncEndpoint(path: '/manual'),
              syncOnConnect: false,
            ),
          ],
        ),
        store: store,
        http: http,
        connectivity: connectivity,
      ));
      await offline.initialize();

      await offline.forFeature('cart').create({'n': 1});
      await offline.forFeature('manual').create({'n': 2});

      connectivity.goOnline();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      // Only syncOnConnect feature fired.
      expect(http.requests, hasLength(1));
      expect(http.requests.single.url.path, '/cart');

      final manualCounts = await offline.queueCounts(feature: 'manual');
      expect(manualCounts[SyncStatus.pending], 1);
      await offline.dispose();
    });

    test('purgeSynced removes old synced ops', () async {
      final http = FakeHttp([HttpResponse(statusCode: 200)]);
      final offline = build(OfflineFirst(
        config: const OfflineFirstConfig(
          baseUrl: 'https://api.test',
          features: [
            FeatureConfig(name: 'cart', endpoint: SyncEndpoint(path: '/cart')),
          ],
        ),
        store: store,
        http: http,
      ));
      await offline.initialize();

      await offline.forFeature('cart').create({'n': 1});
      await offline.syncNow('cart');

      var removed = await offline.purgeSynced(olderThan: Duration.zero);
      expect(removed, 1);

      removed = await offline.purgeSynced();
      expect(removed, 0);
      await offline.dispose();
    });

    test('retryFailed requeues dead ops, next sync succeeds', () async {
      final http = FakeHttp([HttpResponse(statusCode: 500)]);
      final offline = build(OfflineFirst(
        config: const OfflineFirstConfig(
          baseUrl: 'https://api.test',
          features: [
            FeatureConfig(name: 'cart', endpoint: SyncEndpoint(path: '/cart')),
          ],
        ),
        store: store,
        http: http,
        retryPolicy: const RetryPolicy(maxAttempts: 1),
      ));
      await offline.initialize();

      await offline.forFeature('cart').create({'n': 1});
      final first = await offline.syncNow('cart');
      expect(first.single.status, SyncStatus.dead);

      // Server recovered: requeue and drain.
      http.responses
        ..clear()
        ..add(const HttpResponse(statusCode: 201));
      final requeued = await offline.retryFailed(featureName: 'cart');
      expect(requeued, 1);

      final second = await offline.syncNow('cart');
      expect(second.single.status, SyncStatus.synced);
      expect(second.single.operation.attempts, 1);
      await offline.dispose();
    });
  });
}
