## 0.1.0

- Replaced C-style enum exports with Dart-idiomatic enums. `jsStorageType.js_MemoryStorage` is now `StorageType.memory`, `natsStatus.NATS_TIMEOUT` is now `NatsStatus.timeout`, etc. All 8 enums renamed: `RetentionPolicy`, `DiscardPolicy`, `StorageType`, `DeliverPolicy`, `AckPolicy`, `ReplayPolicy`, `KvOperation`, `NatsStatus`.
- `DockerNats` now detects an already-running NATS server on port 4222 and
  skips Docker entirely, enabling tests on environments without Docker
- Added macOS CI job using native `nats-server` via Homebrew
- Core pub/sub with synchronous and asynchronous subscriptions
- Request-reply messaging
- JetStream publish, pull subscribe, and stream/consumer management
- KeyValue store with get, put, delete, watch, history, and optimistic concurrency
- Connection lifecycle event streams (disconnect, reconnect, close, error)
- Vendored nats.c v3.12.0 and LibreSSL (no system dependencies needed)
