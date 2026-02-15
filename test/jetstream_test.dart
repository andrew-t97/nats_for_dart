/// Integration tests for JetStream publish/subscribe and stream/consumer
/// management.
///
/// Requires a running `nats-server -js` on localhost:4222.
library;

import 'dart:async';

import 'package:nats_for_dart/nats_for_dart.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    NatsLibrary.init();
  });

  tearDownAll(() {
    NatsLibrary.close(timeoutMs: 5000);
  });

  group('JetStream publish and pull subscribe', () {
    late NatsClient client;
    late JetStreamContext js;

    setUp(() {
      client = NatsClient.connect('nats://localhost:4222');
      js = client.jetStream();
    });

    tearDown(() {
      // Clean up stream silently in case test created one
      try {
        js.deleteStream('TEST_JS');
      } catch (_) {}
      js.close();
      return client.close();
    });

    test('publish returns valid pub ack with sequence', () {
      js.addStream(JsStreamConfig(
        name: 'TEST_JS',
        subjects: ['test.js.>'],
        storage: jsStorageType.js_MemoryStorage,
      ));

      final ack1 = js.publishString('test.js.hello', 'msg1');
      expect(ack1.stream, equals('TEST_JS'));
      expect(ack1.sequence, equals(1));
      expect(ack1.duplicate, isFalse);

      final ack2 = js.publishString('test.js.hello', 'msg2');
      expect(ack2.sequence, equals(2));
    });

    test('pull subscribe fetches messages', () {
      js.addStream(JsStreamConfig(
        name: 'TEST_JS',
        subjects: ['test.js.>'],
        storage: jsStorageType.js_MemoryStorage,
      ));

      for (var i = 1; i <= 5; i++) {
        js.publishString('test.js.pull', 'message $i');
      }

      final pullSub = js.pullSubscribe('test.js.pull', 'test-puller');
      addTearDown(pullSub.close);

      final messages = pullSub.fetch(5, timeout: Duration(seconds: 5));
      expect(messages.length, equals(5));

      for (var i = 0; i < messages.length; i++) {
        expect(messages[i].dataAsString, equals('message ${i + 1}'));
        messages[i].ack();
      }
    });

    test('nak causes redelivery', () {
      js.addStream(JsStreamConfig(
        name: 'TEST_JS',
        subjects: ['test.js.>'],
        storage: jsStorageType.js_MemoryStorage,
      ));

      js.publishString('test.js.nak', 'retry-me');

      final pullSub = js.pullSubscribe('test.js.nak', 'test-naker');
      addTearDown(pullSub.close);

      // First fetch — nak the message
      final firstFetch = pullSub.fetch(1, timeout: Duration(seconds: 5));
      expect(firstFetch.length, equals(1));
      expect(firstFetch[0].dataAsString, equals('retry-me'));
      firstFetch[0].nak();

      // Second fetch — message should be redelivered
      final secondFetch = pullSub.fetch(1, timeout: Duration(seconds: 5));
      expect(secondFetch.length, equals(1));
      expect(secondFetch[0].dataAsString, equals('retry-me'));

      final meta = secondFetch[0].metadata();
      expect(meta.numDelivered, greaterThan(1));
      secondFetch[0].ack();
    });

    test('sync subscribe receives messages', () {
      js.addStream(JsStreamConfig(
        name: 'TEST_JS',
        subjects: ['test.js.>'],
        storage: jsStorageType.js_MemoryStorage,
      ));

      js.publishString('test.js.sync', 'sync-msg');

      final syncSub = js.subscribeSync('test.js.sync');
      addTearDown(syncSub.close);

      final msg = syncSub.nextMessage(timeout: Duration(seconds: 5));
      expect(msg.dataAsString, equals('sync-msg'));
      msg.ack();
    });

    test('async subscribe receives messages via stream', () async {
      js.addStream(JsStreamConfig(
        name: 'TEST_JS',
        subjects: ['test.js.>'],
        storage: jsStorageType.js_MemoryStorage,
      ));

      final asyncSub = js.subscribe('test.js.async');
      addTearDown(() => asyncSub.close());

      // Publish after a short delay to ensure subscription is active
      Future.delayed(Duration(milliseconds: 100), () {
        js.publishString('test.js.async', 'async-msg');
      });

      final msg = await asyncSub.messages.first
          .timeout(Duration(seconds: 5));
      expect(msg.dataAsString, equals('async-msg'));
      msg.ack();
    });

    test('message metadata is correct', () {
      js.addStream(JsStreamConfig(
        name: 'TEST_JS',
        subjects: ['test.js.>'],
        storage: jsStorageType.js_MemoryStorage,
      ));

      js.publishString('test.js.meta', 'with-metadata');

      final pullSub = js.pullSubscribe('test.js.meta', 'test-meta');
      addTearDown(pullSub.close);

      final messages = pullSub.fetch(1, timeout: Duration(seconds: 5));
      expect(messages.length, equals(1));

      final meta = messages[0].metadata();
      expect(meta.stream, equals('TEST_JS'));
      expect(meta.streamSequence, equals(1));
      expect(meta.numDelivered, equals(1));
      expect(meta.timestamp, greaterThan(0));

      messages[0].ack();
    });
  });

  group('Stream management', () {
    late NatsClient client;
    late JetStreamContext js;

    setUp(() {
      client = NatsClient.connect('nats://localhost:4222');
      js = client.jetStream();
    });

    tearDown(() {
      try {
        js.deleteStream('MGMT_TEST');
      } catch (_) {}
      js.close();
      return client.close();
    });

    test('create, info, and delete stream', () {
      final created = js.addStream(JsStreamConfig(
        name: 'MGMT_TEST',
        subjects: ['mgmt.>'],
        storage: jsStorageType.js_MemoryStorage,
        replicas: 1,
      ));
      expect(created.name, equals('MGMT_TEST'));
      expect(created.messages, equals(0));

      // Publish a message and check info
      js.publishString('mgmt.test', 'hello');
      final info = js.getStreamInfo('MGMT_TEST');
      expect(info.messages, equals(1));
      expect(info.lastSeq, equals(1));

      // Delete
      js.deleteStream('MGMT_TEST');

      // Verify deleted
      expect(
        () => js.getStreamInfo('MGMT_TEST'),
        throwsA(isA<NatsException>()),
      );
    });

    test('purge stream removes messages', () {
      js.addStream(JsStreamConfig(
        name: 'MGMT_TEST',
        subjects: ['mgmt.>'],
        storage: jsStorageType.js_MemoryStorage,
      ));

      for (var i = 0; i < 10; i++) {
        js.publishString('mgmt.purge', 'msg-$i');
      }

      var info = js.getStreamInfo('MGMT_TEST');
      expect(info.messages, equals(10));

      js.purgeStream('MGMT_TEST');

      info = js.getStreamInfo('MGMT_TEST');
      expect(info.messages, equals(0));
    });
  });

  group('Auto-destroy after terminal ack', () {
    late NatsClient client;
    late JetStreamContext js;

    setUp(() {
      client = NatsClient.connect('nats://localhost:4222');
      js = client.jetStream();
      js.addStream(JsStreamConfig(
        name: 'TEST_JS',
        subjects: ['test.js.>'],
        storage: jsStorageType.js_MemoryStorage,
      ));
    });

    tearDown(() {
      try {
        js.deleteStream('TEST_JS');
      } catch (_) {}
      js.close();
      return client.close();
    });

    /// Publishes [payload] to [subject], creates a pull consumer, fetches one
    /// message, and registers tearDown for the subscription.
    JsMessage publishAndFetchOne(
      JetStreamContext js,
      String subject,
      String consumerName,
      String payload,
    ) {
      js.publishString(subject, payload);
      final pullSub = js.pullSubscribe(subject, consumerName);
      addTearDown(pullSub.close);
      final messages = pullSub.fetch(1, timeout: Duration(seconds: 5));
      expect(messages, hasLength(1));
      return messages[0];
    }

    final terminalOps = <String, void Function(JsMessage)>{
      'ack': (msg) => msg.ack(),
      'ackSync': (msg) => msg.ackSync(),
      'nak': (msg) => msg.nak(),
      'term': (msg) => msg.term(),
    };

    for (final MapEntry(key: name, value: terminalAck)
        in terminalOps.entries) {
      test('$name auto-destroys and prevents further ack operations', () {
        final msg = publishAndFetchOne(
            js, 'test.js.auto', 'auto-$name', 'payload');
        terminalAck(msg);
        expect(() => msg.ack(), throwsStateError);
      });

      test('data fields and metadata accessible after $name', () {
        final msg = publishAndFetchOne(
            js, 'test.js.auto', 'data-$name', 'test-data');
        terminalAck(msg);
        expect(msg.dataAsString, equals('test-data'));
        expect(msg.subject, equals('test.js.auto'));
        expect(msg.metadata().stream, equals('TEST_JS'));
      });
    }

    test('inProgress does NOT auto-destroy — can still ack after', () {
      final msg = publishAndFetchOne(
          js, 'test.js.auto', 'auto-progress', 'in-progress');
      msg.inProgress();
      msg.ack(); // should not throw
    });

    test('metadata returns cached instance across calls', () {
      final msg = publishAndFetchOne(
          js, 'test.js.auto', 'meta-cache', 'cache-test');
      final meta1 = msg.metadata();
      final meta2 = msg.metadata();
      expect(meta1, same(meta2));
      msg.ack();
      expect(msg.metadata(), same(meta1));
    });
  });

  group('Consumer management', () {
    late NatsClient client;
    late JetStreamContext js;

    setUp(() {
      client = NatsClient.connect('nats://localhost:4222');
      js = client.jetStream();
      js.addStream(JsStreamConfig(
        name: 'MGMT_TEST',
        subjects: ['consumer.>'],
        storage: jsStorageType.js_MemoryStorage,
      ));
    });

    tearDown(() {
      try {
        js.deleteStream('MGMT_TEST');
      } catch (_) {}
      js.close();
      return client.close();
    });

    test('add, info, and delete consumer', () {
      final created = js.addConsumer(
        'MGMT_TEST',
        JsConsumerConfig(durable: 'test-consumer'),
      );
      expect(created.name, equals('test-consumer'));
      expect(created.stream, equals('MGMT_TEST'));

      final info = js.getConsumerInfo('MGMT_TEST', 'test-consumer');
      expect(info.name, equals('test-consumer'));

      js.deleteConsumer('MGMT_TEST', 'test-consumer');

      expect(
        () => js.getConsumerInfo('MGMT_TEST', 'test-consumer'),
        throwsA(isA<NatsException>()),
      );
    });
  });
}
