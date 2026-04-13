/// Minimal pub/sub example using the NATS C FFI wrapper.
///
/// Prerequisites:
///   - `nats-server` running on localhost:4222
///
/// Run:
///   dart run example/example.dart
library;

import 'package:nats_for_dart/nats_for_dart.dart';

Future<void> main() async {
  // 1. Initialise the NATS C library once per process.
  NatsLibrary.init();

  NatsClient? client;
  NatsSyncSubscription? sub;

  try {
    // 2. Connect to the local NATS server.
    client = NatsClient.connect('nats://localhost:4222');

    // 3. Subscribe synchronously on a subject.
    sub = client.subscribeSync('greet.hello');

    // 4. Publish a message.
    client.publish('greet.hello', 'Hello, NATS!');

    // 5. Receive the next message (blocks up to 2 seconds).
    final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
    print('${msg.subject}: ${msg.dataAsString}');
    // → greet.hello: Hello, NATS!
  } finally {
    // 6. Clean up.
    sub?.close();
    await client?.close();
    NatsLibrary.close(timeoutMs: 5000);
  }
}
