/// Storage backend for a JetStream stream.
///
/// Wraps the C-style `jsStorageType` FFI enum with Dart-idiomatic names.
enum StorageType {
  /// Persist messages to disk. This is the default.
  file(0),

  /// Store messages in memory only.
  memory(1);

  final int value;
  const StorageType(this.value);

  static StorageType fromValue(int value) => switch (value) {
    0 => file,
    1 => memory,
    _ => throw ArgumentError('Unknown value for StorageType: $value'),
  };
}
