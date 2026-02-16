# nats_for_dart

Dart FFI bindings for [nats.c](https://github.com/nats-io/nats.c), the official C client for [NATS](https://nats.io/).

## Features

- **Core pub/sub** — synchronous and asynchronous subscriptions with wildcard support
- **Request-reply** — simple request/response messaging
- **JetStream** — publish, pull subscribe, stream and consumer CRUD management
- **KeyValue store** — get, put, delete, watch, history, and optimistic concurrency
- **Connection lifecycle** — disconnect, reconnect, close, and error event streams via `NatsOptions`

## Prerequisites

- **Dart SDK** `^3.10.8` (with native assets support)
- **`nats-server`** running on localhost — start with the `-js` flag for JetStream and KeyValue features

The native C library (nats.c v3.12.0) and LibreSSL are vendored and compiled automatically by the Dart build hook. No system OpenSSL, `pkg-config`, or manual C compilation is required.

## Installation

Add the package to your `pubspec.yaml`:

```yaml
dependencies:
  nats_for_dart: ^0.1.0
```

Then run:

```bash
dart pub get
```

## Quick start

```dart
import 'package:nats_for_dart/nats_for_dart.dart';

Future<void> main() async {
  NatsLibrary.init();

  final client = NatsClient.connect('nats://localhost:4222');

  // Subscribe asynchronously
  final subscription = client.subscribe('greet.*');
  subscription.messages.listen((msg) {
    print('${msg.subject}: ${msg.dataAsString}');
  });

  // Publish
  client.publish('greet.hello', 'world');
  client.flush();

  // Wait a moment for delivery, then clean up
  await Future.delayed(Duration(seconds: 1));
  await subscription.close();
  await client.close();
  NatsLibrary.close(timeoutMs: 5000);
}
```

## Examples

| Example                                                  | Description                             | Run command                               |
| -------------------------------------------------------- | --------------------------------------- | ----------------------------------------- |
| [main.dart](example/main.dart)                           | Synchronous pub/sub                     | `dart run example/main.dart`              |
| [async_subscriber.dart](example/async_subscriber.dart)   | Async subscription with `Stream`        | `dart run example/async_subscriber.dart`  |
| [lifecycle_demo.dart](example/lifecycle_demo.dart)       | Connection lifecycle events             | `dart run example/lifecycle_demo.dart`    |
| [jetstream_pub_sub.dart](example/jetstream_pub_sub.dart) | JetStream publish and pull subscribe    | `dart run example/jetstream_pub_sub.dart` |
| [kv_demo.dart](example/kv_demo.dart)                     | KeyValue store CRUD, watch, and history | `dart run example/kv_demo.dart`           |

All examples except `main.dart` require `nats-server -js`.

## Running tests

Tests automatically start a Docker NATS container with JetStream enabled. Docker must be installed and running.

```bash
# Run all tests — Docker container starts/stops automatically
just test

# Run a single test file
just test-single nats_client_test.dart
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for development and maintenance workflows, including how to upgrade the vendored nats.c library.

## License

Apache 2.0
