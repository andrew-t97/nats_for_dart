/// Integration tests for KeyValue store operations.
///
/// Requires a running `nats-server -js` on localhost:4222.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:nats_for_dart/nats_for_dart.dart';
import 'package:test/test.dart';

/// Encodes a string to bytes for use in raw-bytes KV API tests.
Uint8List toBytes(String s) => Uint8List.fromList(utf8.encode(s));

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

  group('KeyValue bytes CRUD', () {
    late NatsClient client;
    late JetStreamContext js;
    late KeyValueStore kv;

    setUp(() {
      client = NatsClient.connect('nats://localhost:4222');
      js = client.jetStream();
      kv = js.createKeyValue(KvConfig(
        bucket: 'test-kv-bytes',
        history: 5,
        storageType: jsStorageType.js_MemoryStorage,
      ));
    });

    tearDown(() {
      kv.close();
      try {
        js.deleteKeyValue('test-kv-bytes');
      } catch (_) {}
      js.close();
      return client.close();
    });

    final bytesCrudOps =
        <String, int Function(KeyValueStore kv, String key, Uint8List value)>{
      'put': (kv, key, value) => kv.put(key, value),
      'create': (kv, key, value) => kv.create(key, value),
    };

    for (final MapEntry(key: opName, value: writeOp)
        in bytesCrudOps.entries) {
      test('$opName writes and reads back raw bytes', () {
        final data = toBytes('bytes-$opName');
        final rev = writeOp(kv, 'key-$opName', data);
        expect(rev, greaterThan(0));

        final entry = kv.get('key-$opName');
        expect(entry, isNotNull);
        expect(entry!.value, equals(data));
      });
    }

    test('update with raw bytes and correct revision succeeds', () {
      final initial = toBytes('initial');
      final rev1 = kv.put('update-bytes', initial);

      final updated = toBytes('updated');
      final rev2 = kv.update('update-bytes', updated, rev1);
      expect(rev2, greaterThan(rev1));

      final entry = kv.get('update-bytes');
      expect(entry!.value, equals(updated));
    });

    test('update with stale revision throws', () {
      kv.put('stale-rev', toBytes('v1'));
      expect(
        () => kv.update('stale-rev', toBytes('v2'), 999),
        throwsA(isA<NatsException>()),
      );
    });

    test('put and get zero-length value', () {
      final rev = kv.put('empty-val', Uint8List(0));
      expect(rev, greaterThan(0));

      final entry = kv.get('empty-val');
      expect(entry, isNotNull);
      expect(entry!.value, equals(Uint8List(0)));
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

  group('KeyValueStore.open and keyValue extension', () {
    late NatsClient client;
    late JetStreamContext js;

    setUp(() {
      client = NatsClient.connect('nats://localhost:4222');
      js = client.jetStream();
    });

    tearDown(() {
      try {
        js.deleteKeyValue('test-kv-open');
      } catch (_) {}
      js.close();
      return client.close();
    });

    test('open re-opens existing bucket and reads back data', () {
      final kv1 = js.createKeyValue(KvConfig(
        bucket: 'test-kv-open',
        storageType: jsStorageType.js_MemoryStorage,
      ));
      kv1.putString('survive', 'reopened');
      kv1.close();

      final kv2 = js.keyValue('test-kv-open');
      final entry = kv2.get('survive');
      expect(entry, isNotNull);
      expect(entry!.valueAsString, equals('reopened'));
      kv2.close();
    });

    test('bucket getter returns correct bucket name', () {
      final kv = js.createKeyValue(KvConfig(
        bucket: 'test-kv-open',
        storageType: jsStorageType.js_MemoryStorage,
      ));
      expect(kv.bucket, equals('test-kv-open'));
      kv.close();
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

  group('KvEntry.toString', () {
    late NatsClient client;
    late JetStreamContext js;
    late KeyValueStore kv;

    setUp(() {
      client = NatsClient.connect('nats://localhost:4222');
      js = client.jetStream();
      kv = js.createKeyValue(KvConfig(
        bucket: 'test-kv-tostring',
        storageType: jsStorageType.js_MemoryStorage,
      ));
    });

    tearDown(() {
      kv.close();
      try {
        js.deleteKeyValue('test-kv-tostring');
      } catch (_) {}
      js.close();
      return client.close();
    });

    test('returns a non-empty descriptive string', () {
      kv.putString('ts-key', 'ts-val');
      final entry = kv.get('ts-key');
      final str = entry!.toString();
      expect(
        str,
        equals(
          'KvEntry(key: ts-key, revision: 1, '
          'operation: kvOp_Put, value: ts-val)',
        ),
      );
    });
  });

  group('KvConfig optional fields', () {
    late NatsClient client;
    late JetStreamContext js;

    setUp(() {
      client = NatsClient.connect('nats://localhost:4222');
      js = client.jetStream();
    });

    tearDown(() {
      try {
        js.deleteKeyValue('test-kv-cfg');
      } catch (_) {}
      js.close();
      return client.close();
    });

    test('creates bucket with description, maxValueSize, ttl, maxBytes', () {
      final kv = js.createKeyValue(KvConfig(
        bucket: 'test-kv-cfg',
        description: 'A test bucket',
        maxValueSize: 1024,
        ttl: Duration(hours: 1),
        maxBytes: 1024 * 1024,
        storageType: jsStorageType.js_MemoryStorage,
      ));

      // Verify the bucket is functional
      final rev = kv.putString('cfg-key', 'cfg-val');
      expect(rev, greaterThan(0));

      final entry = kv.get('cfg-key');
      expect(entry!.valueAsString, equals('cfg-val'));
      kv.close();
    });
  });
}
