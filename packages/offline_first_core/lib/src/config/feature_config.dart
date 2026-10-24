import 'sync_endpoint.dart';

/// Per-feature sync configuration.
///
/// Each feature (e.g. `cart`, `transactions`) maps to exactly one endpoint
/// and its own trigger + security behavior.
class FeatureConfig {
  const FeatureConfig({
    required this.name,
    required this.endpoint,
    this.syncOnConnect = true,
    this.syncInterval,
    this.secure = false,
  }) : assert(name.length > 0);

  /// Unique feature namespace, e.g. `cart`.
  final String name;

  final SyncEndpoint endpoint;

  /// Sync automatically when connectivity is regained.
  final bool syncOnConnect;

  /// Optional periodic sync interval. `null` disables periodic sync.
  final Duration? syncInterval;

  /// When true, payloads are encrypted before storage and decrypted in
  /// memory only at send time. Requires a cipher on the main config.
  final bool secure;
}
