import 'feature_config.dart';

/// Global configuration for the offline-first engine.
class OfflineFirstConfig {
  const OfflineFirstConfig({
    required this.baseUrl,
    required this.features,
    this.maxConcurrentFeatures = 4,
    this.batchSize = 20,
  });

  /// Base URL every [SyncEndpoint.path] is resolved against.
  final String baseUrl;

  /// Per-feature configurations. Names must be unique.
  final List<FeatureConfig> features;

  /// How many features sync in parallel.
  final int maxConcurrentFeatures;

  /// Max operations fetched per drain cycle per feature.
  final int batchSize;

  /// Returns the [FeatureConfig] for [name].
  ///
  /// Throws [ArgumentError] for unknown features — enqueueing to an
  /// unconfigured feature is a programming error.
  FeatureConfig feature(String name) {
    for (final f in features) {
      if (f.name == name) return f;
    }
    throw ArgumentError.value(
        name, 'feature', 'Unknown feature. Configured: ${features.map((f) => f.name).join(', ')}');
  }

  bool hasFeature(String name) => features.any((f) => f.name == name);
}
