/// Starting point for message delivery to a JetStream consumer.
///
/// Controls which message in the stream a new consumer begins reading from.
/// Wraps the C-style `jsDeliverPolicy` FFI enum with Dart-idiomatic names.
enum DeliverPolicy {
  /// Start from the very beginning of the stream. This is the default.
  deliverAll(0),

  /// Start with the last sequence received.
  deliverLast(1),

  /// Start with messages sent after the consumer is created.
  deliverNew(2),

  /// Start from a given sequence number.
  deliverByStartSequence(3),

  /// Start from a given UTC time (nanoseconds since epoch).
  deliverByStartTime(4),

  /// Start with the last message for each subject in the stream.
  deliverLastPerSubject(5);

  final int value;
  const DeliverPolicy(this.value);

  static DeliverPolicy fromValue(int value) => switch (value) {
    0 => deliverAll,
    1 => deliverLast,
    2 => deliverNew,
    3 => deliverByStartSequence,
    4 => deliverByStartTime,
    5 => deliverLastPerSubject,
    _ => throw ArgumentError('Unknown value for DeliverPolicy: $value'),
  };
}
