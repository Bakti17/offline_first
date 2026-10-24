# offline_first_core

Pure Dart offline-first engine. Apps write to a local outbox queue; a sync
engine drains the queue to per-feature API endpoints when online. No
Flutter dependencies — works in Dart CLI, server, and tests.

Part of the `offline_first` monorepo. For Flutter apps use the
[`offline_first`](../offline_first) package, which re-exports this core
plus platform adapters.

## Features

- **Outbox pattern** — every write lands locally first; the app never
  blocks on the network.
- **Per-feature configuration** — each feature (`cart`, `transactions`, …)
  maps to its own endpoint, method, headers, and trigger policy.
- **Auto + manual sync** — fires on connectivity regain, on a per-feature
  periodic interval, or on demand (`syncNow` / `syncAll`).
- **Encrypted at rest** — mark a feature `secure: true` and payloads are
  encrypted before storage, decrypted only at send time.
- **Retry with backoff** — exponential backoff with full jitter; 5xx/429/
  network errors retry, other 4xx fail fast, `maxAttempts` exhausted
  operations dead-letter for later inspection and requeue.
- **FIFO ordering** — queue order per feature is preserved; a failed or
  backoff-blocked head blocks the feature (no out-of-order sends).
- **Pluggable everything** — storage, HTTP, connectivity, encryption, and
  conflict resolution are interfaces with sensible defaults.

## Installation

```yaml
dependencies:
  offline_first_core:
    path: ../offline_first_core
```

## Quick start

```dart
final offline = OfflineFirst(
  config: const OfflineFirstConfig(
    baseUrl: 'https://api.example.com',
    features: [
      FeatureConfig(
        name: 'cart',
        endpoint: SyncEndpoint(path: '/api/cart'),
        syncOnConnect: true,
        syncInterval: Duration(minutes: 5),
      ),
      FeatureConfig(
        name: 'transactions',
        endpoint: SyncEndpoint(path: '/api/transactions'),
        syncOnConnect: false, // manual only
        secure: true,         // encrypt payload at rest
      ),
    ],
  ),
  store: MemoryOutboxStore(),          // or your own OutboxStore impl
  http: DioHttpAdapter(dio: dio),      // inject Dio with auth interceptors
  connectivity: StaticConnectivity(),  // or a real adapter
  cipher: MyPayloadCipher(),           // required when any feature is secure
);

await offline.initialize();

// Write — instant, local.
await offline.forFeature('cart').create({'itemId': 'x', 'qty': 2});

// Manual triggers.
await offline.forFeature('transactions').syncNow();
await offline.syncAll();

// UI binding.
offline.statusStream.listen((event) {
  print('${event.feature}: ${event.phase.name} ${event.counts}');
});

// Dead-letter recovery.
final requeued = await offline.retryFailed(featureName: 'cart');
await offline.syncNow('cart');
```

## Core concepts

### Sync lifecycle

`enqueue` → `pending` → engine drain → `synced`
`pending` → retryable failure → backoff (`nextAttemptAt`) → `pending` … → `dead`
`pending` → 4xx (non-retryable) → `failed`

A 409 goes to the configured `ConflictResolver`: last-write-wins (default,
marks synced) or server-wins (drops as failed).

### Encrypted payloads

For `secure` features the facade encrypts on enqueue and stores
`{'__ciphertext': '<base64>'}`. The engine detects the marker, decrypts in
memory, and sends plaintext JSON over TLS. Metadata (status, attempts,
timestamps) stays plaintext for queue inspection.

### Error classification

| Outcome | Status codes | Result |
|---|---|---|
| Success | 2xx | `synced` |
| Conflict | 409 | resolver decides |
| Retry | 5xx, 429, 408, network errors | backoff, attempt+1 |
| Terminal | other 4xx | `failed`, no retry |

## Adapters to implement for production

| Interface | Purpose |
|---|---|
| `OutboxStore` | durable queue (see the Flutter package's `SqfliteOutboxStore`) |
| `ConnectivityAdapter` | online/offline signal for auto-sync |
| `PayloadCipher` | at-rest encryption for `secure` features |
| `HttpAdapter` | custom transport (default: dio) |
| `ConflictResolver` | 409 policy (default: last-write-wins) |

`MemoryOutboxStore` and `StaticConnectivity` ship with the core for tests.
