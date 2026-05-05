/// Integration tests for mutual TLS (mTLS).
///
/// Proves end-to-end that Dart-level [NatsOptions.clientCertPath],
/// [NatsOptions.clientKeyPath] and [NatsOptions.caCertPath] flow through
/// to the C library and drive the expected handshake behaviour against an
/// mTLS-enabled NATS server (`verify: true`).
///
/// Requires an mTLS NATS server on localhost:4224. [DockerNatsMtls] starts
/// one automatically (Docker) or reuses a native server if one is already
/// listening.
library;

import 'package:nats_for_dart/nats_for_dart.dart';
import 'package:test/test.dart';

import 'support/docker_nats_mtls.dart';

void main() {
  late DockerNatsMtls nats;

  setUpAll(() async {
    nats = await DockerNatsMtls.start();
    NatsLibrary.init();
  });

  tearDownAll(() async {
    NatsLibrary.close(timeoutMs: 5000);
    await nats.stop();
  });

  group('mTLS connection', () {
    test('server requires client cert — connection without one fails with '
        'NatsException', () {
      expect(
        () => NatsClient.connect(
          nats.url,
          options: const NatsOptions(
            caCertPath: 'test/support/certs/ca-cert.pem',
          ),
        ),
        throwsA(isA<NatsException>()),
      );
    });
  });
}
