/// Unit tests for the immutable [NatsOptions] value class.
///
/// These tests are pure Dart and do not require a running NATS server.
library;

// The new immutable NatsOptions value class is not yet exported from the
// public barrel — Phase 5 swaps the export. Import from `src/` directly so
// Phase 1 tests can exercise the class in isolation without colliding with
// the legacy FFI `NatsOptions` that still ships via `package:nats_for_dart`.
import 'package:nats_for_dart/src/nats_options_config.dart';
import 'package:test/test.dart';

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
}
