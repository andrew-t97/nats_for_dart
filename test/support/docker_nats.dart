/// Docker-based NATS server lifecycle management for tests.
///
/// Automatically starts a Docker NATS container with JetStream enabled.
/// Uses reference counting so the container stays alive until the last
/// consumer calls [DockerNats.stop].
library;

import 'dart:io';

import 'nats_server_support.dart';

/// Manages a Docker NATS container for integration tests.
///
/// Usage:
/// ```dart
/// late DockerNats nats;
/// setUpAll(() async => nats = await DockerNats.start());
/// tearDownAll(() async => await nats.stop());
/// ```
class DockerNats {
  // Container configuration
  static const _containerName = 'nats-dart-test';
  static const _host = 'localhost';
  static const _port = 4222;
  static const _monitoringPort = 8222;
  static const _image = 'nats:latest';
  static const _jetstreamFlag = '-js';
  static const _monitoringFlag = '-m';
  static const _monitoringPortStr = '$_monitoringPort';
  static const _portMapping = '$_port:$_port';
  static const _monitoringPortMapping = '$_monitoringPort:$_monitoringPort';

  // Docker commands
  static const _docker = 'docker';
  static const _startArgs = [
    'run',
    '-d',
    '--name',
    _containerName,
    '-p',
    _portMapping,
    '-p',
    _monitoringPortMapping,
    _image,
    _jetstreamFlag,
    _monitoringFlag,
    _monitoringPortStr,
  ];
  static const _stopArgs = ['stop', _containerName];
  // Health check configuration
  static const _maxRetries = 30;
  static const _retryDelay = Duration(milliseconds: 500);

  static int _refCount = 0;

  /// True when we detected a native NATS server and skipped Docker entirely.
  static bool _usingNative = false;

  /// The NATS URL to connect to.
  final String url = 'nats://$_host:$_port';

  DockerNats._();

  /// Starts a NATS Docker container, or reuses one already running.
  ///
  /// Reference-counted: the first call starts the container, subsequent
  /// calls increment the counter. Pair every [start] with a [stop].
  static Future<DockerNats> start() async {
    _refCount++;

    if (_refCount == 1) {
      await _startContainer();
    }

    return DockerNats._();
  }

  /// Decrements the reference count and stops the container when it hits zero.
  ///
  /// No-op when [_usingNative] is true — the native server is managed
  /// externally (e.g. by the CI runner or the developer's local environment).
  Future<void> stop() async {
    _refCount--;

    if (_refCount <= 0) {
      _refCount = 0;
      if (!_usingNative) {
        await Process.run(_docker, _stopArgs);
        await removeDockerContainer(_containerName);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Starts the Docker container, cleaning up any stale one first.
  ///
  /// If the Docker binary is not installed, falls back to checking whether a
  /// native NATS server is already listening on port [_port]. This supports
  /// CI environments (e.g. macOS GitHub Actions) that pre-install nats-server
  /// via a package manager instead of running Docker.
  static Future<void> _startContainer() async {
    if (!await isDockerAvailable()) {
      // No Docker — check for a native server instead.
      if (await isTcpReachable(_host, _port)) {
        _usingNative = true;
        return;
      }
      throw StateError(
        '[DockerNats] Docker is not installed and no native NATS server '
        'was detected on $_host:$_port. '
        'Either install Docker or start a NATS server with JetStream enabled.',
      );
    }

    // Remove any stale container with the same name.
    await removeDockerContainer(_containerName);

    final result = await Process.run(_docker, _startArgs);

    if (result.exitCode != 0) {
      throw StateError(
        '[DockerNats] Failed to start container.\n'
        'stdout: ${result.stdout}\n'
        'stderr: ${result.stderr}',
      );
    }

    await _waitForReady();
  }

  /// Waits for NATS to be fully ready by polling its HTTP health endpoint.
  static Future<void> _waitForReady() async {
    for (var attempt = 1; attempt <= _maxRetries; attempt++) {
      if (await _isServerHealthy()) return;
      if (attempt < _maxRetries) {
        await Future<void>.delayed(_retryDelay);
      }
    }

    throw NatsServerTimeoutException(
      '[DockerNats] NATS server did not become ready after '
      '${_maxRetries * _retryDelay.inMilliseconds}ms.',
    );
  }

  /// Returns `true` if the NATS monitoring endpoint reports healthy.
  static Future<bool> _isServerHealthy() async {
    try {
      final client = HttpClient()
        ..connectionTimeout = const Duration(milliseconds: 500);
      final request = await client.getUrl(
        Uri.parse('http://$_host:$_monitoringPort/healthz'),
      );
      final response = await request.close();
      await response.drain<void>();
      client.close();
      return response.statusCode == 200;
    } on Exception {
      return false;
    }
  }
}
