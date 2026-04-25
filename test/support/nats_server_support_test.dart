import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';

import 'nats_server_support.dart';

void main() {
  group('runWithTimeout', () {
    test('returns the awaited value when it completes in time', () async {
      final result = await runWithTimeout(
        () async => 42,
        timeout: const Duration(seconds: 1),
        context: 'fast op',
      );
      expect(result, 42);
    });

    test('throws NatsServerTimeoutException tagged with context', () async {
      final pending = Completer<void>();
      addTearDown(pending.complete);
      await expectLater(
        runWithTimeout(
          () => pending.future,
          timeout: const Duration(milliseconds: 50),
          context: 'slow op',
        ),
        throwsA(
          isA<NatsServerTimeoutException>().having(
            (e) => e.message,
            'message',
            contains('slow op'),
          ),
        ),
      );
    });
  });

  test('reserveEphemeralPort returns a usable, non-zero port', () async {
    final port = await reserveEphemeralPort();
    expect(port, greaterThan(0));
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await socket.close();
  });
}
