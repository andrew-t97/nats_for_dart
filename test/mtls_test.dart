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

    test('full mutual handshake — client cert + key + CA round-trips a '
        'message', () {
      final client = NatsClient.connect(
        nats.url,
        options: const NatsOptions(
          clientCertPath: 'test/support/certs/client-cert.pem',
          clientKeyPath: 'test/support/certs/client-key.pem',
          caCertPath: 'test/support/certs/ca-cert.pem',
        ),
      );
      addTearDown(() => client.close());

      final sub = client.subscribeSync('test.mtls.roundtrip');
      addTearDown(sub.close);

      client.publish('test.mtls.roundtrip', 'mtls-handshake');
      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.dataAsString, equals('mtls-handshake'));
    });

    test('wrong CA — caCertPath that does not anchor the server cert fails '
        'with NatsException', () {
      expect(
        () => NatsClient.connect(
          nats.url,
          options: const NatsOptions(
            clientCertPath: 'test/support/certs/client-cert.pem',
            clientKeyPath: 'test/support/certs/client-key.pem',
            caCertPath: 'test/support/certs/client-cert.pem',
          ),
        ),
        throwsA(isA<NatsException>()),
      );
    });

    test('explicit expectedHostname matching the cert SAN — handshake '
        'succeeds', () {
      final client = NatsClient.connect(
        nats.url,
        options: const NatsOptions(
          clientCertPath: 'test/support/certs/client-cert.pem',
          clientKeyPath: 'test/support/certs/client-key.pem',
          caCertPath: 'test/support/certs/ca-cert.pem',
          expectedHostname: 'localhost',
        ),
      );
      addTearDown(() => client.close());

      final sub = client.subscribeSync('test.mtls.expected_hostname.match');
      addTearDown(sub.close);

      client.publish(
        'test.mtls.expected_hostname.match',
        'expected-hostname-match',
      );
      final msg = sub.nextMessage(timeout: const Duration(seconds: 2));
      expect(msg.dataAsString, equals('expected-hostname-match'));
    });

    test('explicit expectedHostname mismatching the cert — connection '
        'rejected with NatsException', () {
      expect(
        () => NatsClient.connect(
          nats.url,
          options: const NatsOptions(
            clientCertPath: 'test/support/certs/client-cert.pem',
            clientKeyPath: 'test/support/certs/client-key.pem',
            caCertPath: 'test/support/certs/ca-cert.pem',
            expectedHostname: 'wrong.example.com',
          ),
        ),
        throwsA(isA<NatsException>()),
      );
    });
  });
}
