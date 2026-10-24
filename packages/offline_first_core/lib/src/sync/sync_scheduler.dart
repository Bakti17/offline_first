import 'dart:async';

import '../network/connectivity_adapter.dart';
import 'sync_engine.dart';

/// Drives automatic sync triggers:
/// - offline -> online edge: sync every `syncOnConnect` feature
/// - per-feature periodic timer (`syncInterval`)
///
/// Manual triggers (`syncNow` / `syncAll`) live on the facade and feed
/// through the same engine, so cycle coalescing covers all paths.
class SyncScheduler {
  SyncScheduler(this._engine, this._connectivity);

  final SyncEngine _engine;
  final ConnectivityAdapter? _connectivity;
  final List<Timer> _timers = [];
  StreamSubscription<bool>? _connectivitySub;
  bool _started = false;
  bool _wasOnline = true;

  /// Registers triggers. Requires a [ConnectivityAdapter] for the
  /// on-connect trigger; periodic timers work without one.
  Future<void> start() async {
    if (_started) return;
    _started = true;

    for (final feature in _engine.config.features) {
      final interval = feature.syncInterval;
      if (interval != null) {
        _timers.add(Timer.periodic(interval, (_) {
          _engine.syncFeature(feature.name);
        }));
      }
    }

    if (_connectivity != null) {
      _wasOnline = await _connectivity.isOnline();
      _connectivitySub = _connectivity.onConnectivityChanged.listen((online) {
        final edge = !_wasOnline && online;
        _wasOnline = online;
        if (edge) _syncOnConnectFeatures();
      });
    }
  }

  void _syncOnConnectFeatures() {
    for (final feature in _engine.config.features) {
      if (feature.syncOnConnect) {
        _engine.syncFeature(feature.name);
      }
    }
  }

  /// Cancels timers and the connectivity subscription.
  Future<void> stop() async {
    for (final timer in _timers) {
      timer.cancel();
    }
    _timers.clear();
    await _connectivitySub?.cancel();
    _connectivitySub = null;
    _started = false;
  }
}
