/// Flutter adapters for the offline_first_core engine.
///
/// Re-exports the full core API plus:
/// - [SqfliteOutboxStore] — persistent outbox
/// - [ConnectivityPlusAdapter] — auto-sync on connectivity change
/// - [FlutterSecurePayloadCipher] — AES-GCM payload encryption
library;

export 'package:offline_first_core/offline_first_core.dart';

export 'src/adapters.dart';
