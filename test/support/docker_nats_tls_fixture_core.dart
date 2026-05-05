/// Shared lifecycle and orchestration for Docker NATS fixtures that mount
/// a server config + cert directory (`DockerNatsTls`, `DockerNatsMtls`).
///
/// Each public wrapper instantiates its own [DockerNatsTlsFixtureCore], so
/// ref-counts and native-detection state stay independent per fixture.
library;

import 'dart:io';

import 'nats_server_support.dart';

/// Per-fixture lifecycle state and Docker orchestration. Not part of the
/// public test-support API — instantiated only by the sibling `DockerNatsTls*`
/// wrappers.
class DockerNatsTlsFixtureCore {
  static const _host = 'localhost';
  static const _certsHostDir = 'test/support/certs';
  static const _certsContainerDir = '/certs';
  static const _docker = 'docker';

  final String containerName;
  final int port;
  final int monitoringPort;
  final String configHostPath;
  final String configContainerPath;
  final String label;

  int _refCount = 0;
  bool _usingNative = false;

  DockerNatsTlsFixtureCore({
    required this.containerName,
    required this.port,
    required this.monitoringPort,
    required this.configHostPath,
    required this.configContainerPath,
    required this.label,
  });

  String get url => 'tls://$_host:$port';

  Future<void> start() async {
    _refCount++;

    if (_refCount == 1) {
      await _startContainer();
    }
  }

  Future<void> stop() async {
    _refCount--;

    if (_refCount <= 0) {
      _refCount = 0;
      if (!_usingNative) {
        await Process.run(_docker, ['stop', containerName]);
        await removeDockerContainer(containerName);
      }
    }
  }

  /// Resolution order, in priority:
  ///   1. Native NATS server already listening on [port] — adopted as-is and
  ///      managed externally.
  ///   2. Docker — start a fresh container with the fixture's config mount.
  ///   3. Neither — throw, with guidance for the developer.
  Future<void> _startContainer() async {
    if (await isTcpReachable(_host, port)) {
      _usingNative = true;
      return;
    }

    if (!await isDockerAvailable()) {
      throw StateError(
        '[$label] No NATS server detected on $_host:$port and '
        'Docker is not available. '
        'Either install Docker or start a NATS server with the '
        'bundled config ($configHostPath).',
      );
    }

    final certsHostAbs = _toDockerPath(_absolutePath(_certsHostDir));
    final configHostAbs = _toDockerPath(_absolutePath(configHostPath));

    await startDockerNatsContainer(
      host: _host,
      monitoringPort: monitoringPort,
      containerName: containerName,
      dockerRunArgs: [
        'run',
        '-d',
        '--name',
        containerName,
        '-p',
        '$port:$port',
        '-p',
        '$monitoringPort:$monitoringPort',
        '-v',
        '$certsHostAbs:$_certsContainerDir:ro',
        '-v',
        '$configHostAbs:$configContainerPath:ro',
        kDefaultNatsImage,
        '-c',
        configContainerPath,
      ],
      context: '[$label] NATS server',
    );
  }

  /// Resolves [relative] against the current working directory and asserts
  /// the target exists — Docker `-v` silently creates missing source paths
  /// as empty directories, so a stray typo would surface as an opaque TLS
  /// handshake failure instead of a clear "file not found".
  String _absolutePath(String relative) {
    final absolute = File(relative).absolute.path;
    if (!FileSystemEntity.isFileSync(absolute) &&
        !FileSystemEntity.isDirectorySync(absolute)) {
      throw StateError(
        '[$label] Fixture path not found: $absolute. '
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
