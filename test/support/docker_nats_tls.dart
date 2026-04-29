/// Docker-based NATS server lifecycle management for TLS tests.
///
/// Sibling of [DockerNats] that runs `nats-server` with a TLS-enabled
/// config. Uses reference counting so the container stays alive until the
/// last consumer calls [DockerNatsTls.stop].
library;

import 'dart:io';

import 'nats_server_support.dart';

/// Manages a TLS-enabled Docker NATS container for integration tests.
///
/// Usage:
/// ```dart
/// late DockerNatsTls nats;
/// setUpAll(() async => nats = await DockerNatsTls.start());
/// tearDownAll(() async => await nats.stop());
/// ```
class DockerNatsTls {
  // Container configuration
  static const _containerName = 'nats-dart-test-tls';
  static const _host = 'localhost';
  static const _port = 4223;
  static const _monitoringPort = 8223;
  static const _image = 'nats:latest';

  // On-host fixture paths, resolved relative to the package root. `dart test`
  // sets CWD to the package root, so these are valid for every supported
  // invocation (full suite, single file, aggregated runner).
  static const _certsHostDir = 'test/support/certs';
  static const _configHostPath = 'test/support/nats-tls.conf';

  // In-container paths that `nats-tls.conf` references.
  static const _certsContainerDir = '/certs';
  static const _configContainerPath = '/etc/nats/nats-tls.conf';

  // Docker commands
  static const _docker = 'docker';
  static const _stopArgs = ['stop', _containerName];

  // Health check configuration
  static const _maxRetries = 30;
  static const _retryDelay = Duration(milliseconds: 500);

  static int _refCount = 0;

  /// True when we detected a native TLS NATS server and skipped Docker.
  static bool _usingNative = false;

  /// The NATS URL to connect to — `tls://` so callers can rely on the C
  /// library's URL-driven TLS auto-enable.
  final String url = 'tls://$_host:$_port';

  DockerNatsTls._();

  /// Starts a TLS NATS Docker container, or reuses one already running.
  ///
  /// Reference-counted: the first call starts the container, subsequent
  /// calls increment the counter. Pair every [start] with a [stop].
  static Future<DockerNatsTls> start() async {
    _refCount++;

    if (_refCount == 1) {
      await _startContainer();
    }

    return DockerNatsTls._();
  }

  /// Decrements the reference count and stops the container when it hits zero.
  ///
  /// No-op when [_usingNative] is true — the native server is managed
  /// externally (e.g. by the CI runner).
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

  /// Starts the TLS NATS server fixture.
  ///
  /// Resolution order, in priority:
  ///   1. Native TLS server already listening on [_port] — adopted as-is and
  ///      managed externally.
  ///   2. Docker — start a fresh TLS-enabled container.
  ///   3. Neither — throw, with guidance for the developer.
  static Future<void> _startContainer() async {
    if (await isTcpReachable(_host, _port)) {
      _usingNative = true;
      return;
    }

    if (!await isDockerAvailable()) {
      throw StateError(
        '[DockerNatsTls] No TLS NATS server detected on $_host:$_port and '
        'Docker is not available. '
        'Either install Docker or start a TLS-enabled NATS server with the '
        'bundled config (test/support/nats-tls.conf).',
      );
    }

    await removeDockerContainer(_containerName);

    final certsHostAbs = _toDockerPath(_absolutePath(_certsHostDir));
    final configHostAbs = _toDockerPath(_absolutePath(_configHostPath));

    final result = await Process.run(_docker, [
      'run',
      '-d',
      '--name',
      _containerName,
      '-p',
      '$_port:$_port',
      '-p',
      '$_monitoringPort:$_monitoringPort',
      '-v',
      '$certsHostAbs:$_certsContainerDir:ro',
      '-v',
      '$configHostAbs:$_configContainerPath:ro',
      _image,
      '-c',
      _configContainerPath,
    ]);

    if (result.exitCode != 0) {
      throw StateError(
        '[DockerNatsTls] Failed to start container.\n'
        'stdout: ${result.stdout}\n'
        'stderr: ${result.stderr}',
      );
    }

    await waitUntilMonitoringHealthy(
      _host,
      _monitoringPort,
      retryDelay: _retryDelay,
      maxRetries: _maxRetries,
      context: '[DockerNatsTls] NATS server',
    );
  }

  /// Resolves [relative] against the current working directory and asserts
  /// the target exists — Docker `-v` silently creates missing source paths
  /// as empty directories, so a stray typo would surface as an opaque TLS
  /// handshake failure instead of a clear "file not found".
  static String _absolutePath(String relative) {
    final absolute = File(relative).absolute.path;
    if (!FileSystemEntity.isFileSync(absolute) &&
        !FileSystemEntity.isDirectorySync(absolute)) {
      throw StateError(
        '[DockerNatsTls] Fixture path not found: $absolute. '
        'Run `dart test` from the package root.',
      );
    }
    return absolute;
  }

  /// Converts a host absolute path to a form Docker's `-v` parser accepts on
  /// every platform. On Windows, `File(...).absolute.path` yields a mixed-
  /// separator drive-letter path (e.g. `D:\a\repo\test/support/certs`)
  /// whose embedded colon makes Docker treat `D` as the source. The
  /// `/d/a/repo/test/support/certs` form sidesteps the colon ambiguity and
  /// is the shape the Linux-engine Docker daemon (used by GitHub's Windows
  /// runners) accepts. macOS/Linux paths pass through unchanged.
  static String _toDockerPath(String absolutePath) {
    if (!Platform.isWindows) return absolutePath;
    final match = RegExp(r'^([A-Za-z]):[\\/](.*)$').firstMatch(absolutePath);
    if (match == null) return absolutePath;
    final drive = match.group(1)!.toLowerCase();
    final rest = match.group(2)!.replaceAll(r'\', '/');
    return '/$drive/$rest';
  }
}
