/// Asynchronous subscription demo using the NATS C FFI wrapper.
///
/// Prerequisites:
///   - `nats-server` running on localhost:4222
///
/// Run:
///   dart run example/async_subscriber.dart
library;

import 'dart:async';

import 'package:nats_for_dart/nats_for_dart.dart';

Future<void> main() async {
  // 1. Initialise the NATS C library.
  print('Initialising NATS library...');
  NatsLibrary.init();

  NatsClient? client;
  NatsAsyncSubscription? subscription;

  try {
    // 2. Connect to the local NATS server.
    print('Connecting to nats://localhost:4222...');
    client = NatsClient.connect('nats://localhost:4222');
    print('Connected!');

    // 3. Create an async subscription on "demo.>".
    print('Subscribing to "demo.>"...');
    subscription = client.subscribe('demo.>');

    // 4. Collect messages in a list so we know when all 10 arrive.
    final received = <NatsMessage>[];
    final completer = Completer<void>();

    final listener = subscription.messages.listen((msg) {
      received.add(msg);
      print(
        '  [${received.length}] Received on "${msg.subject}": '
        '${msg.dataAsString}',
      );
      if (received.length >= 10) {
        completer.complete();
      }
    });

    // 5. Publish 10 messages at ~500ms intervals.
    print('Publishing 10 messages to "demo.hello"...');
    for (var i = 1; i <= 10; i++) {
      client.publish('demo.hello', 'Message #$i');
      // Flush to ensure the message is sent immediately.
      client.flush();
      await Future.delayed(const Duration(milliseconds: 500));
    }

    // 6. Wait for all messages to arrive (with a safety timeout).
    await completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        print('Timed out waiting — received ${received.length}/10 messages.');
      },
    );

    // 7. Clean up.
    await listener.cancel();
    print('\nAll ${received.length} messages received!');
  } catch (e) {
    print('Error: $e');
  } finally {
    await subscription?.close();
    await client?.close();

    print('Closing NATS library...');
    NatsLibrary.close(timeoutMs: 5000);
    print('Done.');
  }
}
