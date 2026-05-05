/// Docker-based NATS server lifecycle management for TLS tests.
///
/// Sibling of [DockerNats] that runs `nats-server` with a TLS-enabled
/// config. Uses reference counting so the container stays alive until the
/// last consumer calls [DockerNatsTls.stop]. Shared lifecycle/orchestration
/// lives in [DockerNatsTlsFixtureCore].
library;

import 'docker_nats_tls_fixture_core.dart';

/// Manages a TLS-enabled Docker NATS container for integration tests.
///
/// Usage:
/// ```dart
/// late DockerNatsTls nats;
/// setUpAll(() async => nats = await DockerNatsTls.start());
/// tearDownAll(() async => await nats.stop());
/// ```
class DockerNatsTls {
  static final _core = DockerNatsTlsFixtureCore(
    containerName: 'nats-dart-test-tls',
    port: 4223,
    monitoringPort: 8223,
    configHostPath: 'test/support/nats-tls.conf',
    configContainerPath: '/etc/nats/nats-tls.conf',
    label: 'DockerNatsTls',
  );

  /// The NATS URL to connect to — `tls://` so callers can rely on the C
  /// library's URL-driven TLS auto-enable.
  String get url => _core.url;

  static Future<DockerNatsTls> start() async {
    await _core.start();
    return DockerNatsTls._();
  }

  Future<void> stop() => _core.stop();

  DockerNatsTls._();
}
