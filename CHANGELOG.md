## 0.2.0

### Breaking changes

- Connection options are now passed to `NatsClient.connectAsync` via an optional `options:` named argument (`NatsClient.connectAsync(url, options: NatsOptions(...))`). The separate `connectWithOptionsAsync` method has been removed.

### Added

- Message headers — HTTP-style `name: value` metadata via the new `NatsHeaders` object, on core publish/request/respond and JetStream publish, with multi-value Add semantics. Enables distributed tracing, `Nats-Msg-Id` deduplication, and `Nats-Expected-Last-Sequence` optimistic publish.
- TLS / mTLS support:
  - Enable TLS and optionally skip server verification (`NatsOptions.tls`, `NatsOptions.skipServerVerification`).
  - CA trust anchor from a file path (`NatsOptions.caCertPath`) or PEM string (`NatsOptions.caCertPem`).
  - Client cert/key for mutual TLS from file paths (`NatsOptions.clientCertPath` + `NatsOptions.clientKeyPath`) or PEM strings (`NatsOptions.clientCertPem` + `NatsOptions.clientKeyPem`).
  - Server-cert hostname verification with an override via `NatsOptions.expectedHostname` for IP-dialled or SNI-proxied connections.
  - TLS ≤ 1.2 cipher allow-list via `NatsOptions.tlsCiphers` (OpenSSL syntax).
  - TLS handshake-first via `NatsOptions.tlsHandshakeFirst`, for downgrade-attack-resistant deployments.

## 0.1.0

- Replaced C-style enum exports with Dart-idiomatic enums. `jsStorageType.js_MemoryStorage` is now `StorageType.memory`, `natsStatus.NATS_TIMEOUT` is now `NatsStatus.timeout`, etc. All 8 enums renamed: `RetentionPolicy`, `DiscardPolicy`, `StorageType`, `DeliverPolicy`, `AckPolicy`, `ReplayPolicy`, `KvOperation`, `NatsStatus`.
- Core pub/sub with synchronous and asynchronous subscriptions
- Request-reply messaging
- JetStream publish, pull subscribe, and stream/consumer management
- KeyValue store with get, put, delete, watch, history, and optimistic concurrency
- Connection lifecycle event streams (disconnect, reconnect, close, error)
- Vendored nats.c v3.12.0 and LibreSSL (no system dependencies needed)
