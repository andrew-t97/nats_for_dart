/// Integration tests for the NATS FFI wrapper — sync pub/sub, memory safety,
/// and NatsOptions builder.
///
/// These tests require a running `nats-server` on localhost:4222.
/// Start one with:
///   nats-server &
library;

import 'dart:typed_data';

import 'package:nats_for_dart/nats_for_dart.dart';
import 'package:test/test.dart';

void main() {
  // Initialise the NATS C library once for the entire test suite.
  setUpAll(() {
    NatsLibrary.init();
  });

  tearDownAll(() {
    NatsLibrary.close(timeoutMs: 5000);
  });

  group('NatsClient sync pub/sub', () {
    late NatsClient client;

    setUp(() {
      client = NatsClient.connect('nats://localhost:4222');
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
        throwsA(isA<NatsException>().having(
          (e) => e.status,
          'status',
          equals(natsStatus.NATS_TIMEOUT),
        )),
      );
    });

    test('publish on closed client throws StateError', () async {
      final closedClient = NatsClient.connect('nats://localhost:4222');
      await closedClient.close();

      expect(
        () => closedClient.publish('test.closed', 'nope'),
        throwsStateError,
      );
    });

    test('double close is safe', () async {
      final c = NatsClient.connect('nats://localhost:4222');
      await c.close();
      await c.close(); // should be a no-op
    });

    test('subscription close is idempotent', () {
      final sub = client.subscribeSync('test.idempotent');
      sub.close();
      sub.close(); // should be a no-op
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
      final closedClient = NatsClient.connect('nats://localhost:4222');
      await closedClient.close();

      expect(
        () => closedClient.subscribeSync('test.closed'),
        throwsStateError,
      );
    });

    test('flush on closed client throws StateError', () async {
      final closedClient = NatsClient.connect('nats://localhost:4222');
      await closedClient.close();

      expect(
        () => closedClient.flush(),
        throwsStateError,
      );
    });

    test('closing client closes all sync subscriptions', () async {
      final c = NatsClient.connect('nats://localhost:4222');
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

  group('NatsClient async connect', () {
    test('connectAsync connects and supports pub/sub', () async {
      final client = await NatsClient.connectAsync('nats://localhost:4222');
      addTearDown(() => client.close());

      final sub = client.subscribeSync('test.async.connect');
      addTearDown(sub.close);

      client.publish('test.async.connect', 'async works');
      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.dataAsString, equals('async works'));
    });

    test('connectWithOptionsAsync connects and supports pub/sub', () async {
      final opts = NatsOptions()
        ..setUrl('nats://localhost:4222')
        ..setName('dart-async-test');

      final client = await NatsClient.connectWithOptionsAsync(opts);
      addTearDown(() => client.close());

      final sub = client.subscribeSync('test.async.opts');
      addTearDown(sub.close);

      client.publish('test.async.opts', 'async opts works');
      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.dataAsString, equals('async opts works'));
    });

    test('connectAsync to invalid URL throws NatsException', () async {
      expect(
        () => NatsClient.connectAsync('nats://localhost:9999'),
        throwsA(isA<NatsException>()),
      );
    });

    test('connectAsync double close is safe', () async {
      final client = await NatsClient.connectAsync('nats://localhost:4222');
      await client.close();
      await client.close(); // should be a no-op
    });
  });

  group('flush with timeout', () {
    late NatsClient client;

    setUp(() {
      client = NatsClient.connect('nats://localhost:4222');
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
      client = NatsClient.connect('nats://localhost:4222');
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

    test('NatsMessage.toString() with replyTo matches expected format', () async {
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

      final reqMsg = responder.nextMessage(timeout: const Duration(seconds: 5));
      expect(reqMsg.replyTo, isNotNull);
      expect(
        reqMsg.toString(),
        equals('NatsMessage(subject: test.msg.tostring.req, '
            'replyTo: ${reqMsg.replyTo}, data: request-body)'),
      );

      // Respond so the request future completes
      client.respond(reqMsg, 'response');
      await requestFuture;
    });
  });

  group('NatsError.toString()', () {
    test('NatsError.toString() matches expected format', () {
      final error = NatsError(natsStatus.NATS_OK);
      expect(
        error.toString(),
        equals('NatsError(NATS_OK)'),
      );
    });

    test('NatsError.toString() with error status matches expected format', () {
      final error = NatsError(natsStatus.NATS_TIMEOUT);
      expect(
        error.toString(),
        equals('NatsError(NATS_TIMEOUT)'),
      );
    });
  });

  group('NatsOptions expanded builder', () {
    test('fromUrl convenience factory connects successfully', () async {
      final opts = NatsOptions.fromUrl('nats://localhost:4222');
      final client = NatsClient.connectWithOptions(opts);
      addTearDown(() => client.close());

      final sub = client.subscribeSync('test.opts.fromurl');
      addTearDown(sub.close);

      client.publish('test.opts.fromurl', 'fromUrl works');
      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.dataAsString, equals('fromUrl works'));
    });

    test('chaining API with setName and setPingInterval', () async {
      final opts = NatsOptions()
        ..setUrl('nats://localhost:4222')
        ..setName('dart-test-client')
        ..setPingInterval(const Duration(seconds: 30))
        ..setMaxPingsOut(5)
        ..setVerbose(false)
        ..setPedantic(false)
        ..setNoRandomize(true)
        ..setMaxReconnect(3)
        ..setReconnectWait(const Duration(seconds: 1))
        ..setReconnectBufSize(1024 * 1024)
        ..setIOBufSize(32768)
        ..setTimeout(const Duration(seconds: 5));

      final client = NatsClient.connectWithOptions(opts);
      addTearDown(() => client.close());

      final sub = client.subscribeSync('test.opts.chain');
      addTearDown(sub.close);

      client.publish('test.opts.chain', 'chained options');
      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.dataAsString, equals('chained options'));
    });

    test('setters on closed NatsOptions throw StateError', () async {
      final opts = NatsOptions();
      await opts.close();

      expect(() => opts.setUrl('nats://localhost:4222'), throwsStateError);
      expect(() => opts.setName('test'), throwsStateError);
      expect(() => opts.setVerbose(true), throwsStateError);
      expect(() => opts.setPedantic(true), throwsStateError);
      expect(() => opts.setNoRandomize(true), throwsStateError);
      expect(() => opts.setMaxReconnect(3), throwsStateError);
      expect(
        () => opts.setReconnectWait(const Duration(seconds: 1)),
        throwsStateError,
      );
      expect(() => opts.setReconnectBufSize(1024), throwsStateError);
      expect(
        () => opts.setPingInterval(const Duration(seconds: 30)),
        throwsStateError,
      );
      expect(() => opts.setMaxPingsOut(5), throwsStateError);
      expect(() => opts.setIOBufSize(32768), throwsStateError);
      expect(
        () => opts.setTimeout(const Duration(seconds: 5)),
        throwsStateError,
      );
    });

    test('double close on NatsOptions is safe no-op', () async {
      final opts = NatsOptions();
      await opts.close();
      await opts.close(); // should be a no-op
    });

    test('NatsOptions setUserInfo does not throw', () {
      final opts = NatsOptions()
        ..setUrl('nats://localhost:4222')
        ..setUserInfo('user', 'password');
      addTearDown(() => opts.close());
    });

    test('NatsOptions setToken does not throw', () {
      final opts = NatsOptions()
        ..setUrl('nats://localhost:4222')
        ..setToken('some-token');
      addTearDown(() => opts.close());
    });

    test('NatsOptions setServers accepts multiple URLs', () {
      final opts = NatsOptions()
        ..setServers(['nats://localhost:4222', 'nats://localhost:4223']);
      addTearDown(() => opts.close());
    });

    test('NatsOptions setCredentialsFile does not throw', () {
      final opts = NatsOptions()
        ..setUrl('nats://localhost:4222')
        ..setCredentialsFile('/tmp/fake-creds.jwt');
      addTearDown(() => opts.close());
    });

    test('NatsOptions setCredentialsFile with separate seed file', () {
      final opts = NatsOptions()
        ..setUrl('nats://localhost:4222')
        ..setCredentialsFile('/tmp/fake-creds.jwt', '/tmp/fake-seed.nk');
      addTearDown(() => opts.close());
    });
  });

  group('NatsException', () {
    test('default message includes status name and value', () {
      final exception = NatsException(natsStatus.NATS_TIMEOUT);
      expect(
        exception.message,
        equals('NATS error: NATS_TIMEOUT (26)'),
      );
    });

    test('toString() wraps the message', () {
      final exception = NatsException(natsStatus.NATS_TIMEOUT);
      expect(
        exception.toString(),
        equals('NatsException(NATS error: NATS_TIMEOUT (26))'),
      );
    });
  });
}
