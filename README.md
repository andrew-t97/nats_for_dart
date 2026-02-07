# nats_ffi_experiment

A Dart FFI wrapper around [nats.c](https://github.com/nats-io/nats.c), the official C client for [NATS](https://nats.io/).

## Features

- Core pub/sub with sync and async subscriptions
- Request-reply messaging
- JetStream publish, subscribe, and pull consumers
- JetStream stream and consumer CRUD management
- KeyValue store: get, put, delete, watch, and history
- Automatic native memory management via `NativeFinalizer`

## Getting started

### Prerequisites

- Dart SDK (with native assets support)
- OpenSSL development libraries
- A running NATS server (`nats-server -js` for JetStream/KV features)

**macOS:**
```bash
brew install openssl@3 pkg-config
```

**Linux:**
```bash
apt install libssl-dev pkg-config
```

### Installation

Add the package to your `pubspec.yaml` and run `dart pub get`. The native C library is compiled automatically via the Dart build hook — no manual compilation or submodule steps required.

## Usage

```dart
import 'package:nats_ffi_experiment/nats_ffi_experiment.dart';

void main() async {
  NatsLibrary.init();

  final client = NatsClient();
  await client.connect('nats://localhost:4222');

  // Publish
  client.publish('greet.hello', 'world');

  // Subscribe
  final subscription = client.subscribeAsync('greet.*');
  subscription.stream.listen((msg) {
    print('${msg.subject}: ${msg.data}');
  });

  // Clean up
  subscription.unsubscribe();
  client.close();
  NatsLibrary.close();
}
```

## Upgrading the vendored nats.c

The native C source lives in `third_party/nats_c/` as a vendored copy. To upgrade to a new nats.c release:

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
