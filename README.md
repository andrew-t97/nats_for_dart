# nats_for_dart

[![pub.dev](https://img.shields.io/pub/v/nats_for_dart.svg)](https://pub.dev/packages/nats_for_dart)
[![CI](https://github.com/andrew-t97/nats_for_dart/actions/workflows/ci.yml/badge.svg)](https://github.com/andrew-t97/nats_for_dart/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
[![Dart SDK](https://img.shields.io/badge/dart-%5E3.10.8-00B4AB.svg)](https://dart.dev)

Idiomatic Dart bindings for [NATS](https://nats.io/) — pub/sub, JetStream, and KeyValue built on [nats.c v3.12.0](https://github.com/nats-io/nats.c), with no system OpenSSL required.

## ⚡ Features

- **Pub/sub** — synchronous and asynchronous subscriptions, wildcard subjects (`foo.*`, `foo.>`)
- **Request-reply** — single-call request/response pattern
- **JetStream** — durable streams, consumers, publish with ack, and pull subscribe
- **KeyValue store** — get, put, delete, watch, history, and optimistic concurrency with revision checks
- **Connection lifecycle** — disconnect, reconnect, close, and async error event streams

## 📱 Supported platforms
| Platform | Supported |
| -------- | --------- |
| Desktop  | ✅         |
| Mobile   | ❌         |
| Web      | ❌         |

## 📦 Installation

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  nats_for_dart: ^0.1.0
```

Then run:

```bash
dart pub get
```

> The native `libnats` shared library is compiled on first build. This may take some time depending on your machine while LibreSSL and nats.c are compiled from source.

## 🚀 Quick Start

```dart
import 'package:nats_for_dart/nats_for_dart.dart';

void main() {
  // 1. Initialise the library once per process.
  NatsLibrary.init();

  final client = NatsClient.connect('nats://localhost:4222');

  // 2. Subscribe synchronously on a subject.
  final sub = client.subscribeSync('greet.hello');

  // 3. Publish a message.
  client.publish('greet.hello', 'Hello, NATS!');

  // 4. Receive the next message (blocks up to 2 seconds).
  final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
  print('${msg.subject}: ${msg.dataAsString}');
  // → greet.hello: Hello, NATS!

  // 5. Clean up.
  sub.close();
  client.close();
  NatsLibrary.close(timeoutMs: 5000);
}
```

For async (Stream-based) subscriptions, see [`example/async_subscriber.dart`](example/async_subscriber.dart). For JetStream and KeyValue examples, see [Examples](#-examples) below.

## 💡 Examples

| Example                                                    | Description                                                                    | Run                                       |
| ---------------------------------------------------------- | ------------------------------------------------------------------------------ | ----------------------------------------- |
| [`pubsub_sync.dart`](example/pubsub_sync.dart)             | Synchronous pub/sub — publish and receive in one process                       | `dart run example/pubsub_sync.dart`       |
| [`async_subscriber.dart`](example/async_subscriber.dart)   | Async subscription via Dart `Stream` with wildcard subject                     | `dart run example/async_subscriber.dart`  |
| [`lifecycle_demo.dart`](example/lifecycle_demo.dart)       | Connection lifecycle events — stop/restart the server while running to observe | `dart run example/lifecycle_demo.dart`    |
| [`jetstream_pub_sub.dart`](example/jetstream_pub_sub.dart) | JetStream stream creation, publish with ack, and pull subscribe                | `dart run example/jetstream_pub_sub.dart` |
| [`kv_demo.dart`](example/kv_demo.dart)                     | KeyValue CRUD, optimistic update, watch, history, delete, and purge            | `dart run example/kv_demo.dart`           |

> `pubsub_sync.dart` and `async_subscriber.dart` require only a plain `nats-server`. All other examples require `nats-server -js` (JetStream enabled).

 ## 🤖 A note on AI assistance

 This package was developed with heavy use of AI tooling (Claude Code). The implementation has been
 reviewed carefully, but given the early stage (`v0.1.0`) and the nature of AI-assisted development, you
  should feel comfortable scrutinising any part of the code. If something looks wrong, surprising, or
 suboptimal — it very well might be. Issues and PRs are welcome. 🙏

## 🗺️ Roadmap

`nats_for_dart` v0.1.0 covers the core use cases. The following tracks progress toward production readiness and full parity with the NATS C client.

### 🔐 Production Essentials

These features are required for secure, production-grade deployments.

| Feature                    | Why it matters                                                                    |
| -------------------------- | --------------------------------------------------------------------------------- |
| TLS Enable/Disable         | Encrypted connections for any non-development deployment                          |
| CA Certificates            | Server identity verification — prevents MITM attacks                              |
| Client Certificates (mTLS) | Mutual TLS authentication for zero-trust environments                             |
| TLS Configuration          | Cipher selection, hostname verification, and skip-verify options                  |
| Message Headers            | Metadata, distributed tracing, and deduplication — used widely in NATS ecosystems |

### ✨ Coming Next

These additions complete the JetStream management API and round out connection options.

| Feature          | Why it matters                                                                |
| ---------------- | ----------------------------------------------------------------------------- |
| Consumer Update  | FFI binding already exists — only the Dart wrapper is missing                 |
| Stream Listing   | Discover and manage all streams programmatically                              |
| Consumer Listing | Enumerate consumers per stream for monitoring and tooling                     |
| Reconnect Jitter | Prevents thundering-herd reconnects in large deployments                      |
| No Echo          | Suppress delivery of your own published messages to your own subscribers      |
| Direct NKey Auth | Alternative to credentials files — sign challenges directly with an NKey seed |

<details><summary>Priority 3 and 4 — Future Additions</summary>

### Valuable Additions

| Feature                     | Why it matters                                           |
| --------------------------- | -------------------------------------------------------- |
| Object Store                | Large object (file/blob) storage over NATS via JetStream |
| Dynamic Server Discovery    | Auto-discover new cluster members without restarting     |
| Lame Duck Mode Callback     | Graceful shutdown notification from departing servers    |
| Allow/Disable Reconnect     | Explicit control over whether reconnection is attempted  |
| Custom Reconnect Delay      | Callback-driven exponential backoff or custom logic      |
| Fail Requests on Disconnect | Fail-fast behavior instead of buffering requests         |
| Ordered Consumers           | Simplified exactly-once-delivery consumer configuration  |

### Nice to Have

| Feature                     | Why it matters                                                  |
| --------------------------- | --------------------------------------------------------------- |
| Token Refresh Handler       | Dynamic token generation on each reconnect                      |
| Custom Credentials Callback | Generate credentials programmatically                           |
| Send As Soon As Possible    | TCP_NODELAY for latency-sensitive workloads                     |
| Retry on Failed Connect     | Auto-retry the initial connection attempt                       |
| Max Pending Msgs/Bytes      | Per-subscription flow control                                   |
| Micro Service API           | Built-in NATS microservice framework (`micro_AddService`, etc.) |
| WebSocket Transport         | Browser-compatible NATS connections                             |

</details>

---

## 🧑‍💻 Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup, pre-commit hooks, and instructions for upgrading the vendored nats.c and LibreSSL libraries.

## ⚖️ License

This package is licensed under the [Apache License, Version 2.0](LICENSE).

### Third-Party Notices

This package vendors the following C libraries, compiled into the native `libnats`
shared library:

- [**nats.c v3.12.0**](https://github.com/nats-io/nats.c) — [Apache License 2.0](third_party/nats_c/LICENSE)
- [**LibreSSL v4.1.0**](https://www.libressl.org/) — [ISC / OpenSSL / SSLeay](third_party/libressl/LICENSE)

LibreSSL includes code derived from OpenSSL and SSLeay. In compliance with those
licenses:

> This product includes software developed by the OpenSSL Project
> for use in the OpenSSL Toolkit (http://www.openssl.org/)

> This product includes cryptographic software written by Eric Young
> (eay@cryptsoft.com).

See [NOTICE](NOTICE.md) for full third-party attribution notices.
