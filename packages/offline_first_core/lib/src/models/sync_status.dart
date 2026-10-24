/// Status of a single [SyncOperation] in the outbox queue.
enum SyncStatus {
  /// Waiting to be sent.
  pending,

  /// Currently being sent by the sync engine.
  inFlight,

  /// Successfully acknowledged by the API.
  synced,

  /// Failed with a non-retryable error (e.g. 4xx other than 409/429).
  /// Terminal unless retried manually via [RetryPolicy].
  failed,

  /// Exhausted [RetryPolicy.maxAttempts] retries. Inspectable and
  /// re-syncable (dead-letter queue).
  dead,
}
