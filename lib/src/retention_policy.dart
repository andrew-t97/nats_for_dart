/// Message retention strategy for a JetStream stream.
///
/// Controls when messages are removed from a stream.
enum RetentionPolicy {
  /// Retain messages until any configured limit (MaxMsgs, MaxBytes, or
  /// MaxAge) is reached. This is the default.
  limits(0),

  /// Remove a message once all known consumers have acknowledged it.
  interest(1),

  /// Remove a message as soon as the first consumer acknowledges it.
  workQueue(2);

  /// The underlying integer value for this policy.
  final int value;

  /// Creates a [RetentionPolicy] with the given integer [value].
  const RetentionPolicy(this.value);

  /// Returns the [RetentionPolicy] corresponding to the given integer [value].
  static RetentionPolicy fromValue(int value) => switch (value) {
    0 => limits,
    1 => interest,
    2 => workQueue,
    _ => throw ArgumentError('Unknown value for RetentionPolicy: $value'),
  };
}
