# offline_first

Flutter adapters for [`offline_first_core`](../offline_first_core):
persistent storage, connectivity triggers, and payload encryption — plus a
re-export of the entire core API.

## What's included

| Component | Class | Notes |
|---|---|---|
| Outbox store | `SqfliteOutboxStore` | SQLite table, FIFO by autoincrement `sequence` |
| Connectivity | `ConnectivityPlusAdapter` | online = any non-none result (connectivity_plus v6) |
| Cipher | `FlutterSecurePayloadCipher` | AES-256-GCM, key per feature in Keychain/Keystore |

## Installation

```yaml
dependencies:
  offline_first:
    path: ../offline_first
```

## Quick start

```dart
import 'package:offline_first/offline_first.dart';

final dio = Dio()..options.connectTimeout = const Duration(seconds: 10);
// dio.interceptors.add(AuthInterceptor()); // token refresh etc.

final offline = OfflineFirst(
  config: const OfflineFirstConfig(
    baseUrl: 'https://api.example.com',
    features: [
      FeatureConfig(
        name: 'cart',
        endpoint: SyncEndpoint(path: '/api/cart'),
        syncOnConnect: true,                 // sync when back online
        syncInterval: Duration(minutes: 5),  // + periodic
      ),
      FeatureConfig(
        name: 'transactions',
        endpoint: SyncEndpoint(path: '/api/transactions'),
        syncOnConnect: false, // manual only
        secure: true,         // encrypted at rest
      ),
    ],
  ),
  store: SqfliteOutboxStore(),
  http: DioHttpAdapter(dio: dio),
  connectivity: ConnectivityPlusAdapter(),
  cipher: FlutterSecurePayloadCipher(), // required: a feature is secure
);

await offline.initialize();

// Queue a write — instant, survives app restart.
await offline.forFeature('cart').create({'itemId': 'x', 'qty': 2});

// Manual sync for the manual-only feature.
await offline.forFeature('transactions').syncNow();

// Bind UI to queue state.
offline.statusStream.listen((event) => print(event));
```

## Test setup

Sqflite store tests run on the host with FFI:

```dart
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

setUpAll(() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
});
```

## Example app

See [`example/`](example/lib/main.dart) for a full demo: cart with
auto-sync + transactions manual/encrypted, live queue status, retry and
purge buttons. Toggle airplane mode to watch the outbox drain on
reconnect.
