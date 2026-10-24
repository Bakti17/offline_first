import 'dart:math';

/// Retry policy with exponential backoff + full jitter.
class RetryPolicy {
  const RetryPolicy({
    this.maxAttempts = 5,
    this.initialDelay = const Duration(seconds: 2),
    this.maxDelay = const Duration(minutes: 5),
    this.multiplier = 2.0,
    this.retryableStatusCodes = const {408, 429},
    this.retryOnNetworkError = true,
    Random? random,
  })  : assert(maxAttempts >= 1),
        assert(multiplier >= 1.0),
        // ignore: prefer_initializing_formals
        _random = random;

  const RetryPolicy.aggressive()
      : this(maxAttempts: 8, initialDelay: const Duration(milliseconds: 500));

  const RetryPolicy.relaxed()
      : this(maxAttempts: 3, initialDelay: const Duration(seconds: 10));

  /// Total attempts before an operation goes to dead-letter.
  final int maxAttempts;

  /// Delay before the first retry.
  final Duration initialDelay;

  /// Backoff ceiling.
  final Duration maxDelay;

  /// Growth factor per attempt.
  final double multiplier;

  /// HTTP status codes retried. 5xx always retryable, never listed here.
  /// 409 handled by [ConflictResolver], never retried.
  final Set<int> retryableStatusCodes;

  /// Retry on transport errors (timeout, socket, DNS)?
  final bool retryOnNetworkError;

  /// Injectable for deterministic tests. Defaults to [defaultRandom].
  Random get random => _random ?? defaultRandom();
  final Random? _random;

  /// Delay before retry attempt number [attempt] (1-based, the attempt that
  /// just failed). Exponential backoff with full jitter:
  /// `rand(0, min(maxDelay, initial * multiplier^(attempt-1)))`.
  Duration delayFor(int attempt) {
    final exp = initialDelay * pow(multiplier, attempt - 1);
    final capped = exp > maxDelay ? maxDelay : exp;
    final millis = capped.inMilliseconds;
    if (millis <= 0) return Duration.zero;
    return Duration(milliseconds: random.nextInt(millis + 1));
  }

  /// Engine classification of an HTTP status after a send.
  RetryDecision decisionForStatusCode(int statusCode) {
    if (statusCode >= 200 && statusCode < 300) return RetryDecision.synced;
    if (statusCode == 409) return RetryDecision.conflict;
    if (statusCode >= 500 || retryableStatusCodes.contains(statusCode)) {
      return RetryDecision.retry;
    }
    return RetryDecision.fail;
  }

  /// Engine classification of a thrown transport error.
  RetryDecision decisionForError() =>
      retryOnNetworkError ? RetryDecision.retry : RetryDecision.fail;
}

enum RetryDecision { synced, conflict, retry, fail }

/// [RetryPolicy.random] defaults to this when not injected.
final Random Function() defaultRandom = Random.secure;
