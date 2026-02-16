## 0.1.0

- `DockerNats` now detects an already-running NATS server on port 4222 and
  skips Docker entirely, enabling tests on environments without Docker
- Added macOS CI job using native `nats-server` via Homebrew
- Core pub/sub with synchronous and asynchronous subscriptions
- Request-reply messaging
- JetStream publish, pull subscribe, and stream/consumer management
- KeyValue store with get, put, delete, watch, history, and optimistic concurrency
- Connection lifecycle event streams (disconnect, reconnect, close, error)
- Vendored nats.c v3.12.0 and LibreSSL (no system dependencies needed)
