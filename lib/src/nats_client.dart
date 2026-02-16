import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import 'jetstream_context.dart';
import 'nats_async_subscription.dart';
import 'nats_bindings.g.dart';
import 'nats_exceptions.dart';
import 'nats_message.dart';
import 'nats_options.dart';
import 'nats_sync_subscription.dart';

/// A Dart-friendly wrapper around the NATS C client library.
///
/// Provides synchronous publish/subscribe over a single connection.
final class NatsClient implements Finalizable {
  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(Pointer<natsConnection>)>>(
      natsConnection_Destroy,
    ).cast(),
  );

  Pointer<natsConnection>? _nc;
  bool _closed = false;

  /// Whether this client has been closed.
  bool get isClosed => _closed;

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
    final ncPtrPtr = calloc<Pointer<natsConnection>>();
    final urlNative = url.toNativeUtf8();
    try {
      final status = natsConnection_ConnectTo(
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
    final ncPtrPtr = calloc<Pointer<natsConnection>>();
    try {
      final status = natsConnection_Connect(ncPtrPtr, options.nativePtr);
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
      final ncPtrPtr = calloc<Pointer<natsConnection>>();
      final urlNative = url.toNativeUtf8();
      try {
        final status = natsConnection_ConnectTo(
          ncPtrPtr,
          urlNative.cast(),
        );
        checkStatus(status, 'natsConnection_ConnectTo');
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

    final client = NatsClient._();
    client._options = options;
    client._nc = Pointer.fromAddress(connectionAddress);
    _finalizer.attach(client, client._nc!.cast(), detach: client);
    return client;
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
      final status = natsConnection_FlushTimeout(
        _nc!,
        timeout.inMilliseconds,
      );
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
      final ncPtr = _nc!;
      _nc = null;
      // Detach the finalizer before manually destroying to prevent
      // double-free if GC runs after an explicit close.
      _finalizer.detach(this);
      natsConnection_Close(ncPtr);
      natsConnection_Destroy(ncPtr);
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
  }) {
    return _requestImpl(
      subject,
      (subjectPtr, inboxPtr) {
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
      },
      timeout: timeout,
    );
  }

  /// Sends raw [data] bytes as a request on [subject] and waits for a reply.
  ///
  /// Binary variant of [request]. See [request] for details.
  Future<NatsMessage> requestBytes(
    String subject,
    Uint8List data, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    return _requestImpl(
      subject,
      (subjectPtr, inboxPtr) {
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
      },
      timeout: timeout,
    );
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
