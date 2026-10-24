# offline_first

Offline-first packages for Dart & Flutter. Apps write to a local outbox
queue and keep working without internet; a sync engine drains the queue to
per-feature API endpoints when connectivity returns. Auto triggers
(connectivity regained, periodic interval) and manual triggers
(`syncNow` / `syncAll`).

## Packages

| Package | Description |
|---|---|
| [`packages/offline_first_core`](packages/offline_first_core) | Pure Dart engine: outbox, per-feature config, sync, retry, encryption interfaces |
| [`packages/offline_first`](packages/offline_first) | Flutter adapters: sqflite store, connectivity_plus, AES-GCM cipher + secure key storage |
| [`packages/offline_first/example`](packages/offline_first/example) | Demo app |

See [PLAN.md](PLAN.md) for the architecture decision record.

## The 30-second version

```dart
final offline = OfflineFirst(
  config: const OfflineFirstConfig(
    baseUrl: 'https://api.example.com',
    features: [
      FeatureConfig(
        name: 'cart',                        // auto-sync feature
        endpoint: SyncEndpoint(path: '/api/cart'),
        syncOnConnect: true,
        syncInterval: Duration(minutes: 5),
      ),
      FeatureConfig(
        name: 'transactions',                // manual + encrypted feature
        endpoint: SyncEndpoint(path: '/api/transactions'),
        syncOnConnect: false,
        secure: true,
      ),
    ],
  ),
  store: SqfliteOutboxStore(),
  http: DioHttpAdapter(dio: dio),
  connectivity: ConnectivityPlusAdapter(),
  cipher: FlutterSecurePayloadCipher(),
);
await offline.initialize();

await offline.forFeature('cart').create({'itemId': 'x', 'qty': 2}); // instant, local
await offline.forFeature('transactions').syncNow();                 // manual trigger
```

## How it works

```
app write ──► encrypt (secure) ──► outbox (pending)
                                      │
        ┌─────────────────────────────┤ triggers
        │                             │
  connectivity edge            manual syncNow()/syncAll()
  periodic timer                              │
        └────────────┬────────────────────────┘
                     ▼
              SyncEngine (FIFO per feature, parallel across features)
                     │
        2xx ── synced ◄── decrypt (secure) ──► HTTP (idempotency-key)
        409 ── ConflictResolver (LWW default)
        5xx/429/net ── backoff retry ── max attempts ── dead (requeueable)
        other 4xx ── failed (no retry)
```

## Status

- [x] Milestone 1 — core models, config, store/HTTP/connectivity interfaces
- [x] Milestone 2 — sync engine: FIFO, backoff, dead-letter, status events
- [x] Milestone 3 — scheduler (connectivity + periodic) and facade
- [x] Milestone 4 — Flutter adapters (sqflite, connectivity_plus, AES-GCM)
- [x] Milestone 5 — tests (33 core + 6 adapter)
- [x] Milestone 6 — example app + docs
- [ ] Later — pull/cache layer (server → local), bidirectional sync
