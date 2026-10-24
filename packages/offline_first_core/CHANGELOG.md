# Changelog

## 0.0.1

- Initial release: outbox pattern engine with per-feature sync configuration.
- FIFO per-feature drain, parallel across features, head-of-line blocking on
  failure/backoff.
- Retry: exponential backoff + full jitter, 5xx/429/408/network retryable,
  4xx terminal, dead-letter after `maxAttempts`, `retryFailed()` requeue.
- Triggers: connectivity edge, per-feature periodic interval, manual
  `syncNow()`/`syncAll()`.
- Encrypted-at-rest payloads for `secure` features (`PayloadCipher`).
- 409 conflict resolution (last-write-wins default, server-wins included).
- Adapters: `MemoryOutboxStore`, `DioHttpAdapter`, `StaticConnectivity`.
- Status event stream for UI binding.
