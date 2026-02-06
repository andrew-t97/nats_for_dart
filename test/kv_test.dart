/// Integration tests for KeyValue store operations.
///
/// Requires a running `nats-server -js` on localhost:4222.
library;

import 'dart:async';

import 'package:nats_ffi_experiment/nats_ffi_experiment.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    NatsLibrary.init();
  });

  tearDownAll(() {
    NatsLibrary.close(timeoutMs: 5000);
  });

  group('KeyValue CRUD', () {
    late NatsClient client;
    late JetStreamContext js;
    late KeyValueStore kv;

    setUp(() {
      client = NatsClient.connect('nats://localhost:4222');
      js = client.jetStream();
      kv = js.createKeyValue(KvConfig(
        bucket: 'test-kv',
        history: 5,
        storageType: jsStorageType.js_MemoryStorage,
      ));
    });

    tearDown(() {
      kv.close();
      try {
        js.deleteKeyValue('test-kv');
      } catch (_) {}
      js.close();
      return client.close();
    });

    test('put and get', () {
      final rev = kv.putString('key1', 'value1');
      expect(rev, greaterThan(0));

      final entry = kv.get('key1');
      expect(entry, isNotNull);
      expect(entry!.key, equals('key1'));
      expect(entry.valueAsString, equals('value1'));
      expect(entry.revision, equals(rev));
      expect(entry.operation, equals(kvOperation.kvOp_Put));
    });

    test('get returns null for non-existent key', () {
      final entry = kv.get('nonexistent');
      expect(entry, isNull);
    });

    test('create succeeds for new key', () {
      final rev = kv.createString('unique-key', 'first');
      expect(rev, greaterThan(0));

      final entry = kv.get('unique-key');
      expect(entry!.valueAsString, equals('first'));
    });

    test('create fails for existing key', () {
      kv.putString('exists', 'value');
      expect(
        () => kv.createString('exists', 'duplicate'),
        throwsA(isA<NatsException>()),
      );
    });

    test('update with correct revision succeeds', () {
      final rev1 = kv.putString('versioned', 'v1');
      final rev2 = kv.updateString('versioned', 'v2', rev1);
      expect(rev2, greaterThan(rev1));

      final entry = kv.get('versioned');
      expect(entry!.valueAsString, equals('v2'));
      expect(entry.revision, equals(rev2));
    });

    test('update with wrong revision fails', () {
      kv.putString('versioned', 'v1');
      expect(
        () => kv.updateString('versioned', 'v2', 999),
        throwsA(isA<NatsException>()),
      );
    });

    test('delete adds a delete marker', () {
      kv.putString('to-delete', 'value');
      kv.delete('to-delete');

      // After delete, get returns null (key is "deleted")
      final entry = kv.get('to-delete');
      expect(entry, isNull);
    });

    test('purge removes all revisions', () {
      kv.putString('to-purge', 'v1');
      kv.putString('to-purge', 'v2');
      kv.purge('to-purge');

      final entry = kv.get('to-purge');
      expect(entry, isNull);
    });
  });

  group('KeyValue list operations', () {
    late NatsClient client;
    late JetStreamContext js;
    late KeyValueStore kv;

    setUp(() {
      client = NatsClient.connect('nats://localhost:4222');
      js = client.jetStream();
      kv = js.createKeyValue(KvConfig(
        bucket: 'test-kv-list',
        history: 5,
        storageType: jsStorageType.js_MemoryStorage,
      ));
    });

    tearDown(() {
      kv.close();
      try {
        js.deleteKeyValue('test-kv-list');
      } catch (_) {}
      js.close();
      return client.close();
    });

    test('keys returns all active keys', () {
      kv.putString('a', '1');
      kv.putString('b', '2');
      kv.putString('c', '3');

      final allKeys = kv.keys();
      expect(allKeys, containsAll(['a', 'b', 'c']));
      expect(allKeys.length, equals(3));
    });

    test('history returns revisions', () {
      kv.putString('tracked', 'first');
      kv.putString('tracked', 'second');
      kv.putString('tracked', 'third');

      final revisions = kv.history('tracked');
      expect(revisions.length, equals(3));

      // History contains all versions
      final values = revisions.map((e) => e.valueAsString).toList();
      expect(values, contains('first'));
      expect(values, contains('second'));
      expect(values, contains('third'));
    });
  });

  group('KeyValue watch', () {
    late NatsClient client;
    late JetStreamContext js;
    late KeyValueStore kv;

    setUp(() {
      client = NatsClient.connect('nats://localhost:4222');
      js = client.jetStream();
      kv = js.createKeyValue(KvConfig(
        bucket: 'test-kv-watch',
        history: 5,
        storageType: jsStorageType.js_MemoryStorage,
      ));
    });

    tearDown(() {
      kv.close();
      try {
        js.deleteKeyValue('test-kv-watch');
      } catch (_) {}
      js.close();
      return client.close();
    });

    test('watch delivers updates', () async {
      // Put an initial value
      kv.putString('watched', 'initial');

      final watchStream = kv.watch('watched');
      final received = <KvEntry>[];
      final completer = Completer<void>();

      final subscription = watchStream.listen((entry) {
        received.add(entry);
        if (received.length >= 2) {
          completer.complete();
        }
      });

      // Give watcher time to start and deliver initial value
      await Future.delayed(Duration(milliseconds: 200));

      // Put an update to trigger the watcher
      kv.putString('watched', 'updated');

      await completer.future.timeout(Duration(seconds: 5));
      await subscription.cancel();

      expect(received.length, greaterThanOrEqualTo(2));
      // Should see initial and updated values
      final values = received.map((e) => e.valueAsString).toList();
      expect(values, contains('initial'));
      expect(values, contains('updated'));
    });

    test('watchAll delivers updates for all keys', () async {
      final watchStream = kv.watchAll();
      final received = <KvEntry>[];
      final completer = Completer<void>();

      final subscription = watchStream.listen((entry) {
        received.add(entry);
        if (received.length >= 2) {
          completer.complete();
        }
      });

      // Give watcher time to start
      await Future.delayed(Duration(milliseconds: 200));

      kv.putString('key1', 'val1');
      kv.putString('key2', 'val2');

      await completer.future.timeout(Duration(seconds: 5));
      await subscription.cancel();

      expect(received.length, greaterThanOrEqualTo(2));
      final keys = received.map((e) => e.key).toSet();
      expect(keys, containsAll(['key1', 'key2']));
    });
  });
}
