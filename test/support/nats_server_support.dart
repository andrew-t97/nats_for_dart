/// Shared primitives for NATS test-server helpers.
///
/// Both the shared, ref-counted `DockerNats` fixture and the per-test
/// `EphemeralNatsServer` helper delegate Docker availability checks,
/// TCP reachability probes, and container cleanup to the functions here.
library;

import 'dart:io';

/// Returns `true` if `docker info` succeeds, meaning the Docker daemon is
/// reachable and we can launch containers. Returns `false` when the binary
/// is missing or the daemon is not running — callers use this to decide
/// whether to fall back to a native `nats-server` process.
Future<bool> isDockerAvailable() async {
  try {
    final result = await Process.run('docker', ['info']);
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

/// One-shot TCP reachability check. Returns `true` if a TCP connection to
/// `host:port` succeeds within [timeout]; otherwise `false`.
Future<bool> isTcpReachable(
  String host,
  int port, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  try {
    final socket = await Socket.connect(host, port, timeout: timeout);
    socket.destroy();
    return true;
  } on Exception {
    return false;
  }
}

/// Polls [isTcpReachable] until it succeeds or the retry budget is
/// exhausted. Throws [NatsServerTimeoutException] tagged with [context]
/// when the budget runs out.
Future<void> waitUntilTcpReachable(
  String host,
  int port, {
  Duration retryDelay = const Duration(milliseconds: 250),
  int maxRetries = 40,
  String context = 'NATS server',
}) async {
  for (var attempt = 1; attempt <= maxRetries; attempt++) {
    if (await isTcpReachable(
      host,
      port,
      timeout: const Duration(milliseconds: 500),
    )) {
      return;
    }
    if (attempt < maxRetries) await Future<void>.delayed(retryDelay);
  }
  throw NatsServerTimeoutException(
    '$context did not become reachable on $host:$port after '
    '${maxRetries * retryDelay.inMilliseconds}ms',
  );
}

/// One-shot NATS monitoring health check. Returns `true` when the server's
/// `/healthz` endpoint on `host:monitoringPort` responds with HTTP 200
/// within [timeout]; otherwise `false`. `/healthz` is NATS' readiness
/// endpoint — it signals that the server is accepting client connections,
/// which a bare TCP probe cannot confirm.
Future<bool> isMonitoringHealthy(
  String host,
  int monitoringPort, {
  Duration timeout = const Duration(milliseconds: 500),
}) async {
  final client = HttpClient()..connectionTimeout = timeout;
  try {
    final request = await client.getUrl(
      Uri.parse('http://$host:$monitoringPort/healthz'),
    );
    final response = await request.close();
    await response.drain<void>();
    return response.statusCode == 200;
  } on Exception {
    return false;
  } finally {
    client.close();
  }
}

/// Polls [isMonitoringHealthy] until it succeeds or the retry budget is
/// exhausted. Throws [NatsServerTimeoutException] tagged with [context]
/// when the budget runs out.
Future<void> waitUntilMonitoringHealthy(
  String host,
  int monitoringPort, {
  Duration retryDelay = const Duration(milliseconds: 500),
  int maxRetries = 30,
  String context = 'NATS server',
}) async {
  for (var attempt = 1; attempt <= maxRetries; attempt++) {
    if (await isMonitoringHealthy(host, monitoringPort)) return;
    if (attempt < maxRetries) await Future<void>.delayed(retryDelay);
  }
  throw NatsServerTimeoutException(
    '$context did not become ready via http://$host:$monitoringPort/healthz '
    'after ${maxRetries * retryDelay.inMilliseconds}ms',
  );
}

/// Removes a Docker container by name, forcing removal. Safe to call even
/// when no container with that name exists — Docker treats a missing
/// container as a no-op under `rm -f`.
Future<void> removeDockerContainer(String name) async {
  await Process.run('docker', ['rm', '-f', name]);
}

/// Thrown when a test NATS server does not become reachable in time.
class NatsServerTimeoutException implements Exception {
  final String message;
  NatsServerTimeoutException(this.message);

  @override
  String toString() => message;
}
