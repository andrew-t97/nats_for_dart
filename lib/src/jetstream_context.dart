import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import 'ack_policy.dart';
import 'deliver_policy.dart';
import 'discard_policy.dart';
import 'js_message.dart';
import 'nats_bindings.g.dart';
import 'nats_exceptions.dart';
import 'replay_policy.dart';
import 'retention_policy.dart';
import 'storage_type.dart';

// ── Dart-friendly config classes ────────────────────────────────────────

/// Configuration for creating or updating a JetStream stream.
@immutable
final class JsStreamConfig {
  final String name;
  final List<String> subjects;
  final String? description;
  final RetentionPolicy retention;
  final int maxConsumers;
  final int maxMsgs;
  final int maxBytes;
  final Duration? maxAge;
  final int maxMsgsPerSubject;
  final int maxMsgSize;
  final DiscardPolicy discard;
  final StorageType storage;
  final int replicas;
  final bool noAck;

  const JsStreamConfig({
    required this.name,
    this.subjects = const [],
    this.description,
    this.retention = RetentionPolicy.limits,
    this.maxConsumers = -1,
    this.maxMsgs = -1,
    this.maxBytes = -1,
    this.maxAge,
    this.maxMsgsPerSubject = -1,
    this.maxMsgSize = -1,
    this.discard = DiscardPolicy.discardOld,
    this.storage = StorageType.file,
    this.replicas = 1,
    this.noAck = false,
  });
}

/// Configuration for creating a JetStream consumer.
@immutable
final class JsConsumerConfig {
  final String? name;
  final String? durable;
  final String? description;
  final DeliverPolicy deliverPolicy;
  final AckPolicy ackPolicy;
  final ReplayPolicy replayPolicy;
  final String? filterSubject;
  final int? maxDeliver;
  final Duration? ackWait;
  final String? deliverSubject;
  final String? deliverGroup;
  final int? maxAckPending;

  const JsConsumerConfig({
    this.name,
    this.durable,
    this.description,
    this.deliverPolicy = DeliverPolicy.deliverAll,
    this.ackPolicy = AckPolicy.explicit,
    this.replayPolicy = ReplayPolicy.instant,
    this.filterSubject,
    this.maxDeliver,
    this.ackWait,
    this.deliverSubject,
    this.deliverGroup,
    this.maxAckPending,
  });
}

/// Eagerly-copied stream info returned by stream management operations.
@immutable
final class JsStreamInfoResult {
  final String name;
  final int created;
  final int messages;
  final int bytes;
  final int firstSeq;
  final int lastSeq;
  final int consumers;

  JsStreamInfoResult._({
    required this.name,
    required this.created,
    required this.messages,
    required this.bytes,
    required this.firstSeq,
    required this.lastSeq,
    required this.consumers,
  });

  @override
  String toString() =>
      'JsStreamInfoResult(name: $name, messages: $messages, '
      'firstSeq: $firstSeq, lastSeq: $lastSeq)';
}

/// Eagerly-copied consumer info returned by consumer management operations.
@immutable
final class JsConsumerInfoResult {
  final String stream;
  final String name;
  final int created;
  final int numAckPending;
  final int numRedelivered;
  final int numWaiting;
  final int numPending;

  JsConsumerInfoResult._({
    required this.stream,
    required this.name,
    required this.created,
    required this.numAckPending,
    required this.numRedelivered,
    required this.numWaiting,
    required this.numPending,
  });

  @override
  String toString() =>
      'JsConsumerInfoResult(stream: $stream, name: $name, '
      'pending: $numPending, ackPending: $numAckPending)';
}

// ── JetStream subscription wrappers ─────────────────────────────────────

/// A synchronous JetStream subscription that can be polled for messages.
///
/// **Warning:** [nextMessage] blocks the calling isolate's event loop.
/// Use [JsAsyncSubscription] for non-blocking message delivery.
final class JsSyncSubscription implements Finalizable {
  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(Pointer<natsSubscription>)>>(
      natsSubscription_Destroy,
    ).cast(),
  );

  Pointer<natsSubscription>? _sub;
  bool _closed = false;

  JsSyncSubscription._(Pointer<natsSubscription> sub) : _sub = sub {
    _finalizer.attach(this, _sub!.cast(), detach: this);
  }

  /// Polls for the next JetStream message, blocking up to [timeout].
  ///
  /// Returns a [JsMessage] with ack capabilities. Native resources are
  /// automatically released after a terminal ack ([JsMessage.ack],
  /// [JsMessage.ackSync], [JsMessage.nak], or [JsMessage.term]).
  JsMessage nextMessage({Duration timeout = const Duration(seconds: 5)}) {
    _ensureOpen();
    final msgPtrPtr = calloc<Pointer<natsMsg>>();
    try {
      final status = natsSubscription_NextMsg(
        msgPtrPtr,
        _sub!,
        timeout.inMilliseconds,
      );
      checkStatus(status, 'natsSubscription_NextMsg');
      return JsMessage.fromNativePtr(msgPtrPtr.value);
    } finally {
      calloc.free(msgPtrPtr);
    }
  }

  /// Unsubscribes and destroys this subscription.
  void close() {
    if (_closed) return;
    _closed = true;
    if (_sub != null) {
      final subPtr = _sub!;
      _sub = null;
      _finalizer.detach(this);
      natsSubscription_Unsubscribe(subPtr);
      natsSubscription_Destroy(subPtr);
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('JsSyncSubscription is already closed');
  }
}

/// An asynchronous JetStream subscription that delivers messages via a Stream.
///
/// Messages arrive as [JsMessage] objects with ack capabilities. Native
/// resources are automatically released after a terminal ack.
final class JsAsyncSubscription implements Finalizable {
  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(Pointer<natsSubscription>)>>(
      natsSubscription_Destroy,
    ).cast(),
  );

  /// Static routing table for JetStream async subscriptions.
  static final Map<int, StreamController<JsMessage>> _jsSubscriptionRoutes = {};
  static int _nextJsSubscriptionId = 1;

  Pointer<natsSubscription>? _sub;
  bool _closed = false;
  final int _id;
  final StreamController<JsMessage> _controller;
  final NativeCallable<
    Void Function(
      Pointer<natsConnection>,
      Pointer<natsSubscription>,
      Pointer<natsMsg>,
      Pointer<Void>,
    )
  >
  _nativeCallable;

  JsAsyncSubscription._(
    this._sub,
    this._id,
    this._controller,
    this._nativeCallable,
  );

  /// Creates a new JsAsyncSubscription with a pre-allocated routing slot.
  factory JsAsyncSubscription._create() {
    final id = _nextJsSubscriptionId++;
    final controller = StreamController<JsMessage>();
    _jsSubscriptionRoutes[id] = controller;

    final callable =
        NativeCallable<
          Void Function(
            Pointer<natsConnection>,
            Pointer<natsSubscription>,
            Pointer<natsMsg>,
            Pointer<Void>,
          )
        >.listener(_onJsMessage);

    return JsAsyncSubscription._(null, id, controller, callable);
  }

  /// Native callback for JetStream message delivery.
  static void _onJsMessage(
    Pointer<natsConnection> nc,
    Pointer<natsSubscription> sub,
    Pointer<natsMsg> msg,
    Pointer<Void> closure,
  ) {
    final id = closure.address;
    final controller = _jsSubscriptionRoutes[id];
    if (controller == null || controller.isClosed) {
      natsMsg_Destroy(msg);
      return;
    }
    try {
      final message = JsMessage.fromNativePtr(msg);
      controller.add(message);
    } catch (e, stackTrace) {
      try {
        natsMsg_Destroy(msg);
      } catch (_) {}
      controller.addError(e, stackTrace);
    }
  }

  /// Updates the native subscription pointer after the C call succeeds.
  void _updateSubPtr(Pointer<natsSubscription> sub) {
    _sub = sub;
    _finalizer.attach(this, _sub!.cast(), detach: this);
  }

  /// A stream of JetStream messages delivered to this subscription.
  Stream<JsMessage> get messages => _controller.stream;

  /// Whether this subscription has been closed.
  bool get isClosed => _closed;

  /// Unsubscribes and destroys this subscription.
  Future<void> close() {
    if (_closed) return Future.value();
    _closed = true;

    _jsSubscriptionRoutes.remove(_id);

    if (_sub != null) {
      final subPtr = _sub!;
      _sub = null;
      _finalizer.detach(this);
      natsSubscription_Unsubscribe(subPtr);
      natsSubscription_Destroy(subPtr);
    }

    _nativeCallable.close();

    if (_controller.hasListener) {
      return _controller.close();
    }
    _controller.close();
    return Future.value();
  }
}

/// A JetStream pull subscription that fetches messages in batches.
final class JsPullSubscription implements Finalizable {
  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(Pointer<natsSubscription>)>>(
      natsSubscription_Destroy,
    ).cast(),
  );

  Pointer<natsSubscription>? _sub;
  bool _closed = false;

  JsPullSubscription._(Pointer<natsSubscription> sub) : _sub = sub {
    _finalizer.attach(this, _sub!.cast(), detach: this);
  }

  /// Fetches up to [batchSize] messages, waiting up to [timeout].
  ///
  /// Returns a list of [JsMessage] objects. Native resources are
  /// automatically released after a terminal ack on each message.
  List<JsMessage> fetch(
    int batchSize, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    _ensureOpen();
    final msgList = calloc<natsMsgList>();
    final errCode = calloc<UnsignedInt>();
    try {
      final status = natsSubscription_Fetch(
        msgList,
        _sub!,
        batchSize,
        timeout.inMilliseconds,
        errCode,
      );

      // Partial batch (timeout but got some messages) is OK; other errors are not
      final isPartialBatch =
          status == natsStatus.NATS_TIMEOUT && msgList.ref.Count > 0;
      if (status != natsStatus.NATS_OK && !isPartialBatch) {
        checkStatus(status, 'natsSubscription_Fetch');
      }

      final messages = <JsMessage>[];
      for (var i = 0; i < msgList.ref.Count; i++) {
        messages.add(JsMessage.fromNativePtr(msgList.ref.Msgs[i]));
      }
      return messages;
    } finally {
      calloc.free(errCode);
      // The natsMsgList struct itself is stack-allocated (calloc'd), but
      // the Msgs array inside is owned by the C library. After we've
      // consumed the messages (fromNativePtr keeps the pointers alive),
      // we only free our calloc'd wrapper.
      calloc.free(msgList);
    }
  }

  /// Closes this pull subscription.
  void close() {
    if (_closed) return;
    _closed = true;
    if (_sub != null) {
      final subPtr = _sub!;
      _sub = null;
      _finalizer.detach(this);
      natsSubscription_Unsubscribe(subPtr);
      natsSubscription_Destroy(subPtr);
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('JsPullSubscription is already closed');
  }
}

// ── JetStreamContext ────────────────────────────────────────────────────

/// A JetStream context for publishing, subscribing, and managing streams
/// and consumers.
///
/// Obtain via [NatsClient.jetStream].
final class JetStreamContext {
  Pointer<jsCtx>? _js;
  bool _closed = false;

  JetStreamContext._(this._js);

  /// Creates a JetStream context from the given connection pointer.
  static JetStreamContext create(Pointer<natsConnection> nc) {
    final jsPtrPtr = calloc<Pointer<jsCtx>>();
    final jsOpts = calloc<jsOptions>();
    try {
      checkStatus(jsOptions_Init(jsOpts), 'jsOptions_Init');
      checkStatus(
        natsConnection_JetStream(jsPtrPtr, nc, jsOpts),
        'natsConnection_JetStream',
      );
      return JetStreamContext._(jsPtrPtr.value);
    } finally {
      calloc.free(jsOpts);
      calloc.free(jsPtrPtr);
    }
  }

  /// The native JetStream context pointer.
  Pointer<jsCtx> get nativePtr {
    _ensureOpen();
    return _js!;
  }

  // ── Publishing ──────────────────────────────────────────────────────

  /// Publishes raw [data] to the given [subject] via JetStream.
  JsPubAckResult publish(String subject, Uint8List data) {
    _ensureOpen();
    final subjectNative = subject.toNativeUtf8();
    final dataPtr = malloc<Uint8>(data.length);
    final pubAckPtrPtr = calloc<Pointer<jsPubAck>>();
    final errCode = calloc<UnsignedInt>();
    try {
      dataPtr.asTypedList(data.length).setAll(0, data);
      final status = js_Publish(
        pubAckPtrPtr,
        _js!,
        subjectNative.cast(),
        dataPtr.cast(),
        data.length,
        nullptr, // default pub options
        errCode,
      );
      checkStatus(status, 'js_Publish');
      return _extractPubAck(pubAckPtrPtr.value);
    } finally {
      calloc.free(errCode);
      calloc.free(pubAckPtrPtr);
      malloc.free(dataPtr);
      calloc.free(subjectNative);
    }
  }

  /// Publishes a string [message] to the given [subject] via JetStream.
  JsPubAckResult publishString(String subject, String message) {
    return publish(subject, Uint8List.fromList(message.codeUnits));
  }

  JsPubAckResult _extractPubAck(Pointer<jsPubAck> pubAckPtr) {
    final result = JsPubAckResult(
      stream: pubAckPtr.ref.Stream.cast<Utf8>().toDartString(),
      sequence: pubAckPtr.ref.Sequence,
      domain: pubAckPtr.ref.Domain == nullptr
          ? null
          : pubAckPtr.ref.Domain.cast<Utf8>().toDartString(),
      duplicate: pubAckPtr.ref.Duplicate,
    );
    jsPubAck_Destroy(pubAckPtr);
    return result;
  }

  // ── Subscriptions ───────────────────────────────────────────────────

  /// Creates a synchronous JetStream subscription on the given [subject].
  ///
  /// **Warning:** [JsSyncSubscription.nextMessage] blocks the event loop.
  JsSyncSubscription subscribeSync(
    String subject, {
    String? stream,
    String? durable,
    bool manualAck = true,
  }) {
    _ensureOpen();
    final subPtrPtr = calloc<Pointer<natsSubscription>>();
    final subjectNative = subject.toNativeUtf8();
    final subOpts = calloc<jsSubOptions>();
    final errCode = calloc<UnsignedInt>();
    final nativeStrings = <Pointer<Utf8>>[];
    try {
      checkStatus(jsSubOptions_Init(subOpts), 'jsSubOptions_Init');
      subOpts.ref.ManualAck = manualAck;
      if (stream != null) {
        final streamNative = stream.toNativeUtf8();
        nativeStrings.add(streamNative);
        subOpts.ref.Stream = streamNative.cast();
      }
      if (durable != null) {
        final durableNative = durable.toNativeUtf8();
        nativeStrings.add(durableNative);
        subOpts.ref.Config.Durable = durableNative.cast();
      }

      final status = js_SubscribeSync(
        subPtrPtr,
        _js!,
        subjectNative.cast(),
        nullptr, // default js options
        subOpts,
        errCode,
      );
      checkStatus(status, 'js_SubscribeSync');
      return JsSyncSubscription._(subPtrPtr.value);
    } finally {
      for (final ptr in nativeStrings) {
        calloc.free(ptr);
      }
      calloc.free(errCode);
      calloc.free(subOpts);
      calloc.free(subjectNative);
      calloc.free(subPtrPtr);
    }
  }

  /// Creates an asynchronous JetStream subscription on the given [subject].
  ///
  /// Messages are delivered via [JsAsyncSubscription.messages].
  JsAsyncSubscription subscribe(
    String subject, {
    String? stream,
    String? durable,
    bool manualAck = true,
  }) {
    _ensureOpen();
    final subPtrPtr = calloc<Pointer<natsSubscription>>();
    final subjectNative = subject.toNativeUtf8();
    final subOpts = calloc<jsSubOptions>();
    final errCode = calloc<UnsignedInt>();
    final nativeStrings = <Pointer<Utf8>>[];
    JsAsyncSubscription? asyncSub;
    try {
      checkStatus(jsSubOptions_Init(subOpts), 'jsSubOptions_Init');
      subOpts.ref.ManualAck = manualAck;
      if (stream != null) {
        final streamNative = stream.toNativeUtf8();
        nativeStrings.add(streamNative);
        subOpts.ref.Stream = streamNative.cast();
      }
      if (durable != null) {
        final durableNative = durable.toNativeUtf8();
        nativeStrings.add(durableNative);
        subOpts.ref.Config.Durable = durableNative.cast();
      }

      asyncSub = JsAsyncSubscription._create();

      final status = js_Subscribe(
        subPtrPtr,
        _js!,
        subjectNative.cast(),
        asyncSub._nativeCallable.nativeFunction,
        Pointer.fromAddress(asyncSub._id),
        nullptr, // default js options
        subOpts,
        errCode,
      );
      checkStatus(status, 'js_Subscribe');

      asyncSub._updateSubPtr(subPtrPtr.value);
      return asyncSub;
    } catch (e) {
      asyncSub?.close();
      rethrow;
    } finally {
      for (final ptr in nativeStrings) {
        calloc.free(ptr);
      }
      calloc.free(errCode);
      calloc.free(subOpts);
      calloc.free(subjectNative);
      calloc.free(subPtrPtr);
    }
  }

  /// Creates a JetStream pull subscription on the given [subject] with
  /// the specified [durable] consumer name.
  JsPullSubscription pullSubscribe(
    String subject,
    String durable, {
    String? stream,
  }) {
    _ensureOpen();
    final subPtrPtr = calloc<Pointer<natsSubscription>>();
    final subjectNative = subject.toNativeUtf8();
    final durableNative = durable.toNativeUtf8();
    final subOpts = calloc<jsSubOptions>();
    final errCode = calloc<UnsignedInt>();
    final nativeStrings = <Pointer<Utf8>>[];
    try {
      checkStatus(jsSubOptions_Init(subOpts), 'jsSubOptions_Init');
      if (stream != null) {
        final streamNative = stream.toNativeUtf8();
        nativeStrings.add(streamNative);
        subOpts.ref.Stream = streamNative.cast();
      }

      final status = js_PullSubscribe(
        subPtrPtr,
        _js!,
        subjectNative.cast(),
        durableNative.cast(),
        nullptr, // default js options
        subOpts,
        errCode,
      );
      checkStatus(status, 'js_PullSubscribe');
      return JsPullSubscription._(subPtrPtr.value);
    } finally {
      for (final ptr in nativeStrings) {
        calloc.free(ptr);
      }
      calloc.free(errCode);
      calloc.free(subOpts);
      calloc.free(durableNative);
      calloc.free(subjectNative);
      calloc.free(subPtrPtr);
    }
  }

  // ── Stream management ───────────────────────────────────────────────

  /// Creates a new stream with the given configuration.
  JsStreamInfoResult addStream(JsStreamConfig config) {
    _ensureOpen();
    return _withStreamConfig(config, (cfgPtr, errCode) {
      final siPtrPtr = calloc<Pointer<jsStreamInfo>>();
      try {
        final status = js_AddStream(siPtrPtr, _js!, cfgPtr, nullptr, errCode);
        checkStatus(status, 'js_AddStream');
        return _extractStreamInfo(siPtrPtr.value);
      } finally {
        calloc.free(siPtrPtr);
      }
    });
  }

  /// Updates an existing stream with the given configuration.
  JsStreamInfoResult updateStream(JsStreamConfig config) {
    _ensureOpen();
    return _withStreamConfig(config, (cfgPtr, errCode) {
      final siPtrPtr = calloc<Pointer<jsStreamInfo>>();
      try {
        final status = js_UpdateStream(
          siPtrPtr,
          _js!,
          cfgPtr,
          nullptr,
          errCode,
        );
        checkStatus(status, 'js_UpdateStream');
        return _extractStreamInfo(siPtrPtr.value);
      } finally {
        calloc.free(siPtrPtr);
      }
    });
  }

  /// Deletes a stream by name.
  void deleteStream(String name) {
    _ensureOpen();
    final nameNative = name.toNativeUtf8();
    final errCode = calloc<UnsignedInt>();
    try {
      final status = js_DeleteStream(_js!, nameNative.cast(), nullptr, errCode);
      checkStatus(status, 'js_DeleteStream');
    } finally {
      calloc.free(errCode);
      calloc.free(nameNative);
    }
  }

  /// Gets information about a stream.
  JsStreamInfoResult getStreamInfo(String name) {
    _ensureOpen();
    final nameNative = name.toNativeUtf8();
    final siPtrPtr = calloc<Pointer<jsStreamInfo>>();
    final errCode = calloc<UnsignedInt>();
    try {
      final status = js_GetStreamInfo(
        siPtrPtr,
        _js!,
        nameNative.cast(),
        nullptr,
        errCode,
      );
      checkStatus(status, 'js_GetStreamInfo');
      return _extractStreamInfo(siPtrPtr.value);
    } finally {
      calloc.free(errCode);
      calloc.free(siPtrPtr);
      calloc.free(nameNative);
    }
  }

  /// Purges all messages from a stream.
  void purgeStream(String name) {
    _ensureOpen();
    final nameNative = name.toNativeUtf8();
    final errCode = calloc<UnsignedInt>();
    try {
      final status = js_PurgeStream(_js!, nameNative.cast(), nullptr, errCode);
      checkStatus(status, 'js_PurgeStream');
    } finally {
      calloc.free(errCode);
      calloc.free(nameNative);
    }
  }

  // ── Consumer management ─────────────────────────────────────────────

  /// Adds a consumer to the named stream.
  JsConsumerInfoResult addConsumer(String stream, JsConsumerConfig config) {
    _ensureOpen();
    return _withConsumerConfig(stream, config, (streamNative, ccPtr, errCode) {
      final ciPtrPtr = calloc<Pointer<jsConsumerInfo>>();
      try {
        final status = js_AddConsumer(
          ciPtrPtr,
          _js!,
          streamNative.cast(),
          ccPtr,
          nullptr,
          errCode,
        );
        checkStatus(status, 'js_AddConsumer');
        return _extractConsumerInfo(ciPtrPtr.value);
      } finally {
        calloc.free(ciPtrPtr);
      }
    });
  }

  /// Deletes a consumer from a stream.
  void deleteConsumer(String stream, String consumer) {
    _ensureOpen();
    final streamNative = stream.toNativeUtf8();
    final consumerNative = consumer.toNativeUtf8();
    final errCode = calloc<UnsignedInt>();
    try {
      final status = js_DeleteConsumer(
        _js!,
        streamNative.cast(),
        consumerNative.cast(),
        nullptr,
        errCode,
      );
      checkStatus(status, 'js_DeleteConsumer');
    } finally {
      calloc.free(errCode);
      calloc.free(consumerNative);
      calloc.free(streamNative);
    }
  }

  /// Gets information about a consumer.
  JsConsumerInfoResult getConsumerInfo(String stream, String consumer) {
    _ensureOpen();
    final streamNative = stream.toNativeUtf8();
    final consumerNative = consumer.toNativeUtf8();
    final ciPtrPtr = calloc<Pointer<jsConsumerInfo>>();
    final errCode = calloc<UnsignedInt>();
    try {
      final status = js_GetConsumerInfo(
        ciPtrPtr,
        _js!,
        streamNative.cast(),
        consumerNative.cast(),
        nullptr,
        errCode,
      );
      checkStatus(status, 'js_GetConsumerInfo');
      return _extractConsumerInfo(ciPtrPtr.value);
    } finally {
      calloc.free(errCode);
      calloc.free(ciPtrPtr);
      calloc.free(consumerNative);
      calloc.free(streamNative);
    }
  }

  // ── Cleanup ─────────────────────────────────────────────────────────

  /// Destroys the JetStream context.
  void close() {
    if (_closed) return;
    _closed = true;
    if (_js != null) {
      jsCtx_Destroy(_js!);
      _js = null;
    }
  }

  void _ensureOpen() {
    if (_closed) throw StateError('JetStreamContext is already closed');
  }

  // ── Helpers ─────────────────────────────────────────────────────────

  /// Sets up a native jsStreamConfig, calls [body], then frees resources.
  T _withStreamConfig<T>(
    JsStreamConfig config,
    T Function(Pointer<jsStreamConfig> cfgPtr, Pointer<UnsignedInt> errCode)
    body,
  ) {
    final cfgPtr = calloc<jsStreamConfig>();
    final errCode = calloc<UnsignedInt>();
    final nativeStrings = <Pointer<Utf8>>[];
    Pointer<Pointer<Char>>? subjectsArray;

    try {
      checkStatus(jsStreamConfig_Init(cfgPtr), 'jsStreamConfig_Init');

      final nameNative = config.name.toNativeUtf8();
      nativeStrings.add(nameNative);
      cfgPtr.ref.Name = nameNative.cast();

      if (config.description != null) {
        final descNative = config.description!.toNativeUtf8();
        nativeStrings.add(descNative);
        cfgPtr.ref.Description = descNative.cast();
      }

      if (config.subjects.isNotEmpty) {
        subjectsArray = calloc<Pointer<Char>>(config.subjects.length);
        for (var i = 0; i < config.subjects.length; i++) {
          final subjNative = config.subjects[i].toNativeUtf8();
          nativeStrings.add(subjNative);
          subjectsArray[i] = subjNative.cast();
        }
        cfgPtr.ref.Subjects = subjectsArray;
        cfgPtr.ref.SubjectsLen = config.subjects.length;
      }

      cfgPtr.ref.RetentionAsInt = config.retention.value;
      cfgPtr.ref.MaxConsumers = config.maxConsumers;
      cfgPtr.ref.MaxMsgs = config.maxMsgs;
      cfgPtr.ref.MaxBytes = config.maxBytes;
      if (config.maxAge != null) {
        // Safe for durations up to ~292 years (2^63 nanoseconds).
        cfgPtr.ref.MaxAge = config.maxAge!.inMicroseconds * 1000;
      }
      cfgPtr.ref.MaxMsgsPerSubject = config.maxMsgsPerSubject;
      cfgPtr.ref.MaxMsgSize = config.maxMsgSize;
      cfgPtr.ref.DiscardAsInt = config.discard.value;
      cfgPtr.ref.StorageAsInt = config.storage.value;
      cfgPtr.ref.Replicas = config.replicas;
      cfgPtr.ref.NoAck = config.noAck;

      return body(cfgPtr, errCode);
    } finally {
      for (final ptr in nativeStrings) {
        calloc.free(ptr);
      }
      if (subjectsArray != null) calloc.free(subjectsArray);
      calloc.free(errCode);
      calloc.free(cfgPtr);
    }
  }

  JsStreamInfoResult _extractStreamInfo(Pointer<jsStreamInfo> siPtr) {
    final configPtr = siPtr.ref.Config;
    final name = configPtr.ref.Name.cast<Utf8>().toDartString();
    final result = JsStreamInfoResult._(
      name: name,
      created: siPtr.ref.Created,
      messages: siPtr.ref.State.Msgs,
      bytes: siPtr.ref.State.Bytes,
      firstSeq: siPtr.ref.State.FirstSeq,
      lastSeq: siPtr.ref.State.LastSeq,
      consumers: siPtr.ref.State.Consumers,
    );
    jsStreamInfo_Destroy(siPtr);
    return result;
  }

  /// Sets up a native jsConsumerConfig, calls [body], then frees resources.
  T _withConsumerConfig<T>(
    String stream,
    JsConsumerConfig config,
    T Function(
      Pointer<Utf8> streamNative,
      Pointer<jsConsumerConfig> ccPtr,
      Pointer<UnsignedInt> errCode,
    )
    body,
  ) {
    final streamNative = stream.toNativeUtf8();
    final ccPtr = calloc<jsConsumerConfig>();
    final errCode = calloc<UnsignedInt>();
    final nativeStrings = <Pointer<Utf8>>[];

    try {
      checkStatus(jsConsumerConfig_Init(ccPtr), 'jsConsumerConfig_Init');

      if (config.name != null) {
        final nameNative = config.name!.toNativeUtf8();
        nativeStrings.add(nameNative);
        ccPtr.ref.Name = nameNative.cast();
      }
      if (config.durable != null) {
        final durableNative = config.durable!.toNativeUtf8();
        nativeStrings.add(durableNative);
        ccPtr.ref.Durable = durableNative.cast();
      }
      if (config.description != null) {
        final descNative = config.description!.toNativeUtf8();
        nativeStrings.add(descNative);
        ccPtr.ref.Description = descNative.cast();
      }
      ccPtr.ref.DeliverPolicyAsInt = config.deliverPolicy.value;
      ccPtr.ref.AckPolicyAsInt = config.ackPolicy.value;
      ccPtr.ref.ReplayPolicyAsInt = config.replayPolicy.value;
      if (config.filterSubject != null) {
        final filterNative = config.filterSubject!.toNativeUtf8();
        nativeStrings.add(filterNative);
        ccPtr.ref.FilterSubject = filterNative.cast();
      }
      if (config.maxDeliver != null) {
        ccPtr.ref.MaxDeliver = config.maxDeliver!;
      }
      if (config.ackWait != null) {
        // Safe for durations up to ~292 years (2^63 nanoseconds).
        ccPtr.ref.AckWait = config.ackWait!.inMicroseconds * 1000;
      }
      if (config.deliverSubject != null) {
        final deliverNative = config.deliverSubject!.toNativeUtf8();
        nativeStrings.add(deliverNative);
        ccPtr.ref.DeliverSubject = deliverNative.cast();
      }
      if (config.deliverGroup != null) {
        final groupNative = config.deliverGroup!.toNativeUtf8();
        nativeStrings.add(groupNative);
        ccPtr.ref.DeliverGroup = groupNative.cast();
      }
      if (config.maxAckPending != null) {
        ccPtr.ref.MaxAckPending = config.maxAckPending!;
      }

      return body(streamNative, ccPtr, errCode);
    } finally {
      for (final ptr in nativeStrings) {
        calloc.free(ptr);
      }
      calloc.free(errCode);
      calloc.free(ccPtr);
      calloc.free(streamNative);
    }
  }

  JsConsumerInfoResult _extractConsumerInfo(Pointer<jsConsumerInfo> ciPtr) {
    final result = JsConsumerInfoResult._(
      stream: ciPtr.ref.Stream.cast<Utf8>().toDartString(),
      name: ciPtr.ref.Name.cast<Utf8>().toDartString(),
      created: ciPtr.ref.Created,
      numAckPending: ciPtr.ref.NumAckPending,
      numRedelivered: ciPtr.ref.NumRedelivered,
      numWaiting: ciPtr.ref.NumWaiting,
      numPending: ciPtr.ref.NumPending,
    );
    jsConsumerInfo_Destroy(ciPtr);
    return result;
  }
}
