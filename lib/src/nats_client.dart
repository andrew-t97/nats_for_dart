import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import 'jetstream_context.dart';
import 'nats_async_subscription.dart';
import 'nats_bindings.g.dart';
import 'nats_error.dart';
import 'nats_exceptions.dart';
import 'nats_message.dart';
import 'nats_options.dart';
import 'nats_options_config.dart';
import 'nats_status.dart';
import 'nats_sync_subscription.dart';

/// The native callback for disconnected events.
///
/// For `StreamController<void>`, Dart requires passing an explicit value —
/// `null` is the idiomatic sentinel for void streams.
void _onDisconnected(Pointer<natsConnection> _, Pointer<Void> closure) {
  final id = closure.address;
  final controller = NatsClient._lifecycleRoutes[id];
  if (controller != null && !controller.isClosed) {
    controller.add(null);
  }
}

/// The native callback for reconnected events.
void _onReconnected(Pointer<natsConnection> _, Pointer<Void> closure) {
  final id = closure.address;
  final controller = NatsClient._lifecycleRoutes[id];
  if (controller != null && !controller.isClosed) {
    controller.add(null);
  }
}

/// The native callback for closed events.
void _onClosed(Pointer<natsConnection> _, Pointer<Void> closure) {
  final id = closure.address;
  final controller = NatsClient._lifecycleRoutes[id];
  if (controller != null && !controller.isClosed) {
    controller.add(null);
  }
}

/// The native callback for error events.
void _onError(
  Pointer<natsConnection> _,
  Pointer<natsSubscription> _,
  int err,
  Pointer<Void> closure,
) {
  final id = closure.address;
  final controller = NatsClient._errorRoutes[id];
  if (controller != null && !controller.isClosed) {
    controller.add(NatsError(NatsStatus.fromValue(err)));
  }
}

NativeCallable<Void Function(Pointer<natsConnection>, Pointer<Void>)>?
_sharedDisconnectedCallable;

NativeCallable<Void Function(Pointer<natsConnection>, Pointer<Void>)>
_getSharedDisconnectedCallable() {
  return _sharedDisconnectedCallable ??=
      NativeCallable<
        Void Function(Pointer<natsConnection>, Pointer<Void>)
      >.listener(_onDisconnected);
}

NativeCallable<Void Function(Pointer<natsConnection>, Pointer<Void>)>?
_sharedReconnectedCallable;

NativeCallable<Void Function(Pointer<natsConnection>, Pointer<Void>)>
_getSharedReconnectedCallable() {
  return _sharedReconnectedCallable ??=
      NativeCallable<
        Void Function(Pointer<natsConnection>, Pointer<Void>)
      >.listener(_onReconnected);
}

NativeCallable<Void Function(Pointer<natsConnection>, Pointer<Void>)>?
_sharedClosedCallable;

NativeCallable<Void Function(Pointer<natsConnection>, Pointer<Void>)>
_getSharedClosedCallable() {
  return _sharedClosedCallable ??=
      NativeCallable<
        Void Function(Pointer<natsConnection>, Pointer<Void>)
      >.listener(_onClosed);
}

NativeCallable<
  Void Function(
    Pointer<natsConnection>,
    Pointer<natsSubscription>,
    UnsignedInt,
    Pointer<Void>,
  )
>?
_sharedErrorCallable;

NativeCallable<
  Void Function(
    Pointer<natsConnection>,
    Pointer<natsSubscription>,
    UnsignedInt,
    Pointer<Void>,
  )
>
_getSharedErrorCallable() {
  return _sharedErrorCallable ??=
      NativeCallable<
        Void Function(
          Pointer<natsConnection>,
          Pointer<natsSubscription>,
          UnsignedInt,
          Pointer<Void>,
        )
      >.listener(_onError);
}

/// Closes all shared lifecycle callables.
///
/// Only [NatsLibrary.close] should call this. Kept as a top-level function
/// because the shared [NativeCallable]s above are themselves top-level
/// state — promoting this to a static on [NatsClient] would split the
/// variables and their disposer across two scopes.
///
/// Must only be called after `nats_CloseAndWait()` guarantees all C threads
/// have exited; firing a C-thread callback into a closed callable would
/// segfault. Sets each to `null` so subsequent lazy getters re-create them
/// (e.g. in tests that open multiple libraries).
@internal
void closeSharedLifecycleCallables() {
  _sharedDisconnectedCallable?.close();
  _sharedDisconnectedCallable = null;
  _sharedReconnectedCallable?.close();
  _sharedReconnectedCallable = null;
  _sharedClosedCallable?.close();
  _sharedClosedCallable = null;
  _sharedErrorCallable?.close();
  _sharedErrorCallable = null;
}

/// Scrubs a client's four routing entries from the static maps. Invoked by
/// [NatsClient._routesFinalizer] on GC when an instance is abandoned without
/// [NatsClient.close] being called.
void _scrubClientRoutes(
  ({int disconnected, int reconnected, int closed, int error}) ids,
) {
  NatsClient._lifecycleRoutes.remove(ids.disconnected);
  NatsClient._lifecycleRoutes.remove(ids.reconnected);
  NatsClient._lifecycleRoutes.remove(ids.closed);
  NatsClient._errorRoutes.remove(ids.error);
}

/// A Dart-friendly wrapper around the NATS C client library.
///
/// Provides synchronous publish/subscribe over a single connection.
///
/// Close the client with [close] to free native resources straightaway;
/// otherwise they are freed when the instance is garbage collected.
final class NatsClient implements Finalizable {
  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(Pointer<natsConnection>)>>(
      natsConnection_Destroy,
    ).cast(),
  );

  /// Complements [_finalizer] by scrubbing Dart-side routing entries on GC;
  /// [_finalizer] only reclaims the C pointer.
  static final Finalizer<
    ({int disconnected, int reconnected, int closed, int error})
  >
  _routesFinalizer = Finalizer(_scrubClientRoutes);

  Pointer<natsConnection>? _nc;
  bool _closed = false;

  /// Whether this client has been closed.
  bool get isClosed => _closed;

  /// Active sync subscriptions created through this client. Closed
  /// automatically when the client itself is closed.
  final Set<NatsSyncSubscription> _activeSubscriptions = {};

  /// Active async subscriptions created through this client.
  final Set<NatsAsyncSubscription> _activeAsyncSubscriptions = {};

  /// Routes for void-typed lifecycle callbacks (disconnected, reconnected,
  /// closed). Keyed by a unique ID per callback.
  static final Map<int, StreamController<void>> _lifecycleRoutes = {};

  /// Routes for error callbacks. Keyed by a unique ID.
  static final Map<int, StreamController<NatsError>> _errorRoutes = {};

  static int _nextId = 1;

  late final int _disconnectedId;
  late final int _reconnectedId;
  late final int _closedId;
  late final int _errorId;

  late final StreamController<void> _disconnectedController;
  late final StreamController<void> _reconnectedController;
  late final StreamController<void> _closedController;
  late final StreamController<NatsError> _errorController;

  /// Broadcast stream that fires when the connection is lost.
  Stream<void> get onDisconnected => _disconnectedController.stream;

  /// Broadcast stream that fires when the connection has been re-established
  /// after a disconnect.
  Stream<void> get onReconnected => _reconnectedController.stream;

  /// Broadcast stream that fires once when the connection is permanently
  /// closed.
  Stream<void> get onClosed => _closedController.stream;

  /// Broadcast stream of asynchronous errors e.g. slow consumer, failed pings, etc.
  Stream<NatsError> get onError => _errorController.stream;

  NatsClient._() {
    _disconnectedId = _nextId++;
    _reconnectedId = _nextId++;
    _closedId = _nextId++;
    _errorId = _nextId++;

    _disconnectedController = StreamController<void>.broadcast();
    _reconnectedController = StreamController<void>.broadcast();
    _closedController = StreamController<void>.broadcast();
    _errorController = StreamController<NatsError>.broadcast();

    _lifecycleRoutes[_disconnectedId] = _disconnectedController;
    _lifecycleRoutes[_reconnectedId] = _reconnectedController;
    _lifecycleRoutes[_closedId] = _closedController;
    _errorRoutes[_errorId] = _errorController;

    _routesFinalizer.attach(this, (
      disconnected: _disconnectedId,
      reconnected: _reconnectedId,
      closed: _closedId,
      error: _errorId,
    ), detach: this);
  }

  /// Registers this client's lifecycle callbacks with the supplied native
  /// options pointer.
  void _registerLifecycleCallbacks(Pointer<natsOptions> opts) {
    checkStatus(
      natsOptions_SetDisconnectedCB(
        opts,
        _getSharedDisconnectedCallable().nativeFunction,
        Pointer.fromAddress(_disconnectedId),
      ),
      'natsOptions_SetDisconnectedCB',
    );
    checkStatus(
      natsOptions_SetReconnectedCB(
        opts,
        _getSharedReconnectedCallable().nativeFunction,
        Pointer.fromAddress(_reconnectedId),
      ),
      'natsOptions_SetReconnectedCB',
    );
    checkStatus(
      natsOptions_SetClosedCB(
        opts,
        _getSharedClosedCallable().nativeFunction,
        Pointer.fromAddress(_closedId),
      ),
      'natsOptions_SetClosedCB',
    );
    checkStatus(
      natsOptions_SetErrorHandler(
        opts,
        _getSharedErrorCallable().nativeFunction,
        Pointer.fromAddress(_errorId),
      ),
      'natsOptions_SetErrorHandler',
    );
  }

  /// Creates a new [NatsClient] connected to the given [url].
  ///
  /// Pass [options] to configure the connection (authentication, reconnect
  /// tuning, clustering, etc).
  ///
  /// When [options] is non-null, `NatsOptions.servers`, when non-empty,
  /// takes precedence over the positional [url]; otherwise [url] is used.
  ///
  /// Throws [ArgumentError] synchronously if [options] fail validation
  /// (invalid auth pairings or credentials combinations).
  ///
  /// Throws [NatsException] if the client fails to connect for any reason
  /// (e.g. server rejects the connection, network error, etc).
  ///
  /// Example:
  /// ```dart
  /// final client = NatsClient.connect('nats://localhost:4222');
  ///
  /// final configured = NatsClient.connect(
  ///   'nats://localhost:4222',
  ///   options: const NatsOptions(name: 'my-client', maxReconnect: 5),
  /// );
  /// ```
  factory NatsClient.connect(String url, {NatsOptions? options}) {
    final handle = NatsOptionsHandle.fromConfig(
      options ?? const NatsOptions(),
      url,
    );

    final client = NatsClient._();
    try {
      client._registerLifecycleCallbacks(handle.nativePtr);
      final ncPtrPtr = calloc<Pointer<natsConnection>>();
      try {
        final status = natsConnection_Connect(ncPtrPtr, handle.nativePtr);
        checkStatus(status, 'natsConnection_Connect');
        client._nc = ncPtrPtr.value;
        _finalizer.attach(client, client._nc!.cast(), detach: client);
      } finally {
        calloc.free(ncPtrPtr);
      }
      return client;
    } catch (_) {
      unawaited(client.close());
      rethrow;
    } finally {
      unawaited(handle.close());
    }
  }

  /// Creates a new [NatsClient] connected to the given [url] without blocking
  /// the current isolate's event loop.
  ///
  /// The blocking TCP handshake runs in a short-lived worker isolate via
  /// [Isolate.run]. Prefer this over [NatsClient.connect] in Flutter apps.
  ///
  /// Pass [options] to configure the connection (authentication, reconnect
  /// tuning, clustering, etc).
  ///
  /// When [options] is non-null, `NatsOptions.servers`, when non-empty,
  /// takes precedence over the positional [url]; otherwise [url] is used.
  ///
  /// Throws [ArgumentError] if [options] fail validation (invalid auth
  /// pairings or credentials combinations).
  ///
  /// Throws [NatsException] if the client fails to connect for any reason
  /// (e.g. server rejects the connection, network error, etc).
  ///
  /// Because this method is `async`, both surface as rejected Futures —
  /// `await` the call (or attach `.catchError`) to observe them.
  ///
  /// Example:
  /// ```dart
  /// final client = await NatsClient.connectAsync(
  ///   'nats://localhost:4222',
  ///   options: const NatsOptions(name: 'flutter-app'),
  /// );
  /// ```
  static Future<NatsClient> connectAsync(
    String url, {
    NatsOptions? options,
  }) async {
    final handle = NatsOptionsHandle.fromConfig(
      options ?? const NatsOptions(),
      url,
    );

    final client = NatsClient._();
    try {
      client._registerLifecycleCallbacks(handle.nativePtr);

      final optionsAddress = handle.nativePtr.address;
      final connectionAddress = await Isolate.run(() {
        final ncPtrPtr = calloc<Pointer<natsConnection>>();
        try {
          final optsPtr = Pointer<natsOptions>.fromAddress(optionsAddress);
          final status = natsConnection_Connect(ncPtrPtr, optsPtr);
          checkStatus(status, 'natsConnection_Connect');
          return ncPtrPtr.value.address;
        } finally {
          calloc.free(ncPtrPtr);
        }
      });

      client._nc = Pointer.fromAddress(connectionAddress);
      _finalizer.attach(client, client._nc!.cast(), detach: client);
      return client;
    } catch (_) {
      await client.close();
      rethrow;
    } finally {
      await handle.close();
    }
  }

  /// Publishes a string [message] on the given [subject].
  void publish(String subject, String message) {
    _ensureOpen();
    final subjectNative = subject.toNativeUtf8();
    final messageNative = message.toNativeUtf8();
    try {
      final status = natsConnection_PublishString(
        _nc!,
        subjectNative.cast(),
        messageNative.cast(),
      );
      checkStatus(status, 'natsConnection_PublishString');
    } finally {
      calloc.free(subjectNative);
      calloc.free(messageNative);
    }
  }

  /// Publishes raw [data] bytes on the given [subject].
  void publishBytes(String subject, Uint8List data) {
    _ensureOpen();
    final subjectNative = subject.toNativeUtf8();
    final dataPtr = malloc<Uint8>(data.length);
    try {
      dataPtr.asTypedList(data.length).setAll(0, data);
      final status = natsConnection_Publish(
        _nc!,
        subjectNative.cast(),
        dataPtr.cast(),
        data.length,
      );
      checkStatus(status, 'natsConnection_Publish');
    } finally {
      calloc.free(subjectNative);
      malloc.free(dataPtr);
    }
  }

  /// Flushes the connection, ensuring all published messages have been sent.
  ///
  /// If [timeout] is provided, uses [natsConnection_FlushTimeout]; otherwise
  /// blocks until the flush completes with [natsConnection_Flush].
  void flush({Duration? timeout}) {
    _ensureOpen();
    if (timeout != null) {
      final status = natsConnection_FlushTimeout(_nc!, timeout.inMilliseconds);
      checkStatus(status, 'natsConnection_FlushTimeout');
    } else {
      final status = natsConnection_Flush(_nc!);
      checkStatus(status, 'natsConnection_Flush');
    }
  }

  /// Returns the native connection pointer for use by JetStream and KV.
  @internal
  Pointer<natsConnection> get nativeConnectionPtr {
    _ensureOpen();
    return _nc!;
  }

  /// Creates a [JetStreamContext] for this connection.
  ///
  /// The returned context is valid for the lifetime of this connection.
  /// Multiple calls return independent contexts.
  JetStreamContext jetStream() {
    _ensureOpen();
    return JetStreamContext.create(_nc!);
  }

  /// Creates a synchronous subscription on the given [subject].
  NatsSyncSubscription subscribeSync(String subject) {
    _ensureOpen();
    final subPtrPtr = calloc<Pointer<natsSubscription>>();
    final subjectNative = subject.toNativeUtf8();
    try {
      final status = natsConnection_SubscribeSync(
        subPtrPtr,
        _nc!,
        subjectNative.cast(),
      );
      checkStatus(status, 'natsConnection_SubscribeSync');
      late final NatsSyncSubscription sub;
      sub = NatsSyncSubscription.create(
        subPtrPtr.value,
        () => _activeSubscriptions.remove(sub),
      );
      _activeSubscriptions.add(sub);
      return sub;
    } finally {
      calloc.free(subPtrPtr);
      calloc.free(subjectNative);
    }
  }

  /// Creates an asynchronous subscription on the given [subject].
  ///
  /// Messages are delivered via the returned [NatsAsyncSubscription.messages]
  /// stream. The NATS C library delivers messages on internal threads;
  /// [NativeCallable.listener] ensures they arrive on the Dart event loop.
  NatsAsyncSubscription subscribe(String subject) {
    _ensureOpen();
    final subPtrPtr = calloc<Pointer<natsSubscription>>();
    final subjectNative = subject.toNativeUtf8();
    NatsAsyncSubscription? asyncSub;
    try {
      // Pre-allocate the subscription wrapper so we can extract the
      // native callback pointer and closure before calling into C.
      late final NatsAsyncSubscription capturedSub;
      asyncSub = NatsAsyncSubscription.create(
        () => _activeAsyncSubscriptions.remove(capturedSub),
      );
      capturedSub = asyncSub;

      final status = natsConnection_Subscribe(
        subPtrPtr,
        _nc!,
        subjectNative.cast(),
        NatsAsyncSubscription.nativeCallbackFor(),
        NatsAsyncSubscription.closureFor(asyncSub),
      );
      checkStatus(status, 'natsConnection_Subscribe');

      // Store the actual subscription pointer now that subscribe succeeded.
      asyncSub.updateSubPtr(subPtrPtr.value);
      _activeAsyncSubscriptions.add(asyncSub);
      return asyncSub;
    } catch (e) {
      // Clean up the pre-allocated wrapper on failure. close() releases
      // the routing table entry, StreamController, and NativeCallable
      // without touching the native subscription (which was never created).
      asyncSub?.close();
      rethrow;
    } finally {
      calloc.free(subPtrPtr);
      calloc.free(subjectNative);
    }
  }

  /// Creates an asynchronous queue subscription.
  ///
  /// All subscribers sharing the same [queueGroup] name form a queue group —
  /// only one member receives any given message.
  NatsAsyncSubscription queueSubscribe(String subject, String queueGroup) {
    _ensureOpen();
    final subPtrPtr = calloc<Pointer<natsSubscription>>();
    final subjectNative = subject.toNativeUtf8();
    final queueNative = queueGroup.toNativeUtf8();
    NatsAsyncSubscription? asyncSub;
    try {
      late final NatsAsyncSubscription capturedSub;
      asyncSub = NatsAsyncSubscription.create(
        () => _activeAsyncSubscriptions.remove(capturedSub),
      );
      capturedSub = asyncSub;

      final status = natsConnection_QueueSubscribe(
        subPtrPtr,
        _nc!,
        subjectNative.cast(),
        queueNative.cast(),
        NatsAsyncSubscription.nativeCallbackFor(),
        NatsAsyncSubscription.closureFor(asyncSub),
      );
      checkStatus(status, 'natsConnection_QueueSubscribe');

      asyncSub.updateSubPtr(subPtrPtr.value);
      _activeAsyncSubscriptions.add(asyncSub);
      return asyncSub;
    } catch (e) {
      asyncSub?.close();
      rethrow;
    } finally {
      calloc.free(subPtrPtr);
      calloc.free(subjectNative);
      calloc.free(queueNative);
    }
  }

  /// Closes all active subscriptions, then closes the connection and destroys
  /// the native resources.
  ///
  /// Native resources are freed synchronously. The returned [Future]
  /// completes when all stream controllers (async subscriptions and the four
  /// lifecycle streams) have finished notifying their listeners. Callers
  /// that don't need to wait for stream draining can safely ignore the
  /// returned future.
  Future<void> close() {
    if (_closed) return Future.value();
    _closed = true;

    final streamFutures = <Future<void>>[];

    // Close all tracked sync subscriptions first (fully synchronous).
    for (final sub in _activeSubscriptions.toList()) {
      sub.close();
    }
    _activeSubscriptions.clear();

    // Close all tracked async subscriptions. Native cleanup is synchronous;
    // we collect the stream-drain futures.
    for (final sub in _activeAsyncSubscriptions.toList()) {
      streamFutures.add(sub.close());
    }
    _activeAsyncSubscriptions.clear();

    // Detach before scrubbing the maps below so the finalizer can never
    // fire mid-teardown.
    _routesFinalizer.detach(this);

    if (_nc != null) {
      final ncPtr = _nc!;
      _nc = null;
      // Detach the native finalizer before manually destroying to prevent
      // a double-free if GC runs after an explicit close.
      _finalizer.detach(this);
      natsConnection_Close(ncPtr);
      natsConnection_Destroy(ncPtr);
    }

    // Remove lifecycle routing entries first so any late-arriving native
    // callback short-circuits before touching a closed controller, then
    // close the controllers themselves.
    _lifecycleRoutes.remove(_disconnectedId);
    _lifecycleRoutes.remove(_reconnectedId);
    _lifecycleRoutes.remove(_closedId);
    _errorRoutes.remove(_errorId);

    streamFutures.add(_disconnectedController.close());
    streamFutures.add(_reconnectedController.close());
    streamFutures.add(_closedController.close());
    streamFutures.add(_errorController.close());

    return streamFutures.isEmpty ? Future.value() : Future.wait(streamFutures);
  }

  /// Sends a string [message] as a request on [subject] and waits for a reply.
  ///
  /// Creates a unique inbox, subscribes to it, publishes the message with the
  /// inbox as the reply-to subject, then waits for a single reply. The inbox
  /// and subscription are cleaned up automatically.
  ///
  /// Throws [TimeoutException] if no reply arrives within [timeout].
  /// Throws [NatsNoRespondersException] if the server reports no responders
  /// (NATS v2.2+).
  Future<NatsMessage> request(
    String subject,
    String message, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    return _requestImpl(subject, (subjectPtr, inboxPtr) {
      final messageNative = message.toNativeUtf8();
      try {
        final status = natsConnection_PublishRequestString(
          _nc!,
          subjectPtr,
          inboxPtr,
          messageNative.cast(),
        );
        checkStatus(status, 'natsConnection_PublishRequestString');
      } finally {
        calloc.free(messageNative);
      }
    }, timeout: timeout);
  }

  /// Sends raw [data] bytes as a request on [subject] and waits for a reply.
  ///
  /// Binary variant of [request]. See [request] for details.
  Future<NatsMessage> requestBytes(
    String subject,
    Uint8List data, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    return _requestImpl(subject, (subjectPtr, inboxPtr) {
      final dataPtr = malloc<Uint8>(data.length);
      try {
        dataPtr.asTypedList(data.length).setAll(0, data);
        final status = natsConnection_PublishRequest(
          _nc!,
          subjectPtr,
          inboxPtr,
          dataPtr.cast(),
          data.length,
        );
        checkStatus(status, 'natsConnection_PublishRequest');
      } finally {
        malloc.free(dataPtr);
      }
    }, timeout: timeout);
  }

  /// Shared implementation for [request] and [requestBytes].
  ///
  /// Handles inbox creation, subscription, flush, reply await, and cleanup.
  /// The caller-provided [publishWithReplyTo] callback performs the
  /// type-specific publish call.
  Future<NatsMessage> _requestImpl(
    String subject,
    void Function(Pointer<Char> subjectPtr, Pointer<Char> inboxPtr)
    publishWithReplyTo, {
    required Duration timeout,
  }) async {
    _ensureOpen();

    // 1. Create a unique inbox subject.
    final inboxPtrPtr = calloc<Pointer<Char>>();
    try {
      checkStatus(natsInbox_Create(inboxPtrPtr), 'natsInbox_Create');
    } catch (e) {
      calloc.free(inboxPtrPtr);
      rethrow;
    }
    final inboxPtr = inboxPtrPtr.value;
    calloc.free(inboxPtrPtr);

    // 2. Subscribe to the inbox.
    final inboxSubject = inboxPtr.cast<Utf8>().toDartString();
    final inboxSub = subscribe(inboxSubject);

    try {
      // 3. Publish with reply-to (type-specific).
      final subjectNative = subject.toNativeUtf8();
      try {
        publishWithReplyTo(subjectNative.cast(), inboxPtr);
      } finally {
        calloc.free(subjectNative);
      }

      // 4. Flush to ensure delivery.
      flush();

      // 5. Wait for a single reply.
      return await inboxSub.messages.first.timeout(timeout);
    } finally {
      await inboxSub.close();
      natsInbox_Destroy(inboxPtr);
    }
  }

  /// Sends a string [response] back to the sender of [message].
  ///
  /// Convenience method for request-reply responders. Publishes [response]
  /// to the [NatsMessage.replyTo] subject.
  ///
  /// Throws [ArgumentError] if [message] has no [NatsMessage.replyTo].
  void respond(NatsMessage message, String response) {
    if (message.replyTo == null) {
      throw ArgumentError('Cannot respond: message has no replyTo subject');
    }
    publish(message.replyTo!, response);
  }

  /// Sends raw [data] bytes back to the sender of [message].
  ///
  /// Binary variant of [respond]. See [respond] for details.
  void respondBytes(NatsMessage message, Uint8List data) {
    if (message.replyTo == null) {
      throw ArgumentError('Cannot respond: message has no replyTo subject');
    }
    publishBytes(message.replyTo!, data);
  }

  void _ensureOpen() {
    if (_closed) {
      throw StateError('NatsClient is already closed');
    }
  }
}
