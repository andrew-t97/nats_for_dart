/// Replay speed for queued messages delivered to a JetStream consumer.
///
/// Wraps the C-style `jsReplayPolicy` FFI enum with Dart-idiomatic names.
enum ReplayPolicy {
  /// Replay messages as fast as possible.
  instant(0),

  /// Replay messages at the same rate they were originally received.
  original(1);

  final int value;
  const ReplayPolicy(this.value);

  static ReplayPolicy fromValue(int value) => switch (value) {
    0 => instant,
    1 => original,
    _ => throw ArgumentError('Unknown value for ReplayPolicy: $value'),
  };
}
