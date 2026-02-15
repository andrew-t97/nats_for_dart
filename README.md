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
  nats_for_dart:
    path: ../nats_for_dart  # or your path / git ref
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

A running `nats-server -js` is required for the test suite.

```bash
# Run all tests (sequential init/close cycles)
just test

# Run a single test file
just test-single nats_client_test.dart
```

## Upgrading the vendored nats.c

The native C source lives in `third_party/nats_c/` as a vendored copy (currently v3.12.0). To upgrade to a new nats.c release:

1. **Clone or download** the new [nats.c release](https://github.com/nats-io/nats.c/releases).

2. **Run the update script:**
   ```bash
   ./scripts/update_vendor.sh /path/to/nats.c
   ```

3. **Check for added or removed `.c` files** and update the `_sources` list in `hook/build.dart` accordingly. The script will print file counts to help you spot differences.

4. **Regenerate FFI bindings:**
   ```bash
   dart run ffigen --config ffigen.yaml
   ```

5. **Run the test suite:**
   ```bash
   just test
   ```

> **Note:** If upgrading from a release where `version.h` is not pre-generated (only `version.h.in` exists), manually create `version.h` from `version.h.in` by substituting the version values before building.

## License

Apache 2.0
