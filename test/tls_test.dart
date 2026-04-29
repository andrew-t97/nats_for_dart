/// Integration tests for the TLS connection options.
///
/// Proves end-to-end that Dart-level `tls` and `skipServerVerification`
/// flags on [NatsOptions] flow through to the C library and cause the
/// expected handshake behaviour against a TLS-enabled NATS server.
///
/// Requires a TLS NATS server on localhost:4223. [DockerNatsTls] starts
/// one automatically (Docker) or reuses a native server if one is already
/// listening.
library;

import 'package:nats_for_dart/nats_for_dart.dart';
import 'package:test/test.dart';

import 'support/docker_nats_tls.dart';

void main() {
  late DockerNatsTls nats;

  setUpAll(() async {
    nats = await DockerNatsTls.start();
    NatsLibrary.init();
  });

  tearDownAll(() async {
    NatsLibrary.close(timeoutMs: 5000);
    await nats.stop();
  });

  group('TLS connection', () {
    test('connects with tls: true + nats:// URL + '
        'skipServerVerification: true', () {
      final client = NatsClient.connect(
        'nats://localhost:4223',
        options: const NatsOptions(tls: true, skipServerVerification: true),
      );
      addTearDown(() => client.close());

      final sub = client.subscribeSync('test.tls.flag');
      addTearDown(sub.close);

      client.publish('test.tls.flag', 'tls-via-flag');
      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.dataAsString, equals('tls-via-flag'));
    });

    test('connects with tls:// URL scheme + '
        'skipServerVerification: true', () {
      final client = NatsClient.connect(
        nats.url,
        options: const NatsOptions(skipServerVerification: true),
      );
      addTearDown(() => client.close());

      final sub = client.subscribeSync('test.tls.scheme');
      addTearDown(sub.close);

      client.publish('test.tls.scheme', 'tls-via-scheme');
      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.dataAsString, equals('tls-via-scheme'));
    });

    test('connects with tls: true + explicit skipServerVerification: false '
        'against self-signed server fails with NatsException', () {
      expect(
        () => NatsClient.connect(
          nats.url,
          options: const NatsOptions(tls: true, skipServerVerification: false),
        ),
        throwsA(isA<NatsException>()),
      );
    });
  });
}
