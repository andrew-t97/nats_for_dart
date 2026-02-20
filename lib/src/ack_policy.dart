/// Acknowledgement strategy for a JetStream consumer.
///
/// Controls how the server tracks which messages have been processed.
/// Wraps the C-style `jsAckPolicy` FFI enum with Dart-idiomatic names.
enum AckPolicy {
  /// Require an explicit ack or nack for every message.
  explicit(0),

  /// No acknowledgement required; messages are considered delivered
  /// immediately.
  none(1),

  /// Acknowledging a sequence implicitly acks all earlier sequences.
  all(2);

  final int value;
  const AckPolicy(this.value);

  static AckPolicy fromValue(int value) => switch (value) {
    0 => explicit,
    1 => none,
    2 => all,
    _ => throw ArgumentError('Unknown value for AckPolicy: $value'),
  };
}
