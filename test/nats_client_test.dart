/// Integration tests for the NATS FFI wrapper — sync pub/sub, memory safety,
/// and the unified connect/connectAsync API.
///
/// These tests require a NATS server on localhost:4222.
/// The test helper will automatically start a Docker container if needed.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:nats_for_dart/nats_for_dart.dart';
import 'package:test/test.dart';

import 'support/ephemeral_nats_server.dart';
import 'support/docker_nats.dart';

void main() {
  late DockerNats nats;

  setUpAll(() async {
    nats = await DockerNats.start();
    NatsLibrary.init();
  });

  tearDownAll(() async {
    NatsLibrary.close(timeoutMs: 5000);
    await nats.stop();
  });

  group('NatsClient sync pub/sub', () {
    late NatsClient client;

    setUp(() {
      client = NatsClient.connect(nats.url);
    });

    tearDown(() => client.close());

    test('publish and receive a string message', () {
      final sub = client.subscribeSync('test.string');
      addTearDown(sub.close);

      const payload = 'Hello, NATS!';
      client.publish('test.string', payload);

      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.subject, equals('test.string'));
      expect(msg.dataAsString, equals(payload));
    });

    test('publish and receive raw bytes', () {
      final sub = client.subscribeSync('test.bytes');
      addTearDown(sub.close);

      final payload = Uint8List.fromList([0x01, 0x02, 0x03, 0xFF]);
      client.publishBytes('test.bytes', payload);

      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.subject, equals('test.bytes'));
      expect(msg.data, equals(payload));
    });

    test('multiple messages arrive in order', () {
      final sub = client.subscribeSync('test.order');
      addTearDown(sub.close);

      for (var i = 0; i < 5; i++) {
        client.publish('test.order', 'msg-$i');
      }

      for (var i = 0; i < 5; i++) {
        final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
        expect(msg.dataAsString, equals('msg-$i'));
      }
    });

    test('nextMessage times out when no message available', () {
      final sub = client.subscribeSync('test.timeout');
      addTearDown(sub.close);

      expect(
        () => sub.nextMessage(timeout: const Duration(milliseconds: 100)),
        throwsA(
          isA<NatsException>().having(
            (e) => e.status,
            'status',
            equals(NatsStatus.timeout),
          ),
        ),
      );
    });

    test('publish on closed client throws StateError', () async {
      final closedClient = NatsClient.connect(nats.url);
      await closedClient.close();

      expect(
        () => closedClient.publish('test.closed', 'nope'),
        throwsStateError,
      );
    });

    test('double close is safe', () async {
      final c = NatsClient.connect(nats.url);
      await c.close();
      await c.close(); // should be a no-op
      expect(c.isClosed, isTrue);
    });

    test('subscription close is idempotent', () {
      final sub = client.subscribeSync('test.idempotent');
      sub.close();
      sub.close(); // should be a no-op
      expect(sub.isClosed, isTrue);
    });

    test('nextMessage on closed subscription throws StateError', () {
      final sub = client.subscribeSync('test.closed.sub');
      sub.close();

      expect(
        () => sub.nextMessage(timeout: const Duration(milliseconds: 100)),
        throwsStateError,
      );
    });

    test('message fields are accessible after subscription is closed', () {
      // Proves eager copy: close the subscription (destroys native
      // resources) then read message fields.
      final sub = client.subscribeSync('test.eager.copy');
      client.publish('test.eager.copy', 'Eagerly copied!');

      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      sub.close(); // native subscription is now destroyed

      expect(msg.subject, equals('test.eager.copy'));
      expect(msg.dataAsString, equals('Eagerly copied!'));
    });

    test('subscribeSync on closed client throws StateError', () async {
      final closedClient = NatsClient.connect(nats.url);
      await closedClient.close();

      expect(() => closedClient.subscribeSync('test.closed'), throwsStateError);
    });

    test('flush on closed client throws StateError', () async {
      final closedClient = NatsClient.connect(nats.url);
      await closedClient.close();

      expect(() => closedClient.flush(), throwsStateError);
    });

    test('closing client closes all sync subscriptions', () async {
      final c = NatsClient.connect(nats.url);
      final sub1 = c.subscribeSync('test.drain.1');
      final sub2 = c.subscribeSync('test.drain.2');

      await c.close();

      expect(
        () => sub1.nextMessage(timeout: const Duration(milliseconds: 50)),
        throwsStateError,
      );
      expect(
        () => sub2.nextMessage(timeout: const Duration(milliseconds: 50)),
        throwsStateError,
      );
    });
  });

  group('NatsClient async connect (no options)', () {
    test('connectAsync connects and supports pub/sub', () async {
      final client = await NatsClient.connectAsync(nats.url);
      addTearDown(() => client.close());

      final sub = client.subscribeSync('test.async.connect');
      addTearDown(sub.close);

      client.publish('test.async.connect', 'async works');
      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.dataAsString, equals('async works'));
    });

    test('connectAsync to invalid URL throws NatsException', () async {
      expect(
        () => NatsClient.connectAsync('nats://localhost:9999'),
        throwsA(isA<NatsException>()),
      );
    });

    test('connectAsync double close is safe', () async {
      final client = await NatsClient.connectAsync(nats.url);
      await client.close();
      await client.close(); // should be a no-op
      expect(client.isClosed, isTrue);
    });
  });

  group('flush with timeout', () {
    late NatsClient client;

    setUp(() {
      client = NatsClient.connect(nats.url);
    });

    tearDown(() => client.close());

    test('flush with explicit timeout succeeds', () {
      final sub = client.subscribeSync('test.flush.timeout');
      addTearDown(sub.close);

      client.publish('test.flush.timeout', 'flushed');
      client.flush(timeout: const Duration(seconds: 5));

      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.dataAsString, equals('flushed'));
    });
  });

  group('NatsMessage.toString()', () {
    late NatsClient client;

    setUp(() {
      client = NatsClient.connect(nats.url);
    });

    tearDown(() => client.close());

    test('NatsMessage.toString() without replyTo matches expected format', () {
      final sub = client.subscribeSync('test.msg.tostring');
      addTearDown(sub.close);

      client.publish('test.msg.tostring', 'hello');
      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));

      expect(
        msg.toString(),
        equals('NatsMessage(subject: test.msg.tostring, data: hello)'),
      );
    });

    test(
      'NatsMessage.toString() with replyTo matches expected format',
      () async {
        // Set up a responder so we can get a message with a replyTo
        final responder = client.subscribeSync('test.msg.tostring.req');
        addTearDown(responder.close);

        client.publish('test.msg.tostring', 'ignored');

        // Use request/respond to get a message that has replyTo set
        final sub = client.subscribe('test.msg.tostring.req');
        addTearDown(() => sub.close());

        await Future.delayed(const Duration(milliseconds: 200));

        // Publish a request (has replyTo set to the inbox)
        client.publish('test.msg.tostring', 'no-reply');

        // Get a message via sync sub — it won't have replyTo.
        // Instead, listen on the responder for a request message.
        final requestFuture = client.request(
          'test.msg.tostring.req',
          'request-body',
          timeout: const Duration(seconds: 5),
        );

        final reqMsg = responder.nextMessage(
          timeout: const Duration(seconds: 5),
        );
        expect(reqMsg.replyTo, isNotNull);
        expect(
          reqMsg.toString(),
          equals(
            'NatsMessage(subject: test.msg.tostring.req, '
            'replyTo: ${reqMsg.replyTo}, data: request-body)',
          ),
        );

        // Respond so the request future completes
        client.respond(reqMsg, 'response');
        await requestFuture;
      },
    );
  });

  group('NatsError.toString()', () {
    test('NatsError.toString() matches expected format', () {
      final error = NatsError(NatsStatus.ok);
      expect(error.toString(), equals('NatsError(ok)'));
    });

    test('NatsError.toString() with error status matches expected format', () {
      final error = NatsError(NatsStatus.timeout);
      expect(error.toString(), equals('NatsError(timeout)'));
    });
  });

  group('NatsClient.connect with options', () {
    late String url;

    setUpAll(() => url = nats.url);

    test('connect(url) without options connects successfully', () {
      final client = NatsClient.connect(url);
      addTearDown(() => client.close());

      final sub = client.subscribeSync('test.connect.noopts');
      addTearDown(sub.close);

      client.publish('test.connect.noopts', 'no opts');
      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.dataAsString, equals('no opts'));
    });

    test('connect(url, options: NatsOptions(name: ...)) connects and '
        'publishes', () {
      final client = NatsClient.connect(
        url,
        options: const NatsOptions(name: 'sync-connect-test'),
      );
      addTearDown(() => client.close());

      final sub = client.subscribeSync('test.connect.opts');
      addTearDown(sub.close);

      client.publish('test.connect.opts', 'with opts');
      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.dataAsString, equals('with opts'));
    });

    test('connect with options exposes lifecycle streams', () {
      final client = NatsClient.connect(
        url,
        options: const NatsOptions(
          name: 'lifecycle-with-options',
          maxReconnect: 3,
          reconnectWait: Duration(seconds: 1),
        ),
      );
      addTearDown(() => client.close());

      expect(client.onDisconnected, isA<Stream<void>>());
      expect(client.onReconnected, isA<Stream<void>>());
      expect(client.onClosed, isA<Stream<void>>());
      expect(client.onError, isA<Stream<NatsError>>());
    });

    test('connect with invalid options (user without password) throws '
        'ArgumentError before any native allocation', () {
      expect(
        () =>
            NatsClient.connect(url, options: const NatsOptions(user: 'alice')),
        throwsArgumentError,
      );
    });

    test('connectAsync(url) without options still works', () async {
      final client = await NatsClient.connectAsync(url);
      addTearDown(() => client.close());

      final sub = client.subscribeSync('test.async.connect.noopts');
      addTearDown(sub.close);

      client.publish('test.async.connect.noopts', 'no opts async');
      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.dataAsString, equals('no opts async'));
    });

    test('connectAsync(url, options: ...) connects, publishes, and exposes '
        'lifecycle streams', () async {
      final client = await NatsClient.connectAsync(
        url,
        options: const NatsOptions(name: 'async-connect-test'),
      );
      addTearDown(() => client.close());

      expect(client.onDisconnected, isA<Stream<void>>());
      expect(client.onError, isA<Stream<NatsError>>());

      final sub = client.subscribeSync('test.async.connect.opts');
      addTearDown(sub.close);

      client.publish('test.async.connect.opts', 'with opts async');
      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.dataAsString, equals('with opts async'));
    });

    test(
      'connectAsync routes through NatsOptions.servers when non-empty',
      () async {
        final client = await NatsClient.connectAsync(
          'nats://127.0.0.1:1',
          options: NatsOptions(servers: [nats.url, 'nats://localhost:4223']),
        );
        addTearDown(() => client.close());

        final sub = client.subscribeSync('test.async.connect.servers');
        addTearDown(sub.close);

        client.publish('test.async.connect.servers', 'servers wins async');
        final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
        expect(msg.dataAsString, equals('servers wins async'));
      },
    );

    test('connectAsync with invalid options rejects the returned future '
        'without spawning a worker isolate', () async {
      await expectLater(
        NatsClient.connectAsync(
          url,
          options: const NatsOptions(password: 'secret'),
        ),
        throwsArgumentError,
      );
    });
  });

  group('NatsException', () {
    test('default message includes status name and value', () {
      final exception = NatsException(NatsStatus.timeout);
      expect(exception.message, equals('NATS error: timeout (26)'));
    });

    test('toString() wraps the message', () {
      final exception = NatsException(NatsStatus.timeout);
      expect(
        exception.toString(),
        equals('NatsException(NATS error: timeout (26))'),
      );
    });
  });

  group('NatsClient lifecycle streams', () {
    test('onDisconnected, onReconnected, onClosed are Stream<void> getters '
        'available on a client connected without options', () {
      final client = NatsClient.connect(nats.url);
      addTearDown(() => client.close());

      expect(client.onDisconnected, isA<Stream<void>>());
      expect(client.onReconnected, isA<Stream<void>>());
      expect(client.onClosed, isA<Stream<void>>());
    });

    test('onError is a Stream<NatsError> getter available on a client '
        'connected without options', () {
      final client = NatsClient.connect(nats.url);
      addTearDown(() => client.close());

      expect(client.onError, isA<Stream<NatsError>>());
    });

    test('listening to lifecycle streams after connect succeeds — no '
        '"register before connect" requirement', () {
      final client = NatsClient.connect(nats.url);
      addTearDown(() => client.close());

      final disconnectedSub = client.onDisconnected.listen((_) {});
      final reconnectedSub = client.onReconnected.listen((_) {});
      final closedSub = client.onClosed.listen((_) {});
      final errorSub = client.onError.listen((_) {});

      addTearDown(() async {
        await disconnectedSub.cancel();
        await reconnectedSub.cancel();
        await closedSub.cancel();
        await errorSub.cancel();
      });
    });

    test(
      'lifecycle streams are broadcast — multiple listeners are allowed',
      () {
        final client = NatsClient.connect(nats.url);
        addTearDown(() => client.close());

        final firstDisconnected = client.onDisconnected.listen((_) {});
        final secondDisconnected = client.onDisconnected.listen((_) {});
        final firstError = client.onError.listen((_) {});
        final secondError = client.onError.listen((_) {});

        addTearDown(() async {
          await firstDisconnected.cancel();
          await secondDisconnected.cancel();
          await firstError.cancel();
          await secondError.cancel();
        });
      },
    );

    test(
      'onDisconnected fires without options when the server goes away',
      () async {
        final ephemeral = await EphemeralNatsServer.start();
        var ephemeralStopped = false;
        addTearDown(() async {
          if (!ephemeralStopped) await ephemeral.stop();
        });

        final client = NatsClient.connect(ephemeral.url);
        addTearDown(() => client.close());

        final disconnected = client.onDisconnected.first;

        await ephemeral.stop();
        ephemeralStopped = true;

        await disconnected.timeout(const Duration(seconds: 10));
      },
    );

    test('client.close() drains all four lifecycle streams', () async {
      final client = NatsClient.connect(nats.url);

      final disconnectedDone = Completer<void>();
      final reconnectedDone = Completer<void>();
      final closedDone = Completer<void>();
      final errorDone = Completer<void>();

      client.onDisconnected.listen((_) {}, onDone: disconnectedDone.complete);
      client.onReconnected.listen((_) {}, onDone: reconnectedDone.complete);
      client.onClosed.listen((_) {}, onDone: closedDone.complete);
      client.onError.listen((_) {}, onDone: errorDone.complete);

      await client.close();

      await Future.wait([
        disconnectedDone.future,
        reconnectedDone.future,
        closedDone.future,
        errorDone.future,
      ]).timeout(const Duration(seconds: 5));
    });

    test('lifecycle streams are also available on a client connected with '
        'options', () async {
      final client = NatsClient.connect(
        nats.url,
        options: const NatsOptions(
          name: 'lifecycle-stream-test',
          maxReconnect: 3,
          reconnectWait: Duration(seconds: 1),
        ),
      );
      addTearDown(() => client.close());

      expect(client.onDisconnected, isA<Stream<void>>());
      expect(client.onReconnected, isA<Stream<void>>());
      expect(client.onClosed, isA<Stream<void>>());
      expect(client.onError, isA<Stream<NatsError>>());
    });
  });
}
