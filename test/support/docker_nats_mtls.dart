/// Docker-based NATS server lifecycle management for mTLS tests.
///
/// Sibling of [DockerNats] / [DockerNatsTls] that runs `nats-server` with a
/// `verify: true` mTLS-enabled config. Uses reference counting so the
/// container stays alive until the last consumer calls [DockerNatsMtls.stop].
/// Shared lifecycle/orchestration lives in [DockerNatsTlsFixtureCore].
library;

import 'docker_nats_tls_fixture_core.dart';

/// Manages an mTLS-enabled Docker NATS container for integration tests.
///
/// Usage:
/// ```dart
/// late DockerNatsMtls nats;
/// setUpAll(() async => nats = await DockerNatsMtls.start());
/// tearDownAll(() async => await nats.stop());
/// ```
class DockerNatsMtls {
  static final _core = DockerNatsTlsFixtureCore(
    containerName: 'nats-dart-test-mtls',
    port: 4224,
    monitoringPort: 8224,
    configHostPath: 'test/support/nats-mtls.conf',
    configContainerPath: '/etc/nats/nats-mtls.conf',
    label: 'DockerNatsMtls',
  );

  /// The NATS URL to connect to — `tls://` so callers can rely on the C
  /// library's URL-driven TLS auto-enable.
  String get url => _core.url;

  static Future<DockerNatsMtls> start() async {
    await _core.start();
    return DockerNatsMtls._();
  }

  Future<void> stop() => _core.stop();

  DockerNatsMtls._();
}
