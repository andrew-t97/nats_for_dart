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
  static const _image = 'nats:latest';

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
    final useNative = await _isNatsServerOnPath();
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

  static Future<bool> _isNatsServerOnPath() async {
    try {
      final result = await Process.run('nats-server', ['--version']);
      return result.exitCode == 0;
    } on ProcessException {
      return false;
    }
  }

  /// Stops the server. Sends SIGTERM (Docker: via `docker stop`; native:
  /// directly) so existing client connections observe a clean close rather
  /// than a TCP reset.
  Future<void> stop() async {
    final stopwatch = Stopwatch()..start();
    void mark(String label) {
      print('[INSTR][stop +${stopwatch.elapsedMilliseconds}ms] $label');
    }

    final containerName = _containerName;
    if (containerName != null) {
      mark('docker stop begin: $containerName');
      await runWithTimeout(
        () => Process.run('docker', ['stop', containerName]),
        timeout: const Duration(seconds: 5),
        context: 'docker stop $containerName',
      );
      mark('docker stop returned');
      await runWithTimeout(
        () => removeDockerContainer(containerName),
        timeout: const Duration(seconds: 5),
        context: 'docker rm -f $containerName',
      );
      mark('docker rm returned');
      return;
    }
    final process = _nativeProcess;
    if (process != null) {
      mark('native: SIGTERM pid=${process.pid}');
      process.kill(ProcessSignal.sigterm);
      try {
        await runWithTimeout(
          () => process.exitCode,
          timeout: const Duration(seconds: 5),
          context: 'nats-server pid=${process.pid} graceful exit',
        );
        mark('native: graceful exit reaped');
      } on NatsServerTimeoutException {
        mark('native: graceful timed out, escalating to SIGKILL');
        // SIGTERM ignored (or TerminateProcess returned without reaping on
        // Windows). Escalate to SIGKILL so the test does not hang.
        process.kill(ProcessSignal.sigkill);
        mark('native: after SIGKILL kill call');
        await process.exitCode;
        mark('native: SIGKILL reaped');
      }
    }
  }

  static Future<EphemeralNatsServer> _startDocker({
    required int port,
    required int monitoringPort,
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
      '-p',
      '$monitoringPort:$monitoringPort',
      _image,
      '-m',
      '$monitoringPort',
    ]);

    if (result.exitCode != 0) {
      throw StateError(
        '[EphemeralNatsServer] Failed to start container $containerName.\n'
        'stdout: ${result.stdout}\n'
        'stderr: ${result.stderr}',
      );
    }

    await waitUntilMonitoringHealthy(
      _host,
      monitoringPort,
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
    final stopwatch = Stopwatch()..start();
    void mark(String label) {
      print('[INSTR][_startNative +${stopwatch.elapsedMilliseconds}ms] $label');
    }

    mark('begin (port=$port monitoring=$monitoringPort)');

    final Process process;
    try {
      process = await Process.start('nats-server', [
        '-p',
        '$port',
        '-m',
        '$monitoringPort',
      ]);
      mark('Process.start returned pid=${process.pid}');
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
      mark('monitoring /healthz reachable');
      await waitUntilTcpReachable(
        _host,
        port,
        context: 'EphemeralNatsServer native pid=${process.pid} NATS port',
      );
      mark('NATS TCP port reachable');
    })();

    final outcome = await Future.any([ready, exited]);
    if (outcome is StateError) {
      throw outcome;
    }
    mark('start complete');

    return EphemeralNatsServer._(
      port: port,
      monitoringPort: monitoringPort,
      nativeProcess: process,
    );
  }
}
