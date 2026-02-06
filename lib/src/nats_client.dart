import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import 'jetstream_context.dart';
import 'nats_async_subscription.dart';
import 'nats_bindings.g.dart';
import 'nats_bindings_loader.dart';
import 'nats_exceptions.dart';
import 'nats_options.dart';

/// Global library initialisation and teardown for the NATS C client.
///
/// Call [NatsLibrary.init] once before creating any connections and
/// [NatsLibrary.close] after all connections have been destroyed.
final class NatsLibrary {
  NatsLibrary._();

  /// Initialises the NATS C library with default settings.
  ///
  /// This must be called (once) before any connections are created. Passing
  /// `-1` uses the library defaults.
  static void init() {
    checkStatus(bindings.nats_Open(-1), 'nats_Open');
  }

  /// Tears down the NATS C library and waits for resources to be released.
  ///
  /// Pass `0` to wait indefinitely.
  static void close({int timeoutMs = 0}) {
    checkStatus(bindings.nats_CloseAndWait(timeoutMs), 'nats_CloseAndWait');
  }
}

/// A message received from a NATS subscription.
///
/// All fields are eagerly copied from the native `natsMsg` pointer so this
/// object is safe to use after the underlying pointer has been destroyed.
///
/// Unlike [NatsClient], [NatsSyncSubscription], and [NatsAsyncSubscription],
/// this class does **not** use a [NativeFinalizer]. The native `natsMsg`
/// pointer is destroyed eagerly inside [fromNativePtr] immediately after
/// copying, so there is no pointer left to leak — no GC safety net needed.
@immutable
final class NatsMessage {
  /// The subject this message was published to.
  final String subject;

  /// The raw payload bytes.
  final Uint8List data;

  /// The reply-to subject, if present.
  final String? replyTo;

  NatsMessage._(this.subject, this.data, this.replyTo);

  /// Creates a [NatsMessage] for use in tests.
  @visibleForTesting
  NatsMessage.forTest(this.subject, this.data, this.replyTo);

  /// Convenience getter that decodes [data] as a UTF-8 string.
  String get dataAsString => utf8.decode(data);

  @override
  String toString() {
    final reply = replyTo != null ? ', replyTo: $replyTo' : '';
    return 'NatsMessage(subject: $subject$reply, data: $dataAsString)';
  }

  /// Creates a [NatsMessage] by eagerly copying data out of a native
  /// `natsMsg` pointer, then destroying the native message.
  ///
  /// This is the canonical way to materialise a message from a native
  /// pointer. Both sync and async code paths use this.
  factory NatsMessage.fromNativePtr(Pointer<natsMsg> msgPtr) {
    if (msgPtr == nullptr) {
      throw ArgumentError('Cannot create NatsMessage from a null pointer');
    }
    final b = bindings;
    final subject = b.natsMsg_GetSubject(msgPtr).cast<Utf8>().toDartString();
    final dataLen = b.natsMsg_GetDataLength(msgPtr);
    final dataPtr = b.natsMsg_GetData(msgPtr);
    final data = Uint8List.fromList(
      dataPtr.cast<Uint8>().asTypedList(dataLen),
    );

    // Eagerly copy the reply-to subject if present.
    final replyPtr = b.natsMsg_GetReply(msgPtr);
    final replyTo =
        replyPtr == nullptr ? null : replyPtr.cast<Utf8>().toDartString();

    b.natsMsg_Destroy(msgPtr);
    return NatsMessage._(subject, data, replyTo);
  }
}

/// A synchronous subscription that can be polled for messages.
///
/// **Warning:** [nextMessage] calls the blocking C function
/// `natsSubscription_NextMsg`, which blocks the calling isolate's event
/// loop until a message arrives or the timeout expires. In Flutter apps
/// this will freeze the UI.
///
/// Use [NatsAsyncSubscription] (via [NatsClient.subscribe]) for
/// Flutter-friendly, non-blocking message delivery. This class is intended
/// for CLI tools, scripts, and tests where blocking is acceptable.
final class NatsSyncSubscription implements Finalizable {
  static final _finalizer = NativeFinalizer(
    natsLib.lookup('natsSubscription_Destroy'),
  );

  Pointer<natsSubscription>? _sub;
  bool _closed = false;

  /// Back-reference to the owning client so the subscription can remove itself
  /// from the client's active-subscription set on close.
  NatsClient? _owner;

  NatsSyncSubscription._(this._sub, this._owner) {
    _finalizer.attach(this, _sub!.cast(), detach: this);
  }

  /// Polls for the next message, blocking the current isolate up to [timeout].
  ///
  /// **This is a blocking FFI call.** The Dart event loop will not process
  /// any events (timers, I/O, UI frames) until this method returns. In
  /// Flutter, prefer [NatsAsyncSubscription] instead.
  ///
  /// Returns a [NatsMessage] with eagerly-copied data. The underlying native
  /// message is destroyed before this method returns.
  NatsMessage nextMessage({Duration timeout = const Duration(seconds: 5)}) {
    _ensureOpen();
    final b = bindings;
    final msgPtrPtr = calloc<Pointer<natsMsg>>();
    try {
      final status = b.natsSubscription_NextMsg(
        msgPtrPtr,
        _sub!,
        timeout.inMilliseconds,
      );
      checkStatus(status, 'natsSubscription_NextMsg');
      return NatsMessage.fromNativePtr(msgPtrPtr.value);
    } finally {
      calloc.free(msgPtrPtr);
    }
  }

  /// Unsubscribes and destroys this subscription.
  void unsubscribe() {
    if (_closed) return;
    _closed = true;
    _owner?.removeSyncSubscription(this);
    _owner = null;
    if (_sub != null) {
      final b = bindings;
      final subPtr = _sub!;
      _sub = null;
      // Detach the finalizer before manually destroying to prevent
      // double-free if GC runs after an explicit close.
      _finalizer.detach(this);
      // Ignore expected statuses during teardown (e.g. connection already
      // closed or subscription already invalid).
      final status = b.natsSubscription_Unsubscribe(subPtr);
      // Always destroy regardless of unsubscribe outcome.
      b.natsSubscription_Destroy(subPtr);
      if (status != natsStatus.NATS_OK &&
          status != natsStatus.NATS_CONNECTION_CLOSED &&
          status != natsStatus.NATS_INVALID_SUBSCRIPTION) {
        checkStatus(status, 'natsSubscription_Unsubscribe');
      }
    }
  }

  /// Alias for [unsubscribe].
  void close() => unsubscribe();

  void _ensureOpen() {
    if (_closed) {
      throw StateError('Subscription is already closed');
    }
  }
}

/// A Dart-friendly wrapper around the NATS C client library.
///
/// Provides synchronous publish/subscribe over a single connection.
final class NatsClient implements Finalizable {
  static final _finalizer = NativeFinalizer(
    natsLib.lookup('natsConnection_Destroy'),
  );

  Pointer<natsConnection>? _nc;
  bool _closed = false;

  /// Active sync subscriptions created through this client. Closed
  /// automatically when the client itself is closed.
  final Set<NatsSyncSubscription> _activeSubscriptions = {};

  /// Active async subscriptions created through this client.
  final Set<NatsAsyncSubscription> _activeAsyncSubscriptions = {};

  /// Optional [NatsOptions] used to create this connection.
  NatsOptions? _options;

  NatsClient._();

  /// Creates a new [NatsClient] connected to the given [url].
  ///
  /// Example:
  /// ```dart
  /// final client = NatsClient.connect('nats://localhost:4222');
  /// ```
  factory NatsClient.connect(String url) {
    final client = NatsClient._();
    final b = bindings;
    final ncPtrPtr = calloc<Pointer<natsConnection>>();
    final urlNative = url.toNativeUtf8();
    try {
      final status = b.natsConnection_ConnectTo(
        ncPtrPtr,
        urlNative.cast(),
      );
      checkStatus(status, 'natsConnection_ConnectTo');
      client._nc = ncPtrPtr.value;
      _finalizer.attach(client, client._nc!.cast(), detach: client);
    } finally {
      calloc.free(ncPtrPtr);
      calloc.free(urlNative);
    }
    return client;
  }

  /// Creates a new [NatsClient] connected using the given [NatsOptions].
  ///
  /// The [options] object is cloned by the C library during connect, so it
  /// is safe to destroy or reuse after this call. However, if the options
  /// carry lifecycle stream controllers (onDisconnected, etc.) they remain
  /// active and are stored on this client for cleanup.
  ///
  /// Example:
  /// ```dart
  /// final opts = NatsOptions()
  ///   ..setUrl('nats://localhost:4222')
  ///   ..setMaxReconnect(5)
  ///   ..setReconnectWait(Duration(seconds: 2));
  /// final client = NatsClient.connectWithOptions(opts);
  /// ```
  factory NatsClient.connectWithOptions(NatsOptions options) {
    final client = NatsClient._();
    client._options = options;
    final b = bindings;
    final ncPtrPtr = calloc<Pointer<natsConnection>>();
    try {
      final status = b.natsConnection_Connect(ncPtrPtr, options.nativePtr);
      checkStatus(status, 'natsConnection_Connect');
      client._nc = ncPtrPtr.value;
      _finalizer.attach(client, client._nc!.cast(), detach: client);
    } finally {
      calloc.free(ncPtrPtr);
    }
    return client;
  }

  /// Creates a new [NatsClient] connected to the given [url] without blocking
  /// the current isolate's event loop.
  ///
  /// The blocking TCP handshake runs in a short-lived worker isolate via
  /// [Isolate.run]. Prefer this over [NatsClient.connect] in Flutter apps.
  ///
  /// Example:
  /// ```dart
  /// final client = await NatsClient.connectAsync('nats://localhost:4222');
  /// ```
  static Future<NatsClient> connectAsync(String url) async {
    final connectionAddress = await Isolate.run(() {
      final lib = _openNatsLibInIsolate();
      final b = NatsBindings(lib);
      final ncPtrPtr = calloc<Pointer<natsConnection>>();
      final urlNative = url.toNativeUtf8();
      try {
        final status = b.natsConnection_ConnectTo(
          ncPtrPtr,
          urlNative.cast(),
        );
        _checkStatusInIsolate(b, status, 'natsConnection_ConnectTo');
        return ncPtrPtr.value.address;
      } finally {
        calloc.free(ncPtrPtr);
        calloc.free(urlNative);
      }
    });

    final client = NatsClient._();
    client._nc = Pointer.fromAddress(connectionAddress);
    _finalizer.attach(client, client._nc!.cast(), detach: client);
    return client;
  }

  /// Creates a new [NatsClient] connected using the given [NatsOptions] without
  /// blocking the current isolate's event loop.
  ///
  /// The blocking TCP handshake runs in a short-lived worker isolate via
  /// [Isolate.run]. Prefer this over [NatsClient.connectWithOptions] in
  /// Flutter apps.
  ///
  /// The [options] object is cloned by the C library during connect, so its
  /// native pointer only needs to remain valid for the duration of this call.
  /// Lifecycle stream controllers (onDisconnected, etc.) remain active and are
  /// stored on the returned client for cleanup.
  ///
  /// Example:
  /// ```dart
  /// final opts = NatsOptions()
  ///   ..setUrl('nats://localhost:4222')
  ///   ..setMaxReconnect(5);
  /// final client = await NatsClient.connectWithOptionsAsync(opts);
  /// ```
  static Future<NatsClient> connectWithOptionsAsync(
    NatsOptions options,
  ) async {
    final optionsAddress = options.nativePtr.address;
    final connectionAddress = await Isolate.run(() {
      final lib = _openNatsLibInIsolate();
      final b = NatsBindings(lib);
      final ncPtrPtr = calloc<Pointer<natsConnection>>();
      try {
        final optsPtr = Pointer<natsOptions>.fromAddress(optionsAddress);
        final status = b.natsConnection_Connect(ncPtrPtr, optsPtr);
        _checkStatusInIsolate(b, status, 'natsConnection_Connect');
        return ncPtrPtr.value.address;
      } finally {
        calloc.free(ncPtrPtr);
      }
    });

    final client = NatsClient._();
    client._options = options;
    client._nc = Pointer.fromAddress(connectionAddress);
    _finalizer.attach(client, client._nc!.cast(), detach: client);
    return client;
  }

  /// Opens the NATS shared library inside a worker isolate.
  ///
  /// Worker isolates don't share the main isolate's lazy singletons, so we
  /// need to open the library independently.
  static DynamicLibrary _openNatsLibInIsolate() {
    if (Platform.isMacOS) {
      try {
        return DynamicLibrary.open(
          '/opt/homebrew/opt/cnats/lib/libnats.dylib',
        );
      } catch (_) {
        return DynamicLibrary.open('libnats.dylib');
      }
    } else if (Platform.isLinux) {
      try {
        return DynamicLibrary.open(
          '/home/linuxbrew/.linuxbrew/lib/libnats.so',
        );
      } catch (_) {
        return DynamicLibrary.open('libnats.so');
      }
    }
    throw UnsupportedError(
      'Unsupported platform: ${Platform.operatingSystem}',
    );
  }

  /// A self-contained status check for use inside worker isolates, which
  /// cannot access the main isolate's [bindings] singleton.
  static void _checkStatusInIsolate(
    NatsBindings b,
    natsStatus status,
    String context,
  ) {
    if (status != natsStatus.NATS_OK) {
      String? nativeError;
      try {
        final errPtr = b.nats_GetLastError(nullptr);
        if (errPtr != nullptr) {
          nativeError = errPtr.cast<Utf8>().toDartString();
        }
      } catch (_) {}

      final parts = <String>[context, status.name, ?nativeError];
      throw NatsException(status, parts.join(': '));
    }
  }

  /// Publishes a string [message] on the given [subject].
  void publish(String subject, String message) {
    _ensureOpen();
    final b = bindings;
    final subjectNative = subject.toNativeUtf8();
    final messageNative = message.toNativeUtf8();
    try {
      final status = b.natsConnection_PublishString(
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
    final b = bindings;
    final subjectNative = subject.toNativeUtf8();
    final dataPtr = malloc<Uint8>(data.length);
    try {
      dataPtr.asTypedList(data.length).setAll(0, data);
      final status = b.natsConnection_Publish(
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
    final b = bindings;
    if (timeout != null) {
      final status = b.natsConnection_FlushTimeout(
        _nc!,
        timeout.inMilliseconds,
      );
      checkStatus(status, 'natsConnection_FlushTimeout');
    } else {
      final status = b.natsConnection_Flush(_nc!);
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
    final b = bindings;
    final subPtrPtr = calloc<Pointer<natsSubscription>>();
    final subjectNative = subject.toNativeUtf8();
    try {
      final status = b.natsConnection_SubscribeSync(
        subPtrPtr,
        _nc!,
        subjectNative.cast(),
      );
      checkStatus(status, 'natsConnection_SubscribeSync');
      final sub = NatsSyncSubscription._(subPtrPtr.value, this);
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
    final b = bindings;
    final subPtrPtr = calloc<Pointer<natsSubscription>>();
    final subjectNative = subject.toNativeUtf8();
    NatsAsyncSubscription? asyncSub;
    try {
      // Pre-allocate the subscription wrapper so we can extract the
      // native callback pointer and closure before calling into C.
      asyncSub = NatsAsyncSubscription.create(this);

      final status = b.natsConnection_Subscribe(
        subPtrPtr,
        _nc!,
        subjectNative.cast(),
        NatsAsyncSubscription.nativeCallbackFor(asyncSub),
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
    final b = bindings;
    final subPtrPtr = calloc<Pointer<natsSubscription>>();
    final subjectNative = subject.toNativeUtf8();
    final queueNative = queueGroup.toNativeUtf8();
    NatsAsyncSubscription? asyncSub;
    try {
      asyncSub = NatsAsyncSubscription.create(this);

      final status = b.natsConnection_QueueSubscribe(
        subPtrPtr,
        _nc!,
        subjectNative.cast(),
        queueNative.cast(),
        NatsAsyncSubscription.nativeCallbackFor(asyncSub),
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

  /// Removes a sync subscription from the active set.
  ///
  /// Called internally by [NatsSyncSubscription.unsubscribe] — not intended
  /// for external use.
  @internal
  void removeSyncSubscription(NatsSyncSubscription sub) {
    _activeSubscriptions.remove(sub);
  }

  /// Removes an async subscription from the active set.
  ///
  /// Called internally by [NatsAsyncSubscription.unsubscribe] — not intended
  /// for external use.
  @internal
  void removeAsyncSubscription(NatsAsyncSubscription sub) {
    _activeAsyncSubscriptions.remove(sub);
  }

  /// Closes all active subscriptions, then closes the connection and destroys
  /// the native resources.
  ///
  /// Native resources are freed synchronously. The returned [Future]
  /// completes when all stream controllers (async subscriptions, options
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

    if (_nc != null) {
      final b = bindings;
      final ncPtr = _nc!;
      _nc = null;
      // Detach the finalizer before manually destroying to prevent
      // double-free if GC runs after an explicit close.
      _finalizer.detach(this);
      b.natsConnection_Close(ncPtr);
      b.natsConnection_Destroy(ncPtr);
    }

    // Close options if owned by this client.
    if (_options != null) {
      streamFutures.add(_options!.close());
      _options = null;
    }

    return streamFutures.isEmpty
        ? Future.value()
        : Future.wait(streamFutures);
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
  }) async {
    _ensureOpen();
    final b = bindings;

    // 1. Create a unique inbox subject.
    final inboxPtrPtr = calloc<Pointer<Char>>();
    try {
      checkStatus(b.natsInbox_Create(inboxPtrPtr), 'natsInbox_Create');
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
      // 3. Publish with reply-to.
      final subjectNative = subject.toNativeUtf8();
      final messageNative = message.toNativeUtf8();
      try {
        final status = b.natsConnection_PublishRequestString(
          _nc!,
          subjectNative.cast(),
          inboxPtr,
          messageNative.cast(),
        );
        checkStatus(status, 'natsConnection_PublishRequestString');
      } finally {
        calloc.free(subjectNative);
        calloc.free(messageNative);
      }

      // 4. Flush to ensure delivery.
      flush();

      // 5. Wait for a single reply.
      return await inboxSub.messages.first.timeout(timeout);
    } finally {
      await inboxSub.close();
      b.natsInbox_Destroy(inboxPtr);
    }
  }

  /// Sends raw [data] bytes as a request on [subject] and waits for a reply.
  ///
  /// Binary variant of [request]. See [request] for details.
  Future<NatsMessage> requestBytes(
    String subject,
    Uint8List data, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    _ensureOpen();
    final b = bindings;

    // 1. Create a unique inbox subject.
    final inboxPtrPtr = calloc<Pointer<Char>>();
    try {
      checkStatus(b.natsInbox_Create(inboxPtrPtr), 'natsInbox_Create');
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
      // 3. Publish with reply-to.
      final subjectNative = subject.toNativeUtf8();
      final dataPtr = malloc<Uint8>(data.length);
      try {
        dataPtr.asTypedList(data.length).setAll(0, data);
        final status = b.natsConnection_PublishRequest(
          _nc!,
          subjectNative.cast(),
          inboxPtr,
          dataPtr.cast(),
          data.length,
        );
        checkStatus(status, 'natsConnection_PublishRequest');
      } finally {
        calloc.free(subjectNative);
        malloc.free(dataPtr);
      }

      // 4. Flush to ensure delivery.
      flush();

      // 5. Wait for a single reply.
      return await inboxSub.messages.first.timeout(timeout);
    } finally {
      await inboxSub.close();
      b.natsInbox_Destroy(inboxPtr);
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
