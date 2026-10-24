/// Encrypts/decrypts operation payloads for at-rest storage.
///
/// Implementations must be safe for concurrent calls. Payloads are UTF-8
/// JSON before encryption.
abstract class PayloadCipher {
  const PayloadCipher();

  /// Encrypts [plaintext] (UTF-8 JSON bytes). Returns ciphertext bytes.
  Future<List<int>> encrypt(List<int> plaintext, {required String feature});

  /// Decrypts ciphertext produced by [encrypt]. Throws on tamper/auth failure.
  Future<List<int>> decrypt(List<int> ciphertext, {required String feature});
}

/// No-op cipher for development and non-secure features.
///
/// Warning: plaintext at rest. Never use in production for secure features.
class NoopCipher extends PayloadCipher {
  const NoopCipher();

  @override
  Future<List<int>> encrypt(List<int> plaintext, {required String feature}) async =>
      plaintext;

  @override
  Future<List<int>> decrypt(List<int> ciphertext, {required String feature}) async =>
      ciphertext;
}
