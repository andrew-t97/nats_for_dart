import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'nats_bindings.g.dart';
import 'nats_bindings_loader.dart';

/// Exception thrown when a NATS C library call returns a non-OK status.
final class NatsException implements Exception {
  /// The [natsStatus] error code returned by the C library.
  final natsStatus status;

  /// Human-readable description of the error.
  final String message;

  NatsException(this.status, [String? message])
      : message = message ?? 'NATS error: ${status.name} (${status.value})';

  @override
  String toString() => 'NatsException($message)';
}

/// Exception thrown when a request-reply publish receives a "503 No
/// Responders" status from the NATS server (v2.2+), indicating that no
/// subscriber is available on the target subject.
final class NatsNoRespondersException extends NatsException {
  NatsNoRespondersException(String subject)
      : super(natsStatus.NATS_NO_RESPONDERS,
              'No responders on subject: $subject');
}

/// Checks a [natsStatus] value and throws a [NatsException] if it is not
/// [natsStatus.NATS_OK].
///
/// When the status indicates an error, the thread-local error string from
/// the C library is included in the exception message for richer diagnostics.
void checkStatus(natsStatus status, [String? context]) {
  if (status != natsStatus.NATS_OK) {
    // Retrieve the thread-local error description from the C library.
    String? nativeError;
    try {
      final errPtr = bindings.nats_GetLastError(nullptr);
      if (errPtr != nullptr) {
        nativeError = errPtr.cast<Utf8>().toDartString();
      }
    } catch (_) {
      // If we can't read the native error, fall back to the status name.
    }

    final parts = <String>[
      ?context,
      status.name,
      ?nativeError,
    ];
    throw NatsException(status, parts.join(': '));
  }
}
