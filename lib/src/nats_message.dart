import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import 'internal/headers_codec.dart';
import 'nats_bindings.g.dart';
import 'nats_headers.dart';

/// A message received from a NATS subscription.
///
/// All fields are eagerly copied from the native `natsMsg` pointer so this
/// object is safe to use after the underlying pointer has been destroyed.
@immutable
final class NatsMessage {
  /// The subject this message was published to.
  final String subject;

  /// The raw payload bytes.
  final Uint8List data;

  /// The reply-to subject, if present.
  final String? replyTo;

  /// The message headers; always non-null. Empty for headerless messages.
  final NatsHeaders headers;

  NatsMessage._(this.subject, this.data, this.replyTo, this.headers);

  /// Convenience getter that decodes [data] as a UTF-8 string.
  String get dataAsString => utf8.decode(data);

  /// Returns a human-readable representation including the subject, optional
  /// reply-to, and UTF-8 decoded payload.
  @override
  String toString() {
    final reply = replyTo != null ? ', replyTo: $replyTo' : '';
    final hdrs = headers.isEmpty ? '' : ', headers: ${headers.keys.toList()}';
    return 'NatsMessage(subject: $subject$reply$hdrs, data: $dataAsString)';
  }

  /// Creates a [NatsMessage] by eagerly copying data out of a native
  /// `natsMsg` pointer, then destroying the native message.
  ///
  /// This is the canonical way to materialise a message from a native
  /// pointer.
  factory NatsMessage.fromNativePtr(Pointer<natsMsg> msgPtr) {
    if (msgPtr == nullptr) {
      throw ArgumentError('Cannot create NatsMessage from a null pointer');
    }
    final subject = natsMsg_GetSubject(msgPtr).cast<Utf8>().toDartString();
    final dataLen = natsMsg_GetDataLength(msgPtr);
    final dataPtr = natsMsg_GetData(msgPtr);
    final data = Uint8List.fromList(dataPtr.cast<Uint8>().asTypedList(dataLen));

    final replyPtr = natsMsg_GetReply(msgPtr);
    final replyTo = replyPtr == nullptr
        ? null
        : replyPtr.cast<Utf8>().toDartString();

    // Headers must be read before natsMsg_Destroy — the inner key/value
    // strings are owned by the message.
    final headers = readHeadersFromMsg(msgPtr);

    natsMsg_Destroy(msgPtr);
    return NatsMessage._(subject, data, replyTo, headers);
  }
}
