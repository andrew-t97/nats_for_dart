/// A per-test ephemeral NATS server.
///
/// This helper spins up a purpose-built server on a on-default port.
/// This is particularly useful for manipulating the client connectiion state.
///
/// Automatically chooses a Docker container when Docker is available, and
/// falls back to a native `nats-server` child process otherwise. Both
/// modes use [waitUntilTcpReachable] for readiness.
library;

import 'dart:io';

import 'nats_server_support.dart';

class EphemeralNatsServer {
  static const _host = '127.0.0.1';
  static const _image = 'nats:latest';

  final int port;
  final String? _containerName;
  final Process? _nativeProcess;

  /// The NATS URL to connect to.
  String get url => 'nats://$_host:$port';

  EphemeralNatsServer._({
    required this.port,
    String? containerName,
    Process? nativeProcess,
  }) : _containerName = containerName,
       _nativeProcess = nativeProcess;

  /// Starts an ephemeral NATS server on [port]. When [containerName] is
  /// supplied it names the Docker container (unused in native mode); any
  /// stale container with the same name is removed first.
  static Future<EphemeralNatsServer> start({
    int port = 4299,
    String containerName = 'nats-dart-test-ephemeral',
  }) async {
    if (await isDockerAvailable()) {
      return _startDocker(port: port, containerName: containerName);
    }
    return _startNative(port: port);
  }

  /// Stops the server. Sends SIGTERM (Docker: via `docker stop`; native:
  /// directly) so existing client connections observe a clean close rather
  /// than a TCP reset.
  Future<void> stop() async {
    final containerName = _containerName;
    if (containerName != null) {
      await Process.run('docker', ['stop', containerName]);
      await removeDockerContainer(containerName);
      return;
    }
    final process = _nativeProcess;
    if (process != null) {
      process.kill(ProcessSignal.sigterm);
      await process.exitCode;
    }
  }

  static Future<EphemeralNatsServer> _startDocker({
    required int port,
    required String containerName,
  }) async {
    await removeDockerContainer(containerName);

    final result = await Process.run('docker', [
      'run',
      '-d',
      '--name',
      containerName,
      '-p',
      '$port:4222',
      _image,
    ]);

    if (result.exitCode != 0) {
      throw StateError(
        '[EphemeralNatsServer] Failed to start container $containerName.\n'
        'stdout: ${result.stdout}\n'
        'stderr: ${result.stderr}',
      );
    }

    await waitUntilTcpReachable(
      _host,
      port,
      context: 'EphemeralNatsServer container $containerName',
    );

    return EphemeralNatsServer._(port: port, containerName: containerName);
  }

  static Future<EphemeralNatsServer> _startNative({required int port}) async {
    final Process process;
    try {
      process = await Process.start('nats-server', ['-p', '$port']);
    } on ProcessException catch (e) {
      throw StateError(
        '[EphemeralNatsServer] Docker is unavailable and `nats-server` is '
        'not on PATH. Install Docker or the nats-server binary.\n$e',
      );
    }

    // Drain stdio so the child's pipe buffers do not fill and block it.
    process.stdout.listen((_) {});
    process.stderr.listen((_) {});

    await waitUntilTcpReachable(
      _host,
      port,
      context: 'EphemeralNatsServer native pid=${process.pid}',
    );

    return EphemeralNatsServer._(port: port, nativeProcess: process);
  }
}
