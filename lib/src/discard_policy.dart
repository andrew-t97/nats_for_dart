/// Behaviour when a JetStream stream reaches its message or byte limit.
///
/// Wraps the C-style `jsDiscardPolicy` FFI enum with Dart-idiomatic names.
enum DiscardPolicy {
  /// Remove older messages to make room. This is the default.
  discardOld(0),

  /// Reject new messages when the limit is reached.
  discardNew(1);

  final int value;
  const DiscardPolicy(this.value);

  static DiscardPolicy fromValue(int value) => switch (value) {
    0 => discardOld,
    1 => discardNew,
    _ => throw ArgumentError('Unknown value for DiscardPolicy: $value'),
  };
}
