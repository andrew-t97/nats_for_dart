/// Synchronous pub/sub demo using the NATS C FFI wrapper.
///
/// Prerequisites:
///   - `brew install cnats nats-server`
///   - `nats-server` running on localhost:4222
///
/// Run:
///   dart run example/main.dart
library;

import 'package:nats_ffi_experiment/nats_ffi_experiment.dart';

Future<void> main() async {
  // 1. Initialise the NATS C library.
  print('Initialising NATS library...');
  NatsLibrary.init();

  NatsClient? client;
  NatsSyncSubscription? subscription;

  try {
    // 2. Connect to the local NATS server.
    print('Connecting to nats://localhost:4222...');
    client = NatsClient.connect('nats://localhost:4222');
    print('Connected!');

    // 3. Create a synchronous subscription on "test.subject".
    const subject = 'test.subject';
    print('Subscribing to "$subject"...');
    subscription = client.subscribeSync(subject);

    // 4. Publish a string message.
    const payload = 'Hello from Dart FFI!';
    print('Publishing: "$payload" → "$subject"');
    client.publish(subject, payload);

    // 5. Receive the message (with a 2-second timeout).
    print('Waiting for message...');
    final message = subscription.nextMessage(
      timeout: const Duration(seconds: 2),
    );

    // 6. Print the result.
    print('Received on "${message.subject}": ${message.dataAsString}');
  } catch (e) {
    print('Error: $e');
  } finally {
    // 7. Clean up.
    subscription?.close();
    await client?.close();

    // 8. Tear down the library.
    print('Closing NATS library...');
    NatsLibrary.close(timeoutMs: 5000);
    print('Done.');
  }
}
