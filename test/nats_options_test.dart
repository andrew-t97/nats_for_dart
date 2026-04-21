/// Unit tests for the immutable [NatsOptions] value class and the internal
/// [NatsOptionsHandle] FFI bridge.
library;

import 'package:nats_for_dart/nats_for_dart.dart';
import 'package:nats_for_dart/src/nats_options.dart' show NatsOptionsHandle;
import 'package:test/test.dart';

import 'support/docker_nats.dart';

void main() {
  group('NatsOptions default construction', () {
    test('const NatsOptions() compiles as a const expression', () {
      const options = NatsOptions();
      expect(options, isA<NatsOptions>());
    });

    test('all optional scalar fields default to null', () {
      const options = NatsOptions();
      expect(options.name, isNull);
      expect(options.user, isNull);
      expect(options.password, isNull);
      expect(options.token, isNull);
      expect(options.maxReconnect, isNull);
      expect(options.reconnectWait, isNull);
      expect(options.reconnectBufSize, isNull);
      expect(options.verbose, isNull);
      expect(options.pedantic, isNull);
      expect(options.noRandomize, isNull);
      expect(options.pingInterval, isNull);
      expect(options.maxPingsOut, isNull);
      expect(options.ioBufSize, isNull);
      expect(options.timeout, isNull);
      expect(options.credentialsFile, isNull);
      expect(options.credentialsSeedFile, isNull);
    });

    test('servers defaults to the shared const empty list', () {
      const options = NatsOptions();
      expect(options.servers, isEmpty);
      // Identity check locks in const-ness: any refactor that switches the
      // default to `[]` (non-const) would regress this invariant silently
      // under an `isEmpty` assertion alone.
      expect(identical(options.servers, const <String>[]), isTrue);
    });

    test('default servers list (const []) rejects mutation', () {
      const options = NatsOptions();
      expect(() => options.servers.add('nats://x'), throwsUnsupportedError);
    });

    test('caller-supplied servers list is captured by reference', () {
      // Documents the contract: the config captures the reference rather
      // than copying defensively (const requires this). Callers must not
      // mutate the list after passing it in — this test locks in that
      // trust relationship so future "helpful" copy-on-write changes are
      // visible breaking changes, not silent behavioural shifts.
      final mutable = <String>['nats://a:4222'];
      final options = NatsOptions(servers: mutable);
      expect(identical(options.servers, mutable), isTrue);
    });
  });

  group('NatsOptions named-parameter construction', () {
    test('every field round-trips through the constructor', () {
      const options = NatsOptions(
        name: 'my-client',
        servers: ['nats://a:4222', 'nats://b:4222'],
        user: 'alice',
        password: 'secret',
        token: 'tok',
        maxReconnect: 5,
        reconnectWait: Duration(seconds: 2),
        reconnectBufSize: 8388608,
        verbose: true,
        pedantic: false,
        noRandomize: true,
        pingInterval: Duration(minutes: 2),
        maxPingsOut: 3,
        ioBufSize: 65536,
        timeout: Duration(seconds: 10),
        credentialsFile: '/path/to/creds.jwt',
        credentialsSeedFile: '/path/to/creds.seed',
      );

      expect(options.name, equals('my-client'));
      expect(options.servers, equals(['nats://a:4222', 'nats://b:4222']));
      expect(options.user, equals('alice'));
      expect(options.password, equals('secret'));
      expect(options.token, equals('tok'));
      expect(options.maxReconnect, equals(5));
      expect(options.reconnectWait, equals(const Duration(seconds: 2)));
      expect(options.reconnectBufSize, equals(8388608));
      expect(options.verbose, isTrue);
      expect(options.pedantic, isFalse);
      expect(options.noRandomize, isTrue);
      expect(options.pingInterval, equals(const Duration(minutes: 2)));
      expect(options.maxPingsOut, equals(3));
      expect(options.ioBufSize, equals(65536));
      expect(options.timeout, equals(const Duration(seconds: 10)));
      expect(options.credentialsFile, equals('/path/to/creds.jwt'));
      expect(options.credentialsSeedFile, equals('/path/to/creds.seed'));
    });

    test('only some fields may be provided; the rest remain null', () {
      const options = NatsOptions(name: 'partial', maxReconnect: 1);
      expect(options.name, equals('partial'));
      expect(options.maxReconnect, equals(1));
      expect(options.reconnectWait, isNull);
      expect(options.servers, isEmpty);
    });
  });

  group('NatsOptions.validate', () {
    test('default construction is valid', () {
      const NatsOptions().validate();
    });

    test('user + password pair is valid', () {
      const NatsOptions(user: 'alice', password: 'secret').validate();
    });

    test('token alone is valid', () {
      const NatsOptions(token: 'tok').validate();
    });

    test('credentialsFile alone is valid', () {
      const NatsOptions(credentialsFile: '/jwt').validate();
    });

    test('user without password throws ArgumentError', () {
      expect(
        () => const NatsOptions(user: 'alice').validate(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('must be set together'),
          ),
        ),
      );
    });

    test('password without user throws ArgumentError', () {
      expect(
        () => const NatsOptions(password: 'secret').validate(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('must be set together'),
          ),
        ),
      );
    });

    test('token with user/password throws ArgumentError', () {
      expect(
        () => const NatsOptions(
          token: 'tok',
          user: 'alice',
          password: 'secret',
        ).validate(),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('mutually exclusive'),
          ),
        ),
      );
    });

    test(
      'credentialsSeedFile without credentialsFile throws ArgumentError',
      () {
        expect(
          () => const NatsOptions(credentialsSeedFile: '/seed').validate(),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('seed file alone cannot identify'),
            ),
          ),
        );
      },
    );
  });

  group('NatsOptionsHandle.fromConfig validation', () {
    const url = 'nats://localhost:4222';

    test('user without password throws ArgumentError', () {
      expect(
        () =>
            NatsOptionsHandle.fromConfig(const NatsOptions(user: 'alice'), url),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('user'),
          ),
        ),
      );
    });

    test('password without user throws ArgumentError', () {
      expect(
        () => NatsOptionsHandle.fromConfig(
          const NatsOptions(password: 'secret'),
          url,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('password'),
          ),
        ),
      );
    });

    test('token with user throws ArgumentError', () {
      expect(
        () => NatsOptionsHandle.fromConfig(
          const NatsOptions(token: 'tok', user: 'alice', password: 'secret'),
          url,
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('token'),
          ),
        ),
      );
    });

    test(
      'credentialsSeedFile without credentialsFile throws ArgumentError',
      () {
        expect(
          () => NatsOptionsHandle.fromConfig(
            const NatsOptions(credentialsSeedFile: '/path/to/seed.nk'),
            url,
          ),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              contains('credentialsFile'),
            ),
          ),
        );
      },
    );
  });

  group('NatsOptionsHandle.fromConfig native bridge', () {
    late DockerNats nats;
    late String url;

    setUpAll(() async {
      nats = await DockerNats.start();
      url = nats.url;
      NatsLibrary.init();
    });

    tearDownAll(() async {
      NatsLibrary.close(timeoutMs: 5000);
      await nats.stop();
    });

    test('empty config + url connects via the url path', () async {
      final client = NatsClient.connect(url, options: const NatsOptions());
      addTearDown(() => client.close());

      final sub = client.subscribeSync('test.fromConfig.url');
      addTearDown(sub.close);

      client.publish('test.fromConfig.url', 'url path');
      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.dataAsString, equals('url path'));
    });

    test('non-empty servers overrides the positional url argument', () async {
      // Positional `url` points at an unreachable port. If `fromConfig`
      // routes through `natsOptions_SetServers` (and skips `SetURL`), the
      // client connects to the reachable server in the `servers` list.
      // If it mistakenly used `url`, this test would fail with a connect
      // error — making the branch observable end-to-end.
      final client = NatsClient.connect(
        'nats://127.0.0.1:1', // intentionally unreachable
        options: NatsOptions(servers: [nats.url]),
      );
      addTearDown(() => client.close());

      final sub = client.subscribeSync('test.fromConfig.servers');
      addTearDown(sub.close);

      client.publish('test.fromConfig.servers', 'servers path');
      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.dataAsString, equals('servers path'));
    });

    test('user + password pair connects successfully', () async {
      final client = NatsClient.connect(
        url,
        options: const NatsOptions(
          user: 'test-user',
          password: 'test-password',
        ),
      );
      addTearDown(() => client.close());

      final sub = client.subscribeSync('test.fromConfig.userinfo');
      addTearDown(sub.close);

      client.publish('test.fromConfig.userinfo', 'userinfo works');
      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.dataAsString, equals('userinfo works'));
    });

    test('every scalar field applied in a single config connects', () async {
      final client = NatsClient.connect(
        url,
        options: const NatsOptions(
          name: 'fromConfig-kitchen-sink',
          maxReconnect: 3,
          reconnectWait: Duration(seconds: 1),
          reconnectBufSize: 1024 * 1024,
          verbose: false,
          pedantic: false,
          noRandomize: true,
          pingInterval: Duration(seconds: 30),
          maxPingsOut: 5,
          ioBufSize: 32768,
          timeout: Duration(seconds: 5),
        ),
      );
      addTearDown(() => client.close());

      final sub = client.subscribeSync('test.fromConfig.kitchen');
      addTearDown(sub.close);

      client.publish('test.fromConfig.kitchen', 'kitchen works');
      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.dataAsString, equals('kitchen works'));
    });

    test('close on a directly-constructed handle is idempotent', () async {
      final handle = NatsOptionsHandle.fromConfig(const NatsOptions(), url);
      await handle.close();
      await handle.close(); // second close is a no-op
      expect(handle.isClosed, isTrue);
    });

    test('credentialsFile alone does not trip the Dart validator', () async {
      final handle = NatsOptionsHandle.fromConfig(
        const NatsOptions(credentialsFile: '/nonexistent.jwt'),
        url,
      );
      addTearDown(() => handle.close());
      expect(handle.isClosed, isFalse);
    });
  });
}
