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

  group('Stream config options', () {
    late NatsClient client;
    late JetStreamContext js;

    setUp(() {
      client = NatsClient.connect('nats://localhost:4222');
      js = client.jetStream();
    });

    tearDown(() {
      for (final name in ['CFG_DESC', 'CFG_MAXAGE', 'CFG_UPDATE']) {
        try {
          js.deleteStream(name);
        } catch (_) {}
      }
      js.close();
      return client.close();
    });

    final streamConfigCases =
        <String, ({JsStreamConfig config, void Function(JsStreamInfoResult) verify})>{
      'with description': (
        config: JsStreamConfig(
          name: 'CFG_DESC',
          subjects: ['cfg.desc.>'],
          storage: jsStorageType.js_MemoryStorage,
          description: 'A test stream with description',
        ),
        verify: (info) => expect(info.name, equals('CFG_DESC')),
      ),
      'with maxAge': (
        config: JsStreamConfig(
          name: 'CFG_MAXAGE',
          subjects: ['cfg.maxage.>'],
          storage: jsStorageType.js_MemoryStorage,
          maxAge: Duration(hours: 1),
        ),
        verify: (info) => expect(info.name, equals('CFG_MAXAGE')),
      ),
    };

    for (final MapEntry(key: label, value: tc) in streamConfigCases.entries) {
      test('addStream $label', () {
        final info = js.addStream(tc.config);
        tc.verify(info);
      });
    }

    test('updateStream changes stream config', () {
      js.addStream(JsStreamConfig(
        name: 'CFG_UPDATE',
        subjects: ['cfg.update.>'],
        storage: jsStorageType.js_MemoryStorage,
      ));

      final updated = js.updateStream(JsStreamConfig(
        name: 'CFG_UPDATE',
        subjects: ['cfg.update.>'],
        storage: jsStorageType.js_MemoryStorage,
        description: 'Updated description',
        maxAge: Duration(hours: 2),
      ));
      expect(updated.name, equals('CFG_UPDATE'));
    });
  });

  group('Consumer config options', () {
    late NatsClient client;
    late JetStreamContext js;

    setUp(() {
      client = NatsClient.connect('nats://localhost:4222');
      js = client.jetStream();
      js.addStream(JsStreamConfig(
        name: 'CONS_CFG',
        subjects: ['cons.cfg.>'],
        storage: jsStorageType.js_MemoryStorage,
      ));
    });

    tearDown(() {
      try {
        js.deleteStream('CONS_CFG');
      } catch (_) {}
      js.close();
      return client.close();
    });

    final consumerConfigCases = <String, JsConsumerConfig>{
      'with name and description': JsConsumerConfig(
        durable: 'named-consumer',
        name: 'named-consumer',
        description: 'Test consumer with description',
      ),
      'with filterSubject and maxDeliver': JsConsumerConfig(
        durable: 'filter-consumer',
        filterSubject: 'cons.cfg.>',
        maxDeliver: 3,
      ),
      'with ackWait and maxAckPending': JsConsumerConfig(
        durable: 'ackwait-consumer',
        ackWait: Duration(seconds: 30),
        maxAckPending: 100,
      ),
    };

    for (final MapEntry(key: label, value: config)
        in consumerConfigCases.entries) {
      test('addConsumer $label', () {
        final info = js.addConsumer('CONS_CFG', config);
        expect(info.stream, equals('CONS_CFG'));
        expect(info.name, isNotEmpty);
      });
    }
  });

  group('Subscription with explicit stream/durable params', () {
    late NatsClient client;
    late JetStreamContext js;

    setUp(() {
      client = NatsClient.connect('nats://localhost:4222');
      js = client.jetStream();
      js.addStream(JsStreamConfig(
        name: 'SUB_PARAMS',
        subjects: ['sub.params.>'],
        storage: jsStorageType.js_MemoryStorage,
      ));
    });

    tearDown(() {
      try {
        js.deleteStream('SUB_PARAMS');
      } catch (_) {}
      js.close();
      return client.close();
    });

    test('pullSubscribe with explicit stream param', () {
      js.publishString('sub.params.pull', 'pull-msg');

      final pullSub = js.pullSubscribe(
        'sub.params.pull',
        'pull-stream-param',
        stream: 'SUB_PARAMS',
      );
      addTearDown(pullSub.close);

      final messages = pullSub.fetch(1, timeout: Duration(seconds: 5));
      expect(messages, hasLength(1));
      expect(messages[0].dataAsString, equals('pull-msg'));
      messages[0].ack();
    });

    test('subscribeSync with explicit stream and durable params', () {
      js.publishString('sub.params.sync', 'sync-msg');

      final syncSub = js.subscribeSync(
        'sub.params.sync',
        stream: 'SUB_PARAMS',
        durable: 'sync-durable',
      );
      addTearDown(syncSub.close);

      final msg = syncSub.nextMessage(timeout: Duration(seconds: 5));
      expect(msg.dataAsString, equals('sync-msg'));
      msg.ack();
    });

    test('async subscribe with explicit stream and durable params', () async {
      final asyncSub = js.subscribe(
        'sub.params.async',
        stream: 'SUB_PARAMS',
        durable: 'async-durable',
      );
      addTearDown(() => asyncSub.close());

      Future.delayed(Duration(milliseconds: 100), () {
        js.publishString('sub.params.async', 'async-msg');
      });

      final msg = await asyncSub.messages.first
          .timeout(Duration(seconds: 5));
      expect(msg.dataAsString, equals('async-msg'));
      msg.ack();
    });
  });

  group('JetStream toString()', () {
    late NatsClient client;
    late JetStreamContext js;

    setUp(() {
      client = NatsClient.connect('nats://localhost:4222');
      js = client.jetStream();
    });

    tearDown(() {
      try {
        js.deleteStream('TOSTR_TEST');
      } catch (_) {}
      js.close();
      return client.close();
    });

    test('JsStreamInfoResult.toString() matches expected format', () {
      final info = js.addStream(JsStreamConfig(
        name: 'TOSTR_TEST',
        subjects: ['tostr.>'],
        storage: jsStorageType.js_MemoryStorage,
      ));
      expect(
        info.toString(),
        equals('JsStreamInfoResult(name: TOSTR_TEST, messages: 0, '
            'firstSeq: 0, lastSeq: 0)'),
      );
    });

    test('JsConsumerInfoResult.toString() matches expected format', () {
      js.addStream(JsStreamConfig(
        name: 'TOSTR_TEST',
        subjects: ['tostr.>'],
        storage: jsStorageType.js_MemoryStorage,
      ));
      final consumerInfo = js.addConsumer(
        'TOSTR_TEST',
        JsConsumerConfig(durable: 'tostr-consumer'),
      );
      expect(
        consumerInfo.toString(),
        equals('JsConsumerInfoResult(stream: TOSTR_TEST, name: tostr-consumer, '
            'pending: 0, ackPending: 0)'),
      );
    });
  });
}
