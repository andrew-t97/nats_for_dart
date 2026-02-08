// KeyValue store demonstration.
//
// Requires: `nats-server -js` running on localhost:4222.

import 'dart:async';

import 'package:nats_dart/nats_dart.dart';

void main() async {
  NatsLibrary.init();

  final client = NatsClient.connect('nats://localhost:4222');
  final js = client.jetStream();

  try {
    // 1. Create a KV bucket
    final kv = js.createKeyValue(KvConfig(
      bucket: 'config',
      history: 5,
      storageType: jsStorageType.js_MemoryStorage,
    ));
    print('Created bucket: ${kv.bucket}');

    // 2. Put and get
    final rev1 = kv.putString('app.name', 'MyApp');
    print('Put app.name rev=$rev1');

    final entry = kv.get('app.name');
    print('Get app.name: "${entry?.valueAsString}" rev=${entry?.revision}');

    // 3. Optimistic concurrency update
    final rev2 = kv.updateString('app.name', 'MyApp v2', rev1);
    print('Updated app.name to "MyApp v2" rev=$rev2');

    // 4. Watch for changes
    final watchSub = kv.watch('app.>');
    final watchCompleter = Completer<void>();
    var watchCount = 0;

    final watchListener = watchSub.listen((entry) {
      print(
        'Watch: ${entry.operation.name} key=${entry.key} '
        'value="${entry.valueAsString}" rev=${entry.revision}',
      );
      watchCount++;
      // Expect initial snapshot of app.name + new put of app.version
      if (watchCount >= 2) {
        watchCompleter.complete();
      }
    });

    // Give the watcher time to start and deliver initial values
    await Future.delayed(Duration(milliseconds: 200));

    // 5. Put a new key to trigger the watcher
    kv.putString('app.version', '1.0');
    print('\nPut app.version=1.0');

    // Wait for watcher to deliver
    await watchCompleter.future.timeout(
      Duration(seconds: 5),
      onTimeout: () => print('Watch timed out'),
    );
    await watchListener.cancel();

    // 6. List all keys
    final allKeys = kv.keys();
    print('\nAll keys: $allKeys');

    // 7. View history
    final nameHistory = kv.history('app.name');
    print('\nHistory of app.name:');
    for (final h in nameHistory) {
      print('  rev=${h.revision} "${h.valueAsString}" ${h.operation.name}');
    }

    // 8. Delete and purge
    kv.delete('app.name');
    print('\nDeleted app.name');

    kv.purge('app.version');
    print('Purged app.version');

    // 9. Clean up
    kv.close();
    js.deleteKeyValue('config');
    print('Bucket deleted. Done!');
  } finally {
    js.close();
    await client.close();
    NatsLibrary.close(timeoutMs: 5000);
  }
}
