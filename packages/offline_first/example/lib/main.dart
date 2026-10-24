import 'dart:async';

import 'package:flutter/material.dart';
import 'package:offline_first/offline_first.dart';

/// Demo: offline-first cart + manual-only transactions.
///
/// Run with any backend that echoes 2xx (e.g. `json-server`, `mockapi`),
/// or point at a real API. Toggle airplane mode to see the queue drain
/// on reconnect.
Future<void> main() async {
  runApp(const OfflineFirstDemoApp());
}

class OfflineFirstDemoApp extends StatelessWidget {
  const OfflineFirstDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'offline_first demo',
      theme: ThemeData(useMaterial3: true),
      home: const DemoPage(),
    );
  }
}

class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

class _DemoPageState extends State<DemoPage> {
  late final OfflineFirst _offline;
  StreamSubscription<SyncStatusEvent>? _statusSub;
  final Map<SyncStatus, int> _cartCounts = {};
  String _lastEvent = '—';
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final dio = Dio()
      ..options.connectTimeout = const Duration(seconds: 10)
      // Interceptors for auth go here:
      // ..interceptors.add(AuthInterceptor());
      ;

    _offline = OfflineFirst(
      config: const OfflineFirstConfig(
        baseUrl: 'https://api.example.com',
        features: [
          FeatureConfig(
            name: 'cart',
            endpoint: SyncEndpoint(path: '/api/cart'),
            syncOnConnect: true, // auto sync when back online
            syncInterval: Duration(minutes: 5), // periodic
          ),
          FeatureConfig(
            name: 'transactions',
            endpoint: SyncEndpoint(path: '/api/transactions'),
            syncOnConnect: false, // manual only
            secure: true, // encrypted at rest
          ),
        ],
      ),
      store: SqfliteOutboxStore(),
      http: DioHttpAdapter(dio: dio),
      connectivity: ConnectivityPlusAdapter(),
      cipher: FlutterSecurePayloadCipher(),
    );

    await _offline.initialize();
    _statusSub = _offline.statusStream.listen((event) {
      if (!mounted) return;
      setState(() {
        _lastEvent = '${event.feature}: ${event.phase.name}';
        if (event.feature == 'cart') _cartCounts.addAll(event.counts);
      });
    });
    if (mounted) setState(() => _ready = true);
  }

  Future<void> _addToCart() async {
    await _offline.forFeature('cart').create({
      'itemId': 'sku-${DateTime.now().millisecondsSinceEpoch % 1000}',
      'qty': 1,
    });
  }

  Future<void> _addTransaction() async {
    await _offline.forFeature('transactions').create({
      'amount': 19.99,
      'currency': 'USD',
    });
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _offline.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('offline_first demo')),
      body: !_ready
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text('Last event: $_lastEvent'),
                const SizedBox(height: 8),
                Text('Cart queue: $_cartCounts'),
                const Divider(height: 32),
                FilledButton(
                  onPressed: _addToCart,
                  child: const Text('Add cart item (auto-sync)'),
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: _addTransaction,
                  child: const Text('Add transaction (manual, encrypted)'),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  onPressed: () => _offline.syncNow('transactions'),
                  child: const Text('Sync transactions now'),
                ),
                OutlinedButton(
                  onPressed: () => _offline.syncAll(),
                  child: const Text('Sync everything'),
                ),
                OutlinedButton(
                  onPressed: () => _offline.retryFailed(),
                  child: const Text('Retry failed/dead'),
                ),
                OutlinedButton(
                  onPressed: () => _offline.purgeSynced(),
                  child: const Text('Purge synced'),
                ),
              ],
            ),
    );
  }
}
