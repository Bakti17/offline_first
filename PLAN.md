# offline_first — Architecture Decision Record

Offline-first Dart packages: apps write to a local outbox queue, a sync engine
drains the queue to per-feature API endpoints when online. Triggers: automatic
(connectivity regained, periodic interval) and manual (`syncNow()`).

## Decisions

| Decision | Choice | Reason |
|---|---|---|
| Scope | Pure Dart core + Flutter adapter package | Core reusable server-side/CLI; Flutter-only deps isolated |
| HTTP | dio | Interceptors (auth/token refresh), typed errors; pure Dart so it stays in core |
| Storage | sqflite | Raw SQL, no codegen, mature; outbox rows are generic JSON |
| Sync v1 | Push only | Outbox drain to API; pull/cache layer is a later phase |
| Encryption | `secure` flag per feature, AES-GCM at rest | Sensitive features (payments, PII) encrypted before hitting storage |
| FIFO guarantee | Store returns pure FIFO; engine enforces backoff/head-of-line blocking | Time-filtering in the store would silently skip blocked heads and send later ops out of order |
| Encryption boundary | Encrypt at enqueue, decrypt at send (marker-based) | Send-time encryption would double-encrypt or leak plaintext to storage |

## Repo layout (as built)

```
packages/
  offline_first_core/                  # pure Dart (deps: dio only)
    lib/
      offline_first_core.dart          # barrel: public API + dio re-export
      src/
        config/
          offline_first_config.dart    # baseUrl, batch size, concurrency, feature lookup
          feature_config.dart          # name, endpoint, syncOnConnect, syncInterval, secure
          sync_endpoint.dart           # path, method, extra headers, URL join
        crypto/
          payload_cipher.dart          # PayloadCipher interface + NoopCipher
        models/
          sync_operation.dart          # id, feature, type, payload, idempotencyKey,
                                       # status, attempts, lastError, nextAttemptAt, sequence
          sync_status.dart             # pending / inFlight / synced / failed / dead
          sync_result.dart
        network/
          http_adapter.dart            # HttpRequest/HttpResponse + HttpAdapter
          dio_http_adapter.dart        # dio impl (validateStatus always true — engine classifies)
          connectivity_adapter.dart    # ConnectivityAdapter + StaticConnectivity
        outbox/
          outbox_store.dart            # enqueue, nextBatch, retryable, update, purge, counts
          memory_outbox_store.dart     # in-memory impl (tests, examples)
        sync/
          sync_engine.dart             # FIFO drain, backoff eligibility, dead-letter,
                                       # ciphertext marker decrypt at send
          sync_scheduler.dart          # on-connect edge + periodic Timers
          retry_policy.dart            # exponential backoff + full jitter, decision classifier
          conflict_resolver.dart       # last-write-wins / server-wins
          sync_events.dart             # SyncStatusEvent + SyncPhase
        offline_first.dart             # facade: initialize, enqueue, syncNow, syncAll,
                                       # retryFailed, purgeSynced, queueCounts, statusStream,
                                       # forFeature -> FeatureHandle
  offline_first/                       # Flutter package (adapters + core re-export)
    lib/
      offline_first.dart               # barrel: exports core + adapters
      src/adapters.dart                # SqfliteOutboxStore, ConnectivityPlusAdapter,
                                       # FlutterSecurePayloadCipher (AES-256-GCM)
    example/                           # demo app (cart auto-sync + manual encrypted transactions)
```

## Public API (final)

```dart
final offline = OfflineFirst(
  config: const OfflineFirstConfig(
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
  ),
  store: SqfliteOutboxStore(),              // injected
  http: DioHttpAdapter(dio: dio),           // injected (auth via interceptor)
  connectivity: ConnectivityPlusAdapter(),  // injected; null = manual-only mode
  cipher: FlutterSecurePayloadCipher(),     // required if any feature is secure
);
await offline.initialize();

// Write — instant, local, never blocks on network
await offline.forFeature('cart').create({'itemId': 'x', 'qty': 2});

// Manual triggers
await offline.forFeature('transactions').syncNow();
await offline.syncAll();

// Dead-letter recovery
await offline.retryFailed(featureName: 'cart');

// UI status
offline.statusStream.listen((s) => ...); // per-feature counts + phase
```

## Secure data handling

- `FeatureConfig.secure: true` → payload encrypted **at enqueue time**,
  stored as `{'__ciphertext': '<base64>'}`. Engine detects the marker and
  decrypts in memory only at send time (API receives plaintext JSON; TLS
  covers transit). Storage layer never sees plaintext for secure features.
- `PayloadCipher` interface in core; AES-256-GCM (`package:cryptography`) impl in
  the Flutter package, wire format `nonce(12) | ciphertext | mac(16)`, key
  generated on first use, stored in `flutter_secure_storage`
  (Keychain / Keystore).
- Cipher applies to payload only — metadata (status, attempts, timestamps)
  stays plaintext for queue inspection.
- Constructor throws if any feature is `secure` but no cipher injected.
- Trade-off: encrypted rows not human-readable in DB debug tools; acceptable —
  dev builds can inject a no-op cipher.

## Sync semantics

- **Ordering**: FIFO per feature by monotonic `sequence`. Features sync in parallel.
- **Blocking**: a failed head (retryable, terminal, or backoff-waiting) blocks
  later ops of the same feature until it syncs or is dropped — no out-of-order sends.
- **Auto triggers**: offline→online edge fires sync for `syncOnConnect`
  features; per-feature `Timer` for `syncInterval`.
- **Retry**: exponential backoff + full jitter, `maxAttempts`, then `dead`
  (inspectable, `retryFailed()` requeues). Retryable: 5xx, 429, 408, network errors.
- **Non-retryable**: other 4xx → `failed` immediately, no retry burn.
- **409** → pluggable `ConflictResolver` (default last-write-wins; server-wins drops op).
- **Idempotency**: `Idempotency-Key` header from `op.idempotencyKey ?? op.id`.
- **Bookkeeping**: `attempts` counts every send including the successful one.
- **Retention**: `purgeSynced()` removes synced ops older than a keep-window.

## Status

All v1 milestones shipped — core engine, scheduler, facade, Flutter adapters,
example app, CI, docs. Deferred: pull/cache layer (server → local),
bidirectional sync, on-device integration tests for cipher/connectivity
adapters (platform channels).
