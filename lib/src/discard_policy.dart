/// Behaviour when a JetStream stream reaches its message or byte limit.
///
/// Wraps the C-style `jsDiscardPolicy` FFI enum with Dart-idiomatic names.
enum DiscardPolicy {
  /// Remove older messages to make room. This is the default.
  discardOld(0),

  /// Reject new messages when the limit is reached.
  discardNew(1);

  /// The underlying integer value used by the NATS C library.
  final int value;

  /// Creates a [DiscardPolicy] from its C-level integer [value].
  const DiscardPolicy(this.value);

  /// Returns the [DiscardPolicy] corresponding to the given integer [value].
  static DiscardPolicy fromValue(int value) => switch (value) {
    0 => discardOld,
    1 => discardNew,
    _ => throw ArgumentError('Unknown value for DiscardPolicy: $value'),
  };
}
