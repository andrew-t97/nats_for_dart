/// Lifecycle callback demo using the NATS C FFI wrapper.
///
/// Demonstrates connection lifecycle events (disconnected, reconnected,
/// closed, error) by supplying a [NatsOptions] value to
/// [NatsClient.connect] and listening on the client's broadcast streams.
///
/// Prerequisites:
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
    // 2. Connect with options.
    print('Connecting...');
    client = NatsClient.connect(
      'nats://localhost:4222',
      options: const NatsOptions(
        name: 'lifecycle-demo',
        maxReconnect: 10,
        reconnectWait: Duration(seconds: 2),
      ),
    );
    print('Connected!');

    // 3. Listen for lifecycle events on the client. Listeners can be
    //    attached at any time before or after connect; the streams are
    //    broadcast and never replay missed events.
    client.onDisconnected.listen((_) {
      print('[EVENT] Disconnected from server');
    });

    client.onReconnected.listen((_) {
      print('[EVENT] Reconnected to server');
    });

    client.onClosed.listen((_) {
      print('[EVENT] Connection permanently closed');
    });

    client.onError.listen((error) {
      print('[ERROR] Async error: $error');
    });

    // 4. Subscribe and publish a test message to prove the connection works.
    final subscription = client.subscribe('lifecycle.test');

    // Listen for the first message before publishing to avoid a race.
    final firstMessage = subscription.messages.first;

    client.publish('lifecycle.test', 'Hello from lifecycle demo!');
    client.flush();

    final msg = await firstMessage.timeout(const Duration(seconds: 5));
    print('Received: "${msg.dataAsString}" on "${msg.subject}"');

    await subscription.close();

    // 5. Keep the program running so you can stop/restart nats-server
    //    and observe lifecycle events.
    print('\n--- Waiting for lifecycle events ---');
    print('Try stopping and restarting nats-server.');
    print('Press Ctrl-C to exit.\n');

    // Keep alive for 60 seconds.
    await Future.delayed(const Duration(seconds: 60));
  } on ArgumentError catch (e) {
    print('Invalid NatsOptions: $e');
  } on NatsException catch (e, stackTrace) {
    print('NATS runtime error: $e\n$stackTrace');
  } finally {
    await client?.close();

    print('Closing NATS library...');
    NatsLibrary.close(timeoutMs: 5000);
    print('Done.');
  }
}
