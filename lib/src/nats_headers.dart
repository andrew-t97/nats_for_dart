import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// Immutable, value-equal collection of NATS message headers.
///
/// Headers are HTTP-style `name: value` pairs carried alongside a NATS
/// message body. A single key may map to multiple values; per-key value
/// order is significant (it is the order in which values were added),
/// while the key-set order is not.
///
/// Construct with [NatsHeaders.empty] for the headerless case (a true
/// const singleton, allocation-free), [NatsHeaders.from] for the common
/// case of a literal map, or [NatsHeaders.fromEntries] when repeated-key
/// ordering matters and a map literal would silently drop duplicates.
@immutable
final class NatsHeaders {
  static const MapEquality<String, List<String>> _entriesEquality =
      MapEquality<String, List<String>>(values: ListEquality<String>());

  final Map<String, List<String>> _entries;

  const NatsHeaders._(this._entries);

  /// A shared empty instance with zero allocations on the headerless hot
  /// path.
  const NatsHeaders.empty() : _entries = const <String, List<String>>{};

  /// Permissive constructor accepting a map of header names to either a
  /// single `String` value or a `List<String>` of values. The map's key
  /// insertion order is preserved as the header key order; per-key list
  /// order is preserved as the value Add-order.
  ///
  /// Throws [ArgumentError] if any value is not a `String` or
  /// `List<String>`, if any key is empty or contains a non-`tchar`
  /// character, or if any value contains CR, LF, or NUL.
  factory NatsHeaders.from(Map<String, Object> headers) {
    if (headers.isEmpty) {
      return const NatsHeaders.empty();
    }

    final entries = <String, List<String>>{};
    headers.forEach((key, value) {
      _validateKey(key);

      final List<String> values;
      if (value is String) {
        _validateValue(key, value);
        values = List<String>.unmodifiable(<String>[value]);
      } else if (value is List<String>) {
        for (final v in value) {
          _validateValue(key, v);
        }
        values = List<String>.unmodifiable(value);
      } else {
        throw ArgumentError.value(
          value,
          'headers["$key"]',
          'NatsHeaders values must be String or List<String>; '
              'got ${value.runtimeType}',
        );
      }

      entries[key] = values;
    });

    return NatsHeaders._(entries);
  }

  /// Constructs from an iterable of `MapEntry<String, String>`. Repeated
  /// keys are appended in the order they appear — this is the only
  /// construction shape that preserves repeated-key ordering, since map
  /// literals silently drop duplicate keys.
  ///
  /// Throws [ArgumentError] under the same conditions as [NatsHeaders.from].
  factory NatsHeaders.fromEntries(Iterable<MapEntry<String, String>> entries) {
    final mutable = <String, List<String>>{};
    for (final entry in entries) {
      _validateKey(entry.key);
      _validateValue(entry.key, entry.value);
      (mutable[entry.key] ??= <String>[]).add(entry.value);
    }

    if (mutable.isEmpty) {
      return const NatsHeaders.empty();
    }

    final frozen = <String, List<String>>{
      for (final entry in mutable.entries)
        entry.key: List<String>.unmodifiable(entry.value),
    };
    return NatsHeaders._(frozen);
  }

  /// Whether there are no headers.
  bool get isEmpty => _entries.isEmpty;

  /// Whether there is at least one header.
  bool get isNotEmpty => _entries.isNotEmpty;

  /// All header keys in insertion order.
  Iterable<String> get keys => _entries.keys;

  /// Whether [key] has at least one value.
  bool containsKey(String key) => _entries.containsKey(key);

  /// The first value for [key], or `null` when [key] is absent.
  String? firstOrNull(String key) {
    final values = _entries[key];
    return (values == null || values.isEmpty) ? null : values.first;
  }

  /// All values for [key] in Add-order, or an empty list when [key] is
  /// absent. Never returns `null`. The returned list is unmodifiable.
  List<String> getAll(String key) => _entries[key] ?? const <String>[];

  /// An unmodifiable view of the headers as a map. Per-key lists are
  /// also unmodifiable (mutation throws [UnsupportedError]). Allocates
  /// a fresh outer map per call; per-key lists are shared with the
  /// internal storage and never copied.
  Map<String, List<String>> toMap() =>
      UnmodifiableMapView<String, List<String>>(
        Map<String, List<String>>.of(_entries),
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is NatsHeaders &&
          _entriesEquality.equals(_entries, other._entries));

  @override
  int get hashCode => _entriesEquality.hash(_entries);

  static void _validateKey(String key) {
    if (key.isEmpty) {
      throw ArgumentError.value(
        key,
        'key',
        'NatsHeaders key must be non-empty',
      );
    }

    for (var i = 0; i < key.length; i++) {
      if (!_isTchar(key.codeUnitAt(i))) {
        throw ArgumentError.value(
          key,
          'key',
          'NatsHeaders key contains an illegal character at index $i; '
              'keys must consist of RFC 7230 tchar bytes only',
        );
      }
    }
  }

  static void _validateValue(String key, String value) {
    for (var i = 0; i < value.length; i++) {
      final unit = value.codeUnitAt(i);
      if (unit == 0x0D || unit == 0x0A || unit == 0x00) {
        throw ArgumentError.value(
          value,
          'headers["$key"]',
          'NatsHeaders value must not contain CR, LF, or NUL',
        );
      }
    }
  }

  static bool _isTchar(int unit) {
    if (unit >= 0x30 && unit <= 0x39) return true; // 0-9
    if (unit >= 0x41 && unit <= 0x5A) return true; // A-Z
    if (unit >= 0x61 && unit <= 0x7A) return true; // a-z

    switch (unit) {
      case 0x21: // !
      case 0x23: // #
      case 0x24: // $
      case 0x25: // %
      case 0x26: // &
      case 0x27: // '
      case 0x2A: // *
      case 0x2B: // +
      case 0x2D: // -
      case 0x2E: // .
      case 0x5E: // ^
      case 0x5F: // _
      case 0x60: // `
      case 0x7C: // |
      case 0x7E: // ~
        return true;
    }
    return false;
  }
}
