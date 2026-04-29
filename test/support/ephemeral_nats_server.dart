/// A per-test ephemeral NATS server.
///
/// This helper spins up a purpose-built server on a on-default port.
/// This is particularly useful for manipulating the client connectiion state.
///
/// Prefers a native `nats-server` child process when the binary is on PATH
/// and falls back to a Docker container otherwise. Both modes use
/// [waitUntilMonitoringHealthy] (against the server's `/healthz` endpoint)
/// for readiness — a bare TCP probe cannot confirm that the NATS protocol
/// layer is ready to accept client connections.
library;

import 'dart:io';

import 'nats_server_support.dart';

class EphemeralNatsServer {
  static const _host = '127.0.0.1';

  final int port;
  final int monitoringPort;
  final String? _containerName;
  final Process? _nativeProcess;

  /// The NATS URL to connect to.
  String get url => 'nats://$_host:$port';

  EphemeralNatsServer._({
    required this.port,
    required this.monitoringPort,
    String? containerName,
    Process? nativeProcess,
  }) : _containerName = containerName,
       _nativeProcess = nativeProcess;

  /// Starts an ephemeral NATS server on an OS-assigned ephemeral port. When
  /// [containerName] is supplied it names the Docker container (unused in
  /// native mode); any stale container with the same name is removed first.
  ///
  /// Retries up to 3 times with fresh ports if a bind race loses to another
  /// process between [reserveEphemeralPort] returning and `nats-server`
  /// binding.
  static Future<EphemeralNatsServer> start({
    String containerName = 'nats-dart-test-ephemeral',
  }) async {
    // Native nats-server takes priority over Docker. Mirrors DockerNats:
    // Docker on windows-latest is flaky and `docker info` can hang long
    // enough to blow the test framework's 30s timeout.
    final useNative = await isNatsServerOnPath();
    if (!useNative && !await isDockerAvailable()) {
      throw StateError(
        '[EphemeralNatsServer] Neither `nats-server` is on PATH nor Docker '
        'is available. Install one to run these tests.',
      );
    }

    Object? lastError;
    for (var attempt = 1; attempt <= 3; attempt++) {
      final port = await reserveEphemeralPort();
      final monitoringPort = await reserveEphemeralPort();
      try {
        if (useNative) {
          return await _startNative(port: port, monitoringPort: monitoringPort);
        }
        return await _startDocker(
          port: port,
          monitoringPort: monitoringPort,
          containerName: containerName,
        );
      } on Object catch (e) {
        lastError = e;
      }
    }
    throw StateError(
      '[EphemeralNatsServer] failed to start after 3 attempts: $lastError',
    );
  }

  /// Stops the server. Sends SIGTERM (Docker: via `docker stop`; native:
  /// directly) so existing client connections observe a clean close rather
  /// than a TCP reset.
  Future<void> stop() async {
    final containerName = _containerName;
    if (containerName != null) {
      await runWithTimeout(
        () => Process.run('docker', ['stop', containerName]),
        timeout: const Duration(seconds: 5),
        context: 'docker stop $containerName',
      );
      await runWithTimeout(
        () => removeDockerContainer(containerName),
        timeout: const Duration(seconds: 5),
        context: 'docker rm -f $containerName',
      );
      return;
    }
    final process = _nativeProcess;
    if (process != null) {
      process.kill(ProcessSignal.sigterm);
      try {
        await runWithTimeout(
          () => process.exitCode,
          timeout: const Duration(seconds: 5),
          context: 'nats-server pid=${process.pid} graceful exit',
        );
      } on NatsServerTimeoutException {
        // SIGTERM ignored (or TerminateProcess returned without reaping on
        // Windows). Escalate to SIGKILL so the test does not hang.
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      }
    }
  }

  static Future<EphemeralNatsServer> _startDocker({
    required int port,
    required int monitoringPort,
    required String containerName,
  }) async {
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
        '$port:4222',
        '-p',
        '$monitoringPort:$monitoringPort',
        kDefaultNatsImage,
        '-m',
        '$monitoringPort',
      ],
      context: 'EphemeralNatsServer container $containerName',
    );
    await waitUntilTcpReachable(
      _host,
      port,
      context: 'EphemeralNatsServer container $containerName NATS port',
    );

    return EphemeralNatsServer._(
      port: port,
      monitoringPort: monitoringPort,
      containerName: containerName,
    );
  }

  static Future<EphemeralNatsServer> _startNative({
    required int port,
    required int monitoringPort,
  }) async {
    final Process process;
    try {
      process = await Process.start('nats-server', [
        '-p',
        '$port',
        '-m',
        '$monitoringPort',
      ]);
    } on ProcessException catch (e) {
      throw StateError(
        '[EphemeralNatsServer] Failed to launch `nats-server` even though it '
        'reported a version on PATH — likely a permissions or PATH race.\n$e',
      );
    }

    // Drain stdio so the child's pipe buffers do not fill and block it.
    process.stdout.listen((_) {});
    process.stderr.listen((_) {});

    // Race the readiness wait against the process dying — without this, a
    // nats-server that fails to bind takes 15s to surface as a timeout
    // instead of as the real exit code.
    final exited = process.exitCode.then<Object>(
      (code) => StateError(
        '[EphemeralNatsServer] nats-server exited with code $code before '
        'becoming ready',
      ),
    );

    final ready = (() async {
      await waitUntilMonitoringHealthy(
        _host,
        monitoringPort,
        context: 'EphemeralNatsServer native pid=${process.pid}',
      );
      await waitUntilTcpReachable(
        _host,
        port,
        context: 'EphemeralNatsServer native pid=${process.pid} NATS port',
      );
    })();

    final outcome = await Future.any([ready, exited]);
    if (outcome is StateError) {
      throw outcome;
    }

    return EphemeralNatsServer._(
      port: port,
      monitoringPort: monitoringPort,
      nativeProcess: process,
    );
  }
}
