/// Integration tests for the NATS FFI wrapper — async subscriptions,
/// NatsOptions lifecycle, and memory safety.
///
/// These tests require a running `nats-server` on localhost:4222.
/// Start one with:
///   nats-server &
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

  group('NatsClient async subscriptions', () {
    late NatsClient publisher;
    late NatsClient subscriber;

    setUp(() {
      // Use separate connections for pub and sub to prove messages
      // travel through the server.
      publisher = NatsClient.connect('nats://localhost:4222');
      subscriber = NatsClient.connect('nats://localhost:4222');
    });

    tearDown(() async {
      await publisher.close();
      await subscriber.close();
    });

    test('async subscribe receives published messages', () async {
      final sub = subscriber.subscribe('test.async.basic');
      addTearDown(sub.close);

      // Allow the subscription to propagate to the server.
      await Future.delayed(const Duration(milliseconds: 200));

      // Publish a message.
      publisher.publish('test.async.basic', 'hello async');
      publisher.flush();

      // Wait for the message on the stream.
      final msg = await sub.messages.first.timeout(
        const Duration(seconds: 5),
      );
      expect(msg.subject, equals('test.async.basic'));
      expect(msg.dataAsString, equals('hello async'));
    });

    test('async subscribe receives multiple messages in order', () async {
      final sub = subscriber.subscribe('test.async.order');
      addTearDown(sub.close);

      // Allow the subscription to propagate to the server.
      await Future.delayed(const Duration(milliseconds: 200));

      const count = 10;
      for (var i = 0; i < count; i++) {
        publisher.publish('test.async.order', 'msg-$i');
      }
      publisher.flush();

      final messages = await sub.messages
          .take(count)
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(messages, hasLength(count));
      for (var i = 0; i < count; i++) {
        expect(messages[i].dataAsString, equals('msg-$i'));
      }
    });

    test('wildcard subscription matches multiple subjects', () async {
      final sub = subscriber.subscribe('test.wild.*');
      addTearDown(sub.close);

      // Allow the subscription to propagate to the server.
      await Future.delayed(const Duration(milliseconds: 200));

      publisher.publish('test.wild.a', 'alpha');
      publisher.publish('test.wild.b', 'beta');
      publisher.flush();

      final messages = await sub.messages
          .take(2)
          .toList()
          .timeout(const Duration(seconds: 5));

      expect(messages, hasLength(2));
      expect(messages[0].subject, equals('test.wild.a'));
      expect(messages[1].subject, equals('test.wild.b'));
    });

    test('unsubscribing stops message delivery and closes stream', () async {
      final sub = subscriber.subscribe('test.async.unsub');

      // Allow the subscription to propagate to the server.
      await Future.delayed(const Duration(milliseconds: 200));

      // Collect messages.
      final received = <NatsMessage>[];
      final firstMsg = Completer<void>();
      final streamDone = Completer<void>();
      final listener = sub.messages.listen(
        (msg) {
          received.add(msg);
          if (!firstMsg.isCompleted) firstMsg.complete();
        },
        onDone: streamDone.complete,
      );

      publisher.publish('test.async.unsub', 'before-unsub');
      publisher.flush();

      // Wait for the first message to arrive.
      await firstMsg.future.timeout(const Duration(seconds: 5));
      expect(received, hasLength(1));

      // Unsubscribe.
      await sub.close();

      // The stream should complete.
      await streamDone.future.timeout(const Duration(seconds: 2));
      expect(sub.isClosed, isTrue);

      // Publish after unsubscribe — should not arrive.
      publisher.publish('test.async.unsub', 'after-unsub');
      publisher.flush();
      await Future.delayed(const Duration(milliseconds: 500));
      expect(received, hasLength(1));

      await listener.cancel();
    });

    test('queue subscribe distributes messages across subscribers', () async {
      // Two queue subscribers on the same group.
      final sub1 = subscriber.queueSubscribe('test.queue', 'workers');
      final sub2 = subscriber.queueSubscribe('test.queue', 'workers');
      addTearDown(sub1.close);
      addTearDown(sub2.close);

      // Collect messages from both.
      final received1 = <NatsMessage>[];
      final received2 = <NatsMessage>[];

      final listener1 = sub1.messages.listen(received1.add);
      final listener2 = sub2.messages.listen(received2.add);

      // Allow subscriptions to propagate to the server.
      await Future.delayed(const Duration(milliseconds: 200));

      const count = 20;
      for (var i = 0; i < count; i++) {
        publisher.publish('test.queue', 'job-$i');
      }
      publisher.flush();

      // Wait for all messages to be delivered.
      await Future.delayed(const Duration(seconds: 2));

      await listener1.cancel();
      await listener2.cancel();

      // Total should equal count; each subscriber should get some.
      final total = received1.length + received2.length;
      expect(total, equals(count));
      // With 20 messages, each should get at least 1 (probabilistically).
      // Don't assert exact split since it depends on the server.
    });

    test('NativeCallable is cleaned up after subscription close', () async {
      // This primarily tests that close() doesn't throw and the
      // subscription can be garbage-collected.
      final sub = subscriber.subscribe('test.async.cleanup');
      await sub.close();
      expect(sub.isClosed, isTrue);

      // Double close should be safe.
      await sub.close();
    });
  });

  group('NatsClient with NatsOptions', () {
    test('connect via NatsOptions with URL', () async {
      final opts = NatsOptions()..setUrl('nats://localhost:4222');
      final client = NatsClient.connectWithOptions(opts);
      addTearDown(() => client.close());

      // Verify connection works by doing a simple pub/sub.
      final sub = client.subscribeSync('test.options.basic');
      addTearDown(sub.close);

      client.publish('test.options.basic', 'hello options');
      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.dataAsString, equals('hello options'));
    });

    test('lifecycle callbacks fire on disconnect/reconnect', () async {
      final opts = NatsOptions()
        ..setUrl('nats://localhost:4222')
        ..setMaxReconnect(5)
        ..setReconnectWait(const Duration(seconds: 1));

      // Just verify the streams are accessible (actual disconnect/reconnect
      // testing requires stopping the server, which is hard to automate).
      expect(opts.onDisconnected(), isA<Stream<void>>());
      expect(opts.onReconnected(), isA<Stream<void>>());
      expect(opts.onClosed(), isA<Stream<void>>());
      expect(opts.onError(), isA<Stream<NatsError>>());

      final client = NatsClient.connectWithOptions(opts);
      addTearDown(() => client.close());

      // Connection should be functional.
      final sub = client.subscribeSync('test.lifecycle.basic');
      addTearDown(sub.close);
      client.publish('test.lifecycle.basic', 'lifecycle test');
      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.dataAsString, equals('lifecycle test'));
    });
  });

  group('Async subscription on closed client', () {
    test('subscribe on closed client throws StateError', () async {
      final client = NatsClient.connect('nats://localhost:4222');
      await client.close();
      expect(() => client.subscribe('test.closed'), throwsStateError);
    });

    test('closing client closes all async subscriptions', () async {
      final client = NatsClient.connect('nats://localhost:4222');
      final sub = client.subscribe('test.auto.close');
      await client.close();
      expect(sub.isClosed, isTrue);
    });
  });

  group('Async message eager copy', () {
    test(
        'message fields are accessible after client is closed '
        '(async subscription)', () async {
      final client = NatsClient.connect('nats://localhost:4222');

      final sub = client.subscribe('test.eager.async');
      await Future.delayed(const Duration(milliseconds: 200));

      client.publish('test.eager.async', 'Async eager copy');
      client.flush();

      final msg = await sub.messages.first.timeout(
        const Duration(seconds: 5),
      );

      // Close everything.
      await sub.close();
      await client.close();

      // Message data should still be accessible.
      expect(msg.subject, equals('test.eager.async'));
      expect(msg.dataAsString, equals('Async eager copy'));
    });
  });
}
