/// Integration tests for NATS request-reply (Phase 5).
///
/// These tests require a running `nats-server` on localhost:4222.
/// Start one with:
///   nats-server &
library;

import 'dart:typed_data';

import 'package:nats_for_dart/nats_for_dart.dart';
import 'package:nats_for_dart/src/nats_async_subscription.dart';
import 'package:test/test.dart';

void main() {
  setUpAll(() {
    NatsLibrary.init();
  });

  tearDownAll(() {
    resetAsyncSubscriptionRoutingForTesting();
    NatsOptions.resetRoutingTablesForTesting();
    NatsLibrary.close(timeoutMs: 5000);
  });

  group('Request-Reply', () {
    late NatsClient requester;
    late NatsClient responder;

    setUp(() {
      requester = NatsClient.connect('nats://localhost:4222');
      responder = NatsClient.connect('nats://localhost:4222');
    });

    tearDown(() async {
      await requester.close();
      await responder.close();
    });

    test('basic string request-reply', () async {
      final subject = 'test.reqrep.string.${DateTime.now().millisecondsSinceEpoch}';

      // Set up the responder: subscribe, read request, reply to replyTo.
      final sub = responder.subscribe(subject);
      sub.messages.listen((msg) {
        responder.publish(msg.replyTo!, 'reply: ${msg.dataAsString}');
      });
      // Flush ensures the subscription is registered on the server
      // before the requester publishes.
      responder.flush();

      // Send request and verify response.
      final reply = await requester.request(subject, 'hello');
      expect(reply.dataAsString, equals('reply: hello'));

      await sub.close();
    });

    test('basic bytes request-reply', () async {
      final subject = 'test.reqrep.bytes.${DateTime.now().millisecondsSinceEpoch}';

      final sub = responder.subscribe(subject);
      sub.messages.listen((msg) {
        // Echo the bytes back reversed.
        final reversed = Uint8List.fromList(msg.data.reversed.toList());
        responder.publishBytes(msg.replyTo!, reversed);
      });
      responder.flush();

      final requestData = Uint8List.fromList([1, 2, 3, 4, 5]);
      final reply = await requester.requestBytes(subject, requestData);
      expect(reply.data, equals(Uint8List.fromList([5, 4, 3, 2, 1])));

      await sub.close();
    });

    test('no responders detection', () async {
      final subject = 'test.reqrep.noresp.${DateTime.now().millisecondsSinceEpoch}';

      // No subscriber on this subject — NATS 2.2+ returns 503 immediately
      // instead of waiting for a timeout.
      expect(
        () => requester.request(subject, 'hello'),
        throwsA(isA<NatsNoRespondersException>()),
      );
    });

    test('respond convenience method', () async {
      final subject = 'test.reqrep.respond.${DateTime.now().millisecondsSinceEpoch}';

      // Use the respond() convenience method instead of manual publish.
      final sub = responder.subscribe(subject);
      sub.messages.listen((msg) {
        responder.respond(msg, 'pong');
      });
      responder.flush();

      final reply = await requester.request(subject, 'ping');
      expect(reply.dataAsString, equals('pong'));

      await sub.close();
    });

    test('respondBytes convenience method', () async {
      final subject = 'test.reqrep.respondbytes.${DateTime.now().millisecondsSinceEpoch}';

      final sub = responder.subscribe(subject);
      sub.messages.listen((msg) {
        responder.respondBytes(msg, Uint8List.fromList([0xDE, 0xAD]));
      });
      responder.flush();

      final reply = await requester.request(subject, 'give-bytes');
      expect(reply.data, equals(Uint8List.fromList([0xDE, 0xAD])));

      await sub.close();
    });

    test('respond without replyTo throws ArgumentError', () {
      // Create a NatsMessage with no replyTo manually by publishing and
      // receiving a normal message.
      final message = NatsMessage.forTest('test.sub', Uint8List(0), null);

      expect(
        () => requester.respond(message, 'oops'),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => requester.respondBytes(message, Uint8List(0)),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('multiple concurrent requests get independent replies', () async {
      final subject = 'test.reqrep.concurrent.${DateTime.now().millisecondsSinceEpoch}';

      // Responder echoes with a prefix.
      final sub = responder.subscribe(subject);
      sub.messages.listen((msg) {
        responder.respond(msg, 'echo:${msg.dataAsString}');
      });
      responder.flush();

      // Fire three requests concurrently.
      final results = await Future.wait([
        requester.request(subject, 'a'),
        requester.request(subject, 'b'),
        requester.request(subject, 'c'),
      ]);

      final replies = results.map((r) => r.dataAsString).toSet();
      expect(replies, equals({'echo:a', 'echo:b', 'echo:c'}));

      await sub.close();
    });

    test('request on closed client throws StateError', () async {
      await requester.close();

      expect(
        () => requester.request('some.subject', 'hello'),
        throwsA(isA<StateError>()),
      );
    });
  });
}
