import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'nats_bindings.g.dart';
import 'nats_exceptions.dart';

/// Represents an error reported by the NATS C library's asynchronous error
/// handler.
final class NatsError {
  /// The [natsStatus] error code.
  final natsStatus status;

  NatsError(this.status);

  @override
  String toString() => 'NatsError(${status.name})';
}

/// The native callback for disconnected events.
///
/// For `StreamController<void>`, Dart requires passing an explicit value —
/// `null` is the idiomatic sentinel for void streams.
void _onDisconnected(Pointer<natsConnection> nc, Pointer<Void> closure) {
  final id = closure.address;
  final controller = NatsOptions._lifecycleRoutes[id];
  if (controller != null && !controller.isClosed) {
    controller.add(null);
  }
}

/// The native callback for reconnected events.
void _onReconnected(Pointer<natsConnection> nc, Pointer<Void> closure) {
  final id = closure.address;
  final controller = NatsOptions._lifecycleRoutes[id];
  if (controller != null && !controller.isClosed) {
    controller.add(null);
  }
}

/// The native callback for closed events.
void _onClosed(Pointer<natsConnection> nc, Pointer<Void> closure) {
  final id = closure.address;
  final controller = NatsOptions._lifecycleRoutes[id];
  if (controller != null && !controller.isClosed) {
    controller.add(null);
  }
}

/// The native callback for error events.
void _onError(
  Pointer<natsConnection> nc,
  Pointer<natsSubscription> subscription,
  int err,
  Pointer<Void> closure,
) {
  final id = closure.address;
  final controller = NatsOptions._errorRoutes[id];
  if (controller != null && !controller.isClosed) {
    controller.add(NatsError(natsStatus.fromValue(err)));
  }
}

/// Builder-style wrapper around `natsOptions` for configuring connections.
///
/// Exposes lifecycle event streams (`onDisconnected`, `onReconnected`,
/// `onClosed`) and an error stream (`onError`) via
/// `NativeCallable.listener()`.
final class NatsOptions implements Finalizable {
  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(Pointer<natsOptions>)>>(
      natsOptions_Destroy,
    ).cast(),
  );

  Pointer<natsOptions>? _opts;
  bool _closed = false;

  // ── Routing tables for lifecycle callbacks ──────────────────────────

  /// Routes for lifecycle callbacks (disconnected, reconnected, closed).
  /// Keyed by a unique ID per callback.
  static final Map<int, StreamController<void>> _lifecycleRoutes = {};

  /// Routes for error callbacks. Keyed by a unique ID.
  static final Map<int, StreamController<NatsError>> _errorRoutes = {};

  static int _nextId = 1;

  // ── Per-instance callback state ────────────────────────────────────

  int? _disconnectedId;
  StreamController<void>? _disconnectedController;
  NativeCallable<Void Function(Pointer<natsConnection>, Pointer<Void>)>?
      _disconnectedCallable;

  int? _reconnectedId;
  StreamController<void>? _reconnectedController;
  NativeCallable<Void Function(Pointer<natsConnection>, Pointer<Void>)>?
      _reconnectedCallable;

  int? _closedId;
  StreamController<void>? _closedController;
  NativeCallable<Void Function(Pointer<natsConnection>, Pointer<Void>)>?
      _closedCallable;

  int? _errorId;
  StreamController<NatsError>? _errorController;
  NativeCallable<
      Void Function(Pointer<natsConnection>, Pointer<natsSubscription>, UnsignedInt,
          Pointer<Void>)>? _errorCallable;

  /// Creates a new [NatsOptions] with default settings.
  NatsOptions() {
    final optsPtrPtr = calloc<Pointer<natsOptions>>();
    try {
      checkStatus(natsOptions_Create(optsPtrPtr), 'natsOptions_Create');
      _opts = optsPtrPtr.value;
      _finalizer.attach(this, _opts!.cast(), detach: this);
    } finally {
      calloc.free(optsPtrPtr);
    }
  }

  /// Creates a [NatsOptions] pre-configured with a single server [url].
  ///
  /// This is a convenience factory equivalent to `NatsOptions()..setUrl(url)`.
  factory NatsOptions.fromUrl(String url) {
    return NatsOptions()..setUrl(url);
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
        natsOptions_SetUserInfo(
            _opts!, userNative.cast(), passNative.cast()),
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
  /// [userOrChainedFile] is the path to the credentials file (or chained
  /// file containing both JWT and seed). [seedFile] is optional and used
  /// only when the JWT and seed are in separate files.
  void setCredentialsFile(String userOrChainedFile, [String? seedFile]) {
    _ensureAlive();
    final userNative = userOrChainedFile.toNativeUtf8();
    final seedNative = seedFile?.toNativeUtf8();
    try {
      checkStatus(
        natsOptions_SetUserCredentialsFromFiles(
          _opts!,
          userNative.cast(),
          seedNative?.cast() ?? nullptr,
        ),
        'natsOptions_SetUserCredentialsFromFiles',
      );
    } finally {
      calloc.free(userNative);
      if (seedNative != null) calloc.free(seedNative);
    }
  }

  // ── Lifecycle event streams ────────────────────────────────────────

  /// Registers a callback with the native options for connection-lost events
  /// and returns a stream that fires when the connection is lost.
  ///
  /// Must be called before [NatsClient.connectWithOptions]. Calling this
  /// multiple times returns the same stream (the callback is only registered
  /// once).
  Stream<void> onDisconnected() {
    _ensureAlive();
    if (_disconnectedController == null) {
      _disconnectedId = _nextId++;
      _disconnectedController = StreamController<void>.broadcast();
      _lifecycleRoutes[_disconnectedId!] = _disconnectedController!;

      _disconnectedCallable = NativeCallable<
              Void Function(Pointer<natsConnection>, Pointer<Void>)>.listener(
          _onDisconnected);

      checkStatus(
        natsOptions_SetDisconnectedCB(
          _opts!,
          _disconnectedCallable!.nativeFunction,
          Pointer.fromAddress(_disconnectedId!),
        ),
        'natsOptions_SetDisconnectedCB',
      );
    }
    return _disconnectedController!.stream;
  }

  /// Registers a callback with the native options for reconnection events
  /// and returns a stream that fires when the connection has been
  /// re-established.
  ///
  /// Must be called before [NatsClient.connectWithOptions]. Calling this
  /// multiple times returns the same stream (the callback is only registered
  /// once).
  Stream<void> onReconnected() {
    _ensureAlive();
    if (_reconnectedController == null) {
      _reconnectedId = _nextId++;
      _reconnectedController = StreamController<void>.broadcast();
      _lifecycleRoutes[_reconnectedId!] = _reconnectedController!;

      _reconnectedCallable = NativeCallable<
              Void Function(Pointer<natsConnection>, Pointer<Void>)>.listener(
          _onReconnected);

      checkStatus(
        natsOptions_SetReconnectedCB(
          _opts!,
          _reconnectedCallable!.nativeFunction,
          Pointer.fromAddress(_reconnectedId!),
        ),
        'natsOptions_SetReconnectedCB',
      );
    }
    return _reconnectedController!.stream;
  }

  /// Registers a callback with the native options for connection-closed
  /// events and returns a stream that fires when the connection is
  /// permanently closed.
  ///
  /// Must be called before [NatsClient.connectWithOptions]. Calling this
  /// multiple times returns the same stream (the callback is only registered
  /// once).
  Stream<void> onClosed() {
    _ensureAlive();
    if (_closedController == null) {
      _closedId = _nextId++;
      _closedController = StreamController<void>.broadcast();
      _lifecycleRoutes[_closedId!] = _closedController!;

      _closedCallable = NativeCallable<
              Void Function(Pointer<natsConnection>, Pointer<Void>)>.listener(
          _onClosed);

      checkStatus(
        natsOptions_SetClosedCB(
          _opts!,
          _closedCallable!.nativeFunction,
          Pointer.fromAddress(_closedId!),
        ),
        'natsOptions_SetClosedCB',
      );
    }
    return _closedController!.stream;
  }

  /// Registers an error handler with the native options and returns a stream
  /// of asynchronous errors (e.g. slow-consumer).
  ///
  /// Must be called before [NatsClient.connectWithOptions]. Calling this
  /// multiple times returns the same stream (the callback is only registered
  /// once).
  Stream<NatsError> onError() {
    _ensureAlive();
    if (_errorController == null) {
      _errorId = _nextId++;
      _errorController = StreamController<NatsError>.broadcast();
      _errorRoutes[_errorId!] = _errorController!;

      _errorCallable = NativeCallable<
          Void Function(Pointer<natsConnection>, Pointer<natsSubscription>,
              UnsignedInt, Pointer<Void>)>.listener(_onError);

      checkStatus(
        natsOptions_SetErrorHandler(
          _opts!,
          _errorCallable!.nativeFunction,
          Pointer.fromAddress(_errorId!),
        ),
        'natsOptions_SetErrorHandler',
      );
    }
    return _errorController!.stream;
  }

  // ── Cleanup ────────────────────────────────────────────────────────

  /// Closes the native options and releases all callback resources.
  ///
  /// The returned [Future] completes when all stream controllers have
  /// finished notifying their listeners. Native resources are freed
  /// synchronously before the first `await`, so callers that don't need
  /// to wait for stream draining can safely ignore the returned future.
  Future<void> close() {
    if (_closed) return Future.value();
    _closed = true;

    // 1. Remove routing table entries first — prevents any late-arriving
    //    native callbacks from adding events to controllers that are
    //    about to close.
    if (_disconnectedId != null) _lifecycleRoutes.remove(_disconnectedId);
    if (_reconnectedId != null) _lifecycleRoutes.remove(_reconnectedId);
    if (_closedId != null) _lifecycleRoutes.remove(_closedId);
    if (_errorId != null) _errorRoutes.remove(_errorId);

    // 2. Close stream controllers — delivers done event to listeners.
    final controllerFutures = <Future<void>>[
      if (_disconnectedController != null) _disconnectedController!.close(),
      if (_reconnectedController != null) _reconnectedController!.close(),
      if (_closedController != null) _closedController!.close(),
      if (_errorController != null) _errorController!.close(),
    ];

    // 3. Close NativeCallables last — keeps them alive long enough for
    //    any already-posted callbacks to be delivered (they'll no-op
    //    because the routing table entries are gone).
    _disconnectedCallable?.close();
    _reconnectedCallable?.close();
    _closedCallable?.close();
    _errorCallable?.close();

    // 4. Destroy the native options pointer.
    if (_opts != null) {
      _finalizer.detach(this);
      natsOptions_Destroy(_opts!);
      _opts = null;
    }

    return controllerFutures.isEmpty
        ? Future.value()
        : Future.wait(controllerFutures);
  }

  void _ensureAlive() {
    if (_closed) {
      throw StateError('NatsOptions has been closed');
    }
  }
}
