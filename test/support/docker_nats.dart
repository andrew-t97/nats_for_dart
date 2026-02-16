/// Docker-based NATS server lifecycle management for tests.
///
/// Automatically starts a Docker NATS container with JetStream enabled.
/// Uses reference counting so the container stays alive until the last
/// consumer calls [DockerNats.stop].
library;

import 'dart:io';

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
  static const _image = 'nats:latest';
  static const _jetstreamFlag = '-js';
  static const _portMapping = '$_port:$_port';

  // Docker commands
  static const _docker = 'docker';
  static const _startArgs = [
    'run', '-d', '--name', _containerName, '-p', _portMapping, _image,
    _jetstreamFlag,
  ];
  static const _stopArgs = ['stop', _containerName];
  static const _removeArgs = ['rm', '-f', _containerName];
  static const _checkArgs = ['info'];
  // Health check configuration
  static const _maxRetries = 30;
  static const _retryDelay = Duration(milliseconds: 500);

  static int _refCount = 0;

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
  Future<void> stop() async {
    _refCount--;

    if (_refCount <= 0) {
      _refCount = 0;
      await Process.run(_docker, _stopArgs);
      await Process.run(_docker, _removeArgs);
    }
  }

  // ---------------------------------------------------------------------------
  // Private helpers
  // ---------------------------------------------------------------------------

  /// Starts the Docker container, cleaning up any stale one first.
  static Future<void> _startContainer() async {
    final dockerCheck = await Process.run(_docker, _checkArgs);
    if (dockerCheck.exitCode != 0) {
      throw StateError(
        '[DockerNats] Docker is not available. '
        'Install Docker to run the test suite.\n'
        'stderr: ${dockerCheck.stderr}',
      );
    }

    // Remove any stale container with the same name.
    await Process.run(_docker, _removeArgs);

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

  /// Waits for NATS to accept TCP connections, retrying with a fixed delay.
  static Future<void> _waitForReady() async {
    for (var attempt = 1; attempt <= _maxRetries; attempt++) {
      if (await _isPortReachable(_host, _port)) return;
      if (attempt < _maxRetries) {
        await Future<void>.delayed(_retryDelay);
      }
    }

    throw DockerNatsTimeoutException(
      '[DockerNats] NATS server did not become ready after '
      '${_maxRetries * _retryDelay.inMilliseconds}ms.',
    );
  }

  /// Returns `true` if a TCP connection to [host]:[port] succeeds.
  static Future<bool> _isPortReachable(String host, int port) async {
    try {
      final socket = await Socket.connect(host, port,
          timeout: const Duration(milliseconds: 500));
      await socket.close();
      return true;
    } on SocketException {
      return false;
    } on OSError {
      return false;
    }
  }
}

/// Thrown when the NATS server does not start within the expected timeout.
class DockerNatsTimeoutException implements Exception {
  final String message;
  DockerNatsTimeoutException(this.message);

  @override
  String toString() => message;
}
