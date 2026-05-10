/// FFI codec for [NatsHeaders] ↔ `natsMsg`.
///
/// All `natsMsgHeader_*` calls funnel through this file; no other Dart
/// source touches them directly.
library;

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import '../nats_bindings.g.dart';
import '../nats_exceptions.dart';
import '../nats_headers.dart';

/// Writes [headers] onto [msg] via `natsMsgHeader_Set`/`_Add`. No-op when
/// [headers] is empty.
@internal
void writeHeadersToMsg(Pointer<natsMsg> msg, NatsHeaders headers) {
  if (headers.isEmpty) return;

  for (final key in headers.keys) {
    final values = headers.getAll(key);
    if (values.isEmpty) continue;

    final keyNative = key.toNativeUtf8();
    try {
      // First value via Set (replaces any existing); subsequent values via
      // Add (appends, preserving Add order).
      final firstNative = values.first.toNativeUtf8();
      try {
        checkStatus(
          natsMsgHeader_Set(msg, keyNative.cast(), firstNative.cast()),
          'natsMsgHeader_Set',
        );
      } finally {
        calloc.free(firstNative);
      }

      for (var i = 1; i < values.length; i++) {
        final valueNative = values[i].toNativeUtf8();
        try {
          checkStatus(
            natsMsgHeader_Add(msg, keyNative.cast(), valueNative.cast()),
            'natsMsgHeader_Add',
          );
        } finally {
          calloc.free(valueNative);
        }
      }
    } finally {
      calloc.free(keyNative);
    }
  }
}

/// Reads all headers off [msg] into a [NatsHeaders]. Returns
/// [NatsHeaders.empty] when the message carries no headers.
@internal
NatsHeaders readHeadersFromMsg(Pointer<natsMsg> msg) {
  final keysPtrPtr = calloc<Pointer<Pointer<Char>>>();
  final keyCountPtr = calloc<Int>();
  try {
    final keysStatus = natsMsgHeader_Keys(msg, keysPtrPtr, keyCountPtr);
    if (keysStatus == natsStatus.NATS_NOT_FOUND) {
      return const NatsHeaders.empty();
    }
    checkStatus(keysStatus, 'natsMsgHeader_Keys');

    final keyCount = keyCountPtr.value;
    if (keyCount == 0) {
      return const NatsHeaders.empty();
    }

    // Outer array (`char**`) is caller-owned and must be freed with calloc.free.
    // Inner strings (`char*`) are message-owned — never free them.
    final keysArray = keysPtrPtr.value;
    final entries = <MapEntry<String, String>>[];
    try {
      for (var i = 0; i < keyCount; i++) {
        final keyPtr = keysArray[i];
        final key = keyPtr.cast<Utf8>().toDartString();

        final valuesPtrPtr = calloc<Pointer<Pointer<Char>>>();
        final valueCountPtr = calloc<Int>();
        try {
          final valuesStatus = natsMsgHeader_Values(
            msg,
            keyPtr,
            valuesPtrPtr,
            valueCountPtr,
          );
          if (valuesStatus == natsStatus.NATS_NOT_FOUND) {
            continue;
          }
          checkStatus(valuesStatus, 'natsMsgHeader_Values');

          final valueCount = valueCountPtr.value;
          final valuesArray = valuesPtrPtr.value;
          try {
            for (var j = 0; j < valueCount; j++) {
              final value = valuesArray[j].cast<Utf8>().toDartString();
              entries.add(MapEntry(key, value));
            }
          } finally {
            calloc.free(valuesArray);
          }
        } finally {
          calloc.free(valuesPtrPtr);
          calloc.free(valueCountPtr);
        }
      }
    } finally {
      calloc.free(keysArray);
    }

    if (entries.isEmpty) {
      return const NatsHeaders.empty();
    }
    return NatsHeaders.fromEntries(entries);
  } finally {
    calloc.free(keysPtrPtr);
    calloc.free(keyCountPtr);
  }
}
