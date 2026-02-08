/// Lifecycle callback demo using the NATS C FFI wrapper.
///
/// Demonstrates connection lifecycle events (disconnected, reconnected,
/// closed) using [NatsOptions] with `NativeCallable.listener()`.
///
/// Prerequisites:
///   - `brew install cnats nats-server`
///   - `nats-server` running on localhost:4222
///
/// Run:
///   dart run example/lifecycle_demo.dart
///
/// While running, try stopping and restarting `nats-server` to observe
/// disconnect/reconnect events in the console.
library;

import 'dart:async';

import 'package:nats_for_dart/nats_for_dart.dart';

Future<void> main() async {
  // 1. Initialise the NATS C library.
  print('Initialising NATS library...');
  NatsLibrary.init();

  NatsClient? client;

  try {
    // 2. Create NatsOptions with lifecycle callbacks.
    final opts = NatsOptions()
      ..setUrl('nats://localhost:4222')
      ..setMaxReconnect(10)
      ..setReconnectWait(const Duration(seconds: 2));

    // 3. Listen for lifecycle events.
    opts.onDisconnected().listen((_) {
      print('[EVENT] Disconnected from server');
    });

    opts.onReconnected().listen((_) {
      print('[EVENT] Reconnected to server');
    });

    opts.onClosed().listen((_) {
      print('[EVENT] Connection permanently closed');
    });

    opts.onError().listen((error) {
      print('[ERROR] Async error: $error');
    });

    // 4. Connect using the options.
    print('Connecting with lifecycle callbacks...');
    client = NatsClient.connectWithOptions(opts);
    print('Connected!');

    // 5. Subscribe and publish a test message to prove the connection works.
    final subscription = client.subscribe('lifecycle.test');

    // Listen for the first message before publishing to avoid a race.
    final firstMessage = subscription.messages.first;

    client.publish('lifecycle.test', 'Hello from lifecycle demo!');
    client.flush();

    final msg = await firstMessage.timeout(const Duration(seconds: 5));
    print('Received: "${msg.dataAsString}" on "${msg.subject}"');

    await subscription.close();

    // 6. Keep the program running so you can stop/restart nats-server
    //    and observe lifecycle events.
    print('\n--- Waiting for lifecycle events ---');
    print('Try stopping and restarting nats-server.');
    print('Press Ctrl-C to exit.\n');

    // Keep alive for 60 seconds.
    await Future.delayed(const Duration(seconds: 60));
  } catch (e) {
    print('Error: $e');
  } finally {
    await client?.close();

    print('Closing NATS library...');
    NatsLibrary.close(timeoutMs: 5000);
    print('Done.');
  }
}
