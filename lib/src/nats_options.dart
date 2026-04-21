import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import 'nats_bindings.g.dart';
import 'nats_exceptions.dart';
import 'nats_options_config.dart';

/// Library-internal FFI wrapper around `natsOptions`.
///
/// Bridges the immutable public [NatsOptions] config to the native option
/// setters. External callers should not construct this handle directly.
@internal
final class NatsOptionsHandle implements Finalizable {
  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(Pointer<natsOptions>)>>(
      natsOptions_Destroy,
    ).cast(),
  );

  Pointer<natsOptions>? _opts;
  bool _closed = false;

  /// Whether these options have been closed.
  bool get isClosed => _closed;

  /// Creates a new empty [NatsOptionsHandle].
  NatsOptionsHandle() {
    final optsPtrPtr = calloc<Pointer<natsOptions>>();
    try {
      checkStatus(natsOptions_Create(optsPtrPtr), 'natsOptions_Create');
      _opts = optsPtrPtr.value;
      _finalizer.attach(this, _opts!.cast(), detach: this);
    } finally {
      calloc.free(optsPtrPtr);
    }
  }

  /// Builds a [NatsOptionsHandle] from an immutable [NatsOptions] config and
  /// a positional [url].
  ///
  /// Validation runs first via [NatsOptions.validate] (pure Dart, no FFI) so
  /// contract violations surface as [ArgumentError] rather than opaque native
  /// status codes.
  ///
  /// Precedence for the server target:
  ///   * If `config.servers` is non-empty, `natsOptions_SetServers` is
  ///     called with that list and the positional [url] is ignored.
  ///   * Otherwise `natsOptions_SetURL` is called with [url].
  factory NatsOptionsHandle.fromConfig(NatsOptions config, String url) {
    config.validate();

    final handle = NatsOptionsHandle();
    try {
      if (config.servers.isNotEmpty) {
        handle.setServers(config.servers);
      } else {
        handle.setUrl(url);
      }

      void setIf<T>(T? value, void Function(T) apply) {
        if (value != null) apply(value);
      }

      setIf(config.name, handle.setName);
      setIf(config.user, (user) {
        // config.validate() guarantees password is non-null when user is set.
        handle.setUserInfo(user, config.password!);
      });
      setIf(config.token, handle.setToken);
      setIf(config.maxReconnect, handle.setMaxReconnect);
      setIf(config.reconnectWait, handle.setReconnectWait);
      setIf(config.reconnectBufSize, handle.setReconnectBufSize);
      setIf(config.verbose, handle.setVerbose);
      setIf(config.pedantic, handle.setPedantic);
      setIf(config.noRandomize, handle.setNoRandomize);
      setIf(config.pingInterval, handle.setPingInterval);
      setIf(config.maxPingsOut, handle.setMaxPingsOut);
      setIf(config.ioBufSize, handle.setIOBufSize);
      setIf(config.timeout, handle.setTimeout);
      setIf(config.credentialsFile, (file) {
        handle.setCredentialsFile(file, config.credentialsSeedFile);
      });
      return handle;
    } catch (_) {
      unawaited(handle.close());
      rethrow;
    }
  }

  /// The underlying native options pointer. Used by [NatsClient] to connect.
  Pointer<natsOptions> get nativePtr {
    _ensureAlive();
    return _opts!;
  }

  // ── Builder setters ────────────────────────────────────────────────

  /// Sets the server URL.
  void setUrl(String url) {
    _ensureAlive();
    final urlNative = url.toNativeUtf8();
    try {
      checkStatus(
        natsOptions_SetURL(_opts!, urlNative.cast()),
        'natsOptions_SetURL',
      );
    } finally {
      calloc.free(urlNative);
    }
  }

  /// Sets multiple server URLs.
  void setServers(List<String> servers) {
    _ensureAlive();
    final serverPtrs = calloc<Pointer<Char>>(servers.length);
    final nativePtrs = <Pointer<Utf8>>[];
    try {
      for (var i = 0; i < servers.length; i++) {
        final native = servers[i].toNativeUtf8();
        nativePtrs.add(native);
        serverPtrs[i] = native.cast();
      }
      checkStatus(
        natsOptions_SetServers(_opts!, serverPtrs, servers.length),
        'natsOptions_SetServers',
      );
    } finally {
      for (final ptr in nativePtrs) {
        calloc.free(ptr);
      }
      calloc.free(serverPtrs);
    }
  }

  /// Sets user name and password for authentication.
  void setUserInfo(String user, String password) {
    _ensureAlive();
    final userNative = user.toNativeUtf8();
    final passNative = password.toNativeUtf8();
    try {
      checkStatus(
        natsOptions_SetUserInfo(_opts!, userNative.cast(), passNative.cast()),
        'natsOptions_SetUserInfo',
      );
    } finally {
      calloc.free(userNative);
      calloc.free(passNative);
    }
  }

  /// Sets an authentication token.
  void setToken(String token) {
    _ensureAlive();
    final tokenNative = token.toNativeUtf8();
    try {
      checkStatus(
        natsOptions_SetToken(_opts!, tokenNative.cast()),
        'natsOptions_SetToken',
      );
    } finally {
      calloc.free(tokenNative);
    }
  }

  /// Sets the maximum number of reconnect attempts.
  void setMaxReconnect(int maxReconnect) {
    _ensureAlive();
    checkStatus(
      natsOptions_SetMaxReconnect(_opts!, maxReconnect),
      'natsOptions_SetMaxReconnect',
    );
  }

  /// Sets the wait time between reconnect attempts.
  void setReconnectWait(Duration wait) {
    _ensureAlive();
    checkStatus(
      natsOptions_SetReconnectWait(_opts!, wait.inMilliseconds),
      'natsOptions_SetReconnectWait',
    );
  }

  /// Sets the size of the internal reconnect buffer (in bytes).
  ///
  /// When a client is disconnected, messages published are buffered
  /// internally up to this size. If the buffer is full, further publish
  /// calls will return an error.
  void setReconnectBufSize(int size) {
    _ensureAlive();
    checkStatus(
      natsOptions_SetReconnectBufSize(_opts!, size),
      'natsOptions_SetReconnectBufSize',
    );
  }

  /// Sets the connection name, visible in server monitoring.
  void setName(String name) {
    _ensureAlive();
    final nameNative = name.toNativeUtf8();
    try {
      checkStatus(
        natsOptions_SetName(_opts!, nameNative.cast()),
        'natsOptions_SetName',
      );
    } finally {
      calloc.free(nameNative);
    }
  }

  /// Enables or disables verbose mode.
  ///
  /// When enabled, the server will acknowledge every protocol message.
  void setVerbose(bool verbose) {
    _ensureAlive();
    checkStatus(
      natsOptions_SetVerbose(_opts!, verbose),
      'natsOptions_SetVerbose',
    );
  }

  /// Enables or disables pedantic mode.
  ///
  /// When enabled, the server performs extra checks on protocol messages.
  void setPedantic(bool pedantic) {
    _ensureAlive();
    checkStatus(
      natsOptions_SetPedantic(_opts!, pedantic),
      'natsOptions_SetPedantic',
    );
  }

  /// Enables or disables server-list randomisation.
  ///
  /// When [noRandomize] is `true`, the client connects to servers in the
  /// order given rather than randomising the list.
  void setNoRandomize(bool noRandomize) {
    _ensureAlive();
    checkStatus(
      natsOptions_SetNoRandomize(_opts!, noRandomize),
      'natsOptions_SetNoRandomize',
    );
  }

  /// Sets the interval between client-to-server pings.
  void setPingInterval(Duration interval) {
    _ensureAlive();
    checkStatus(
      natsOptions_SetPingInterval(_opts!, interval.inMilliseconds),
      'natsOptions_SetPingInterval',
    );
  }

  /// Sets the maximum number of outstanding pings before considering the
  /// connection stale.
  void setMaxPingsOut(int maxPingsOut) {
    _ensureAlive();
    checkStatus(
      natsOptions_SetMaxPingsOut(_opts!, maxPingsOut),
      'natsOptions_SetMaxPingsOut',
    );
  }

  /// Sets the size of the internal read/write buffers (in bytes).
  void setIOBufSize(int size) {
    _ensureAlive();
    checkStatus(
      natsOptions_SetIOBufSize(_opts!, size),
      'natsOptions_SetIOBufSize',
    );
  }

  /// Sets the connection timeout.
  ///
  /// If the client cannot establish a connection within [timeout], the
  /// connect call will fail.
  void setTimeout(Duration timeout) {
    _ensureAlive();
    checkStatus(
      natsOptions_SetTimeout(_opts!, timeout.inMilliseconds),
      'natsOptions_SetTimeout',
    );
  }

  /// Sets the path to a user credentials file (JWT + seed).
  ///
  /// [credentialsFile] is the path to the credentials file — either a
  /// JWT-only file or a chained file containing both the JWT and the NKey
  /// seed. [seedFile] is optional and used only when the JWT and seed live
  /// in separate files.
  void setCredentialsFile(String credentialsFile, [String? seedFile]) {
    _ensureAlive();
    final credsNative = credentialsFile.toNativeUtf8();
    final seedNative = seedFile?.toNativeUtf8();
    try {
      checkStatus(
        natsOptions_SetUserCredentialsFromFiles(
          _opts!,
          credsNative.cast(),
          seedNative?.cast() ?? nullptr,
        ),
        'natsOptions_SetUserCredentialsFromFiles',
      );
    } finally {
      calloc.free(credsNative);
      if (seedNative != null) calloc.free(seedNative);
    }
  }

  // ── Cleanup ────────────────────────────────────────────────────────

  /// Closes the native options pointer.
  Future<void> close() {
    if (_closed) return Future.value();
    _closed = true;

    if (_opts != null) {
      _finalizer.detach(this);
      natsOptions_Destroy(_opts!);
      _opts = null;
    }

    return Future.value();
  }

  void _ensureAlive() {
    if (_closed) {
      throw StateError('NatsOptionsHandle has been closed');
    }
  }
}
