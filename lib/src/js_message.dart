import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import 'nats_bindings.g.dart';
import 'nats_exceptions.dart';

/// A JetStream message that supports acknowledgement operations.
///
/// Data fields ([subject], [data], [replyTo]) and [metadata] are eagerly
/// copied at construction and remain accessible for the lifetime of the
/// object — including after acknowledgement.
///
/// Native resources are automatically released after any terminal ack
/// operation ([ack], [ackSync], [nak], [term]). A [NativeFinalizer] serves
/// as a safety net for abrupt shutdown. Calling a second terminal ack on
/// the same message throws a [StateError].
///
/// [inProgress] is non-terminal and does not release resources — you must
/// still follow up with a terminal ack.
final class JsMessage implements Finalizable {
  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(Pointer<natsMsg>)>>(
      natsMsg_Destroy,
    ).cast(),
  );

  /// The subject this message was published to.
  final String subject;

  /// The raw payload bytes.
  final Uint8List data;

  /// The reply-to subject, if present.
  final String? replyTo;

  Pointer<natsMsg>? _msgPtr;
  bool _destroyed = false;
  final JsMessageMetadata _cachedMetadata;

  JsMessage._({
    required this.subject,
    required this.data,
    this.replyTo,
    required Pointer<natsMsg> msgPtr,
    required JsMessageMetadata cachedMetadata,
  }) : _msgPtr = msgPtr,
       _cachedMetadata = cachedMetadata {
    _finalizer.attach(this, msgPtr.cast(), detach: this);
  }

  /// Convenience getter that decodes [data] as a UTF-8 string.
  String get dataAsString => utf8.decode(data);

  /// Returns a human-readable representation including the subject, optional
  /// reply-to, and UTF-8 decoded payload.
  @override
  String toString() {
    final reply = replyTo != null ? ', replyTo: $replyTo' : '';
    return 'JsMessage(subject: $subject$reply, data: $dataAsString)';
  }

  /// Extracts [JsMessageMetadata] from a native `natsMsg` pointer.
  static JsMessageMetadata _extractMetadata(Pointer<natsMsg> msgPtr) {
    final metaPtrPtr = calloc<Pointer<jsMsgMetaData>>();
    try {
      checkStatus(
        natsMsg_GetMetaData(metaPtrPtr, msgPtr),
        'natsMsg_GetMetaData',
      );
      final meta = metaPtrPtr.value;
      final result = JsMessageMetadata._(
        streamSequence: meta.ref.Sequence.Stream,
        consumerSequence: meta.ref.Sequence.Consumer,
        numDelivered: meta.ref.NumDelivered,
        numPending: meta.ref.NumPending,
        timestamp: meta.ref.Timestamp,
        stream: meta.ref.Stream.cast<Utf8>().toDartString(),
        consumer: meta.ref.Consumer.cast<Utf8>().toDartString(),
        domain: meta.ref.Domain == nullptr
            ? null
            : meta.ref.Domain.cast<Utf8>().toDartString(),
      );
      jsMsgMetaData_Destroy(meta);
      return result;
    } finally {
      calloc.free(metaPtrPtr);
    }
  }

  /// Creates a [JsMessage] by eagerly copying data fields from a native
  /// `natsMsg` pointer.
  ///
  /// Unlike [NatsMessage.fromNativePtr], the native pointer is **not**
  /// destroyed — it is kept alive for ack/nak operations.
  factory JsMessage.fromNativePtr(Pointer<natsMsg> msgPtr) {
    if (msgPtr == nullptr) {
      throw ArgumentError('Cannot create JsMessage from a null pointer');
    }
    final subject = natsMsg_GetSubject(msgPtr).cast<Utf8>().toDartString();
    final dataLen = natsMsg_GetDataLength(msgPtr);
    final dataPtr = natsMsg_GetData(msgPtr);
    final data = Uint8List.fromList(dataPtr.cast<Uint8>().asTypedList(dataLen));

    final replyPtr = natsMsg_GetReply(msgPtr);
    final replyTo = replyPtr == nullptr
        ? null
        : replyPtr.cast<Utf8>().toDartString();

    final metadata = _extractMetadata(msgPtr);

    return JsMessage._(
      subject: subject,
      data: data,
      replyTo: replyTo,
      msgPtr: msgPtr,
      cachedMetadata: metadata,
    );
  }

  /// Acknowledges successful processing of this message.
  ///
  /// Automatically releases native resources after a successful ack.
  void ack() {
    _ensureAlive();
    checkStatus(natsMsg_Ack(_msgPtr!, nullptr), 'natsMsg_Ack');
    _destroy();
  }

  /// Synchronously acknowledges this message, waiting for server confirmation.
  ///
  /// Automatically releases native resources after a successful ack.
  void ackSync({Duration timeout = const Duration(seconds: 5)}) {
    _ensureAlive();
    final jsOpts = calloc<jsOptions>();
    try {
      checkStatus(jsOptions_Init(jsOpts), 'jsOptions_Init');
      jsOpts.ref.Wait = timeout.inMilliseconds;
      final errCode = calloc<UnsignedInt>();
      try {
        checkStatus(
          natsMsg_AckSync(_msgPtr!, jsOpts, errCode),
          'natsMsg_AckSync',
        );
      } finally {
        calloc.free(errCode);
      }
    } finally {
      calloc.free(jsOpts);
    }
    _destroy();
  }

  /// Negatively acknowledges the message, requesting redelivery.
  ///
  /// Automatically releases native resources after a successful nak.
  void nak({Duration? delay}) {
    _ensureAlive();
    if (delay != null) {
      checkStatus(
        natsMsg_NakWithDelay(_msgPtr!, delay.inMilliseconds, nullptr),
        'natsMsg_NakWithDelay',
      );
    } else {
      checkStatus(natsMsg_Nak(_msgPtr!, nullptr), 'natsMsg_Nak');
    }
    _destroy();
  }

  /// Signals that processing is still in progress, resetting the ack-wait
  /// timer on the server.
  void inProgress() {
    _ensureAlive();
    checkStatus(natsMsg_InProgress(_msgPtr!, nullptr), 'natsMsg_InProgress');
  }

  /// Terminates processing of this message — the server will not attempt
  /// redelivery.
  ///
  /// Automatically releases native resources after a successful term.
  void term() {
    _ensureAlive();
    checkStatus(natsMsg_Term(_msgPtr!, nullptr), 'natsMsg_Term');
    _destroy();
  }

  /// Returns JetStream metadata for this message (stream name, consumer
  /// name, sequence numbers, timestamp, etc.).
  ///
  /// Metadata is eagerly cached at construction time, so this method
  /// remains accessible even after the native pointer has been freed.
  JsMessageMetadata metadata() => _cachedMetadata;

  /// Destroys the native message pointer. Safe to call multiple times.
  void _destroy() {
    if (_destroyed) return;
    _destroyed = true;
    if (_msgPtr != null) {
      _finalizer.detach(this);
      natsMsg_Destroy(_msgPtr!);
      _msgPtr = null;
    }
  }

  void _ensureAlive() {
    if (_destroyed) {
      throw StateError(
        'JsMessage has already been acknowledged and its native resources '
        'released. Data fields and metadata remain accessible.',
      );
    }
  }
}

/// Eagerly-copied JetStream message metadata.
@immutable
final class JsMessageMetadata {
  /// The stream sequence number.
  final int streamSequence;

  /// The consumer sequence number.
  final int consumerSequence;

  /// The number of times this message has been delivered.
  final int numDelivered;

  /// The number of messages pending for this consumer.
  final int numPending;

  /// The message timestamp as nanoseconds since epoch.
  final int timestamp;

  /// The stream name.
  final String stream;

  /// The consumer name.
  final String consumer;

  /// The JetStream domain, if applicable.
  final String? domain;

  JsMessageMetadata._({
    required this.streamSequence,
    required this.consumerSequence,
    required this.numDelivered,
    required this.numPending,
    required this.timestamp,
    required this.stream,
    required this.consumer,
    this.domain,
  });

  /// Returns a human-readable summary of this metadata.
  @override
  String toString() =>
      'JsMessageMetadata(stream: $stream, seq: $streamSequence, '
      'consumer: $consumer, delivered: $numDelivered)';
}

/// Eagerly-copied JetStream publish acknowledgement.
@immutable
final class JsPubAckResult {
  /// The stream the message was published to.
  final String stream;

  /// The sequence number assigned by the stream.
  final int sequence;

  /// The JetStream domain, if applicable.
  final String? domain;

  /// Whether the server detected this as a duplicate.
  final bool duplicate;

  /// @nodoc — Use [JetStreamContext.publish] to obtain instances.
  @internal
  JsPubAckResult({
    required this.stream,
    required this.sequence,
    this.domain,
    required this.duplicate,
  });

  /// Returns a human-readable summary of this publish acknowledgement.
  @override
  String toString() =>
      'JsPubAckResult(stream: $stream, sequence: $sequence, '
      'duplicate: $duplicate)';
}
