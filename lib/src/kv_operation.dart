/// Type of mutation recorded on a NATS Key-Value entry.
///
/// Wraps the C-style `kvOperation` FFI enum with Dart-idiomatic names.
enum KvOperation {
  /// The operation type could not be determined.
  unknown(0),

  /// A value was stored or updated.
  put(1),

  /// The key was soft-deleted (a delete marker was written).
  delete(2),

  /// The key and all its revisions were permanently removed.
  purge(3);

  /// The underlying integer value for this operation.
  final int value;

  /// Creates a [KvOperation] with the given integer [value].
  const KvOperation(this.value);

  /// Returns the [KvOperation] corresponding to the given integer [value].
  static KvOperation fromValue(int value) => switch (value) {
    0 => unknown,
    1 => put,
    2 => delete,
    3 => purge,
    _ => throw ArgumentError('Unknown value for KvOperation: $value'),
  };
}
