/// Replay speed for queued messages delivered to a JetStream consumer.
enum ReplayPolicy {
  /// Replay messages as fast as possible.
  instant(0),

  /// Replay messages at the same rate they were originally received.
  original(1);

  /// The underlying integer value for this policy.
  final int value;

  /// Creates a [ReplayPolicy] with the given integer [value].
  const ReplayPolicy(this.value);

  /// Returns the [ReplayPolicy] corresponding to the given integer [value].
  static ReplayPolicy fromValue(int value) => switch (value) {
    0 => instant,
    1 => original,
    _ => throw ArgumentError('Unknown value for ReplayPolicy: $value'),
  };
}
