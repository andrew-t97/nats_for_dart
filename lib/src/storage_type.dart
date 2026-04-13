/// Storage backend for a JetStream stream.
enum StorageType {
  /// Persist messages to disk. This is the default.
  file(0),

  /// Store messages in memory only.
  memory(1);

  /// The underlying integer value for this storage type.
  final int value;

  /// Creates a [StorageType] with the given integer [value].
  const StorageType(this.value);

  /// Returns the [StorageType] corresponding to the given integer [value].
  static StorageType fromValue(int value) => switch (value) {
    0 => file,
    1 => memory,
    _ => throw ArgumentError('Unknown value for StorageType: $value'),
  };
}
