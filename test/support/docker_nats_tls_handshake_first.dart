/// Docker-based NATS server lifecycle management for TLS handshake-first
/// tests.
///
/// Sibling of [DockerNats] / [DockerNatsTls] / [DockerNatsMtls] that runs
/// `nats-server` with a `handshake_first: true` TLS config. Uses reference
/// counting so the container stays alive until the last consumer calls
/// [DockerNatsTlsHandshakeFirst.stop]. Shared lifecycle/orchestration lives
/// in [DockerNatsTlsFixtureCore].
library;

import 'docker_nats_tls_fixture_core.dart';

/// Manages a TLS handshake-first Docker NATS container for integration tests.
///
/// Usage:
/// ```dart
/// late DockerNatsTlsHandshakeFirst nats;
/// setUpAll(() async => nats = await DockerNatsTlsHandshakeFirst.start());
/// tearDownAll(() async => await nats.stop());
/// ```
class DockerNatsTlsHandshakeFirst {
  static final _core = DockerNatsTlsFixtureCore(
    containerName: 'nats-dart-test-tls-handshake-first',
    port: 4225,
    monitoringPort: 8225,
    configHostPath: 'test/support/nats-tls-handshake-first.conf',
    configContainerPath: '/etc/nats/nats-tls-handshake-first.conf',
    label: 'DockerNatsTlsHandshakeFirst',
  );

  /// The NATS URL to connect to — `tls://` so callers can rely on the C
  /// library's URL-driven TLS auto-enable.
  String get url => _core.url;

  static Future<DockerNatsTlsHandshakeFirst> start() async {
    await _core.start();
    return DockerNatsTlsHandshakeFirst._();
  }

  Future<void> stop() => _core.stop();

  DockerNatsTlsHandshakeFirst._();
}
