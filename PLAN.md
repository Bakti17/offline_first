# offline_first — Architecture Plan

Offline-first Dart packages: apps write to a local outbox queue, a sync engine
drains the queue to per-feature API endpoints when online. Triggers: automatic
(connectivity regained, periodic interval) and manual (`syncNow()`).

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Scope | Pure Dart core + Flutter adapter package | Core reusable server-side/CLI; Flutter-only deps isolated |
| HTTP | dio | Interceptors (auth/token refresh), typed errors |
| Storage | sqflite | Raw SQL, no codegen, mature; outbox rows are generic JSON |
| Sync v1 | Push only | Outbox drain to API; pull/cache layer is a later phase |
| Encryption | `secure` flag per feature, AES-GCM at rest | Sensitive features (payments, PII) encrypted before hitting storage |

## Repo layout

```
packages/
  offline_first_core/          # pure Dart (deps: dio only)
    lib/src/
      config/
        offline_first_config.dart   # baseUrl, default retry policy, feature list
        feature_config.dart         # name, endpoint, syncOnConnect, syncInterval,
                                    # secure (encrypt payload at rest)
        sync_endpoint.dart          # path, method, extra headers
      crypto/
        payload_cipher.dart         # abstract: encrypt(bytes)->bytes, decrypt
      models/
        sync_operation.dart         # id, feature, type, payload, idempotencyKey,
                                    # status, attempts, lastError, sequence, createdAt
        sync_status.dart            # pending / inFlight / synced / failed / dead
        sync_result.dart
      outbox/
        outbox_store.dart           # abstract: enqueue, nextBatch, markStatus, purge
        memory_outbox_store.dart    # in-memory impl (tests, examples)
      network/
        http_adapter.dart           # abstract: send(request) -> Response
        dio_http_adapter.dart       # dio impl (dio is pure Dart — lives here)
        connectivity_adapter.dart   # abstract: Stream<bool> isOnline
      sync/
        sync_engine.dart            # FIFO drain per feature, parallel across features
        sync_scheduler.dart         # on-connect trigger + periodic Timers
        retry_policy.dart           # exponential backoff + jitter, maxAttempts,
                                    # retryable status codes
        conflict_resolver.dart      # pluggable, default last-write-wins (409)
      offline_first_core.dart       # facade: initialize, enqueue, syncNow, syncAll,
                                    # statusStream
  offline_first/               # Flutter package (facade + platform adapters)
    lib/
      offline_first.dart            # re-exports core + Flutter factory
      src/adapters/
        connectivity_plus_adapter.dart   # connectivity_plus impl
        flutter_secure_payload_cipher.dart # AES-GCM, key in flutter_secure_storage
        sqflite_outbox_store.dart   # sqflite impl of OutboxStore
        connectivity_plus_adapter.dart
  example/                     # later: demo Flutter app
```

## Public API (target)

```dart
final offline = OfflineFirst(
  config: OfflineFirstConfig(
    baseUrl: 'https://api.example.com',
    features: [
      FeatureConfig(
        name: 'cart',
        endpoint: SyncEndpoint(path: '/api/cart'),
        syncOnConnect: true,
        syncInterval: Duration(minutes: 5),   // optional periodic
      ),
      FeatureConfig(
        name: 'transactions',
        endpoint: SyncEndpoint(path: '/api/transactions'),
        syncOnConnect: false,                 // manual only
        secure: true,                         // payload encrypted at rest
      ),
    ],
    store: SqfliteOutboxStore(),              // injected
    http: DioHttpAdapter(dio: dioWithAuth),   // injected (auth via interceptor)
    connectivity: ConnectivityPlusAdapter(),  // injected; null = manual-only mode
    cipher: FlutterSecurePayloadCipher(),     // required if any feature is secure
  ),
);
await offline.initialize();

// Write — instant, local, never blocks on network
await offline.forFeature('cart').enqueue(
  SyncOperation.create(payload: {'itemId': 'x', 'qty': 2}),
);

// Manual triggers
await offline.forFeature('transactions').syncNow();
await offline.syncAll();

// UI status
offline.statusStream.listen((s) => ...); // per-feature depth + sync state
```

## Secure data handling

- `FeatureConfig.secure: true` → payload encrypted **at enqueue time**,
  stored as `{'__ciphertext': '<base64>'}`. Engine detects the marker and
  decrypts in memory only at send time (API receives plaintext JSON; TLS
  covers transit). Storage layer never sees plaintext for secure features.
- `PayloadCipher` interface in core; AES-GCM (`package:cryptography`) impl in the
  Flutter package, key generated on first use, stored in
  `flutter_secure_storage` (Keychain / Keystore).
- Cipher applies to payload only — metadata (status, attempts, timestamps)
  stays plaintext for queue inspection.
- Constructor throws if any feature is `secure` but no cipher injected.
- Trade-off: encrypted rows not human-readable in DB debug tools; acceptable —
  dev builds can inject a no-op cipher.

## Sync semantics

- **Ordering**: FIFO per feature by monotonic `sequence`. Features sync in parallel.
- **Auto triggers**: offline→online edge fires `syncAll()` for `syncOnConnect`
  features; per-feature `Timer` for `syncInterval`.
- **Retry**: exponential backoff + jitter, `maxAttempts`, then `dead` (inspectable,
  re-syncable). Retryable: 5xx, 429, network errors.
- **Non-retryable**: 4xx (except 409/429) → `failed` immediately, no retry burn.
- **409** → pluggable `ConflictResolver` (default last-write-wins).
- **Idempotency**: `Idempotency-Key` header from `op.idempotencyKey ?? op.id`.
- **Retention**: synced ops purgeable (configurable keep-window for debugging).

## Milestones

1. `offline_first_core` scaffold: models, config, `OutboxStore`/`HttpAdapter`/
   `ConnectivityAdapter` interfaces, `MemoryOutboxStore`, `DioHttpAdapter`
2. `SyncEngine`: FIFO drain, retry + backoff, dead-letter, status stream
3. `SyncScheduler`: on-connect + periodic triggers; core facade wiring
4. `offline_first` Flutter package: `SqfliteOutboxStore`,
   `ConnectivityPlusAdapter`, facade factory
5. Tests: core unit tests (fake store/http), adapter tests
6. Example app + README + docs

