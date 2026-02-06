import 'dart:ffi';
import 'dart:io' show Platform;

import 'nats_bindings.g.dart';

/// Resolves and opens the NATS C shared library for the current platform.
DynamicLibrary _openNatsLibrary() {
  if (Platform.isMacOS) {
    try {
      return DynamicLibrary.open('/opt/homebrew/opt/cnats/lib/libnats.dylib');
    } catch (_) {
      return DynamicLibrary.open('libnats.dylib');
    }
  } else if (Platform.isLinux) {
    try {
      return DynamicLibrary.open('/home/linuxbrew/.linuxbrew/lib/libnats.so');
    } catch (_) {
      return DynamicLibrary.open('libnats.so');
    }
  }
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}

/// Lazily-initialised singleton for the underlying [DynamicLibrary].
///
/// Exposed so that wrapper classes can look up C destroy function pointers
/// for use with [NativeFinalizer].
DynamicLibrary? _natsLib;

/// Returns the shared [DynamicLibrary] handle to the NATS C library.
DynamicLibrary get natsLib => _natsLib ??= _openNatsLibrary();

/// Lazily-initialised singleton bindings instance.
NatsBindings? _bindings;

/// Returns the shared [NatsBindings] instance, opening the native library on
/// first access.
NatsBindings get bindings => _bindings ??= NatsBindings(natsLib);
