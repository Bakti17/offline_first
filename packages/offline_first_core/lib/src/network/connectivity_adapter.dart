/// Connectivity signal for auto-sync triggers.
///
/// Core stays pure Dart; platform implementations (connectivity_plus,
/// socket checks) live in host apps or the Flutter adapter package.
abstract class ConnectivityAdapter {
  const ConnectivityAdapter();

  /// Current online state. `true` = assume syncable.
  Future<bool> isOnline();

  /// Emits on connectivity changes. First event = current state.
  Stream<bool> get onConnectivityChanged;
}

/// Static connectivity — always online or always offline. Useful for
/// manual-only mode, tests, and server-side Dart.
class StaticConnectivity extends ConnectivityAdapter {
  const StaticConnectivity({this.online = true});

  final bool online;

  @override
  Future<bool> isOnline() async => online;

  @override
  Stream<bool> get onConnectivityChanged => Stream.value(online);
}
