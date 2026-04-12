/// Storage backend for a JetStream stream.
///
/// Wraps the C-style `jsStorageType` FFI enum with Dart-idiomatic names.
enum StorageType {
  /// Persist messages to disk. This is the default.
  file(0),

  /// Store messages in memory only.
  memory(1);

  /// The underlying integer value used by the NATS C library.
  final int value;

  /// Creates a [StorageType] from its C-level integer [value].
  const StorageType(this.value);

  /// Returns the [StorageType] corresponding to the given integer [value].
  static StorageType fromValue(int value) => switch (value) {
    0 => file,
    1 => memory,
    _ => throw ArgumentError('Unknown value for StorageType: $value'),
  };
}
