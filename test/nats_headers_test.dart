/// Unit tests for the immutable [NatsHeaders] value class.
library;

import 'package:nats_for_dart/nats_for_dart.dart';
import 'package:test/test.dart';

void main() {
  group('NatsHeaders.empty', () {
    test('isEmpty is true', () {
      const headers = NatsHeaders.empty();
      expect(headers.isEmpty, isTrue);
      expect(headers.isNotEmpty, isFalse);
    });

    test('two empty instances are == and have equal hashCode', () {
      const a = NatsHeaders.empty();
      const b = NatsHeaders.empty();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('keys is empty', () {
      const headers = NatsHeaders.empty();
      expect(headers.keys, isEmpty);
    });

    test('firstOrNull returns null for any key', () {
      const headers = NatsHeaders.empty();
      expect(headers.firstOrNull('X-Anything'), isNull);
    });

    test('getAll returns empty list for any key', () {
      const headers = NatsHeaders.empty();
      expect(headers.getAll('X-Anything'), isEmpty);
    });

    test('containsKey returns false for any key', () {
      const headers = NatsHeaders.empty();
      expect(headers.containsKey('X-Anything'), isFalse);
    });
  });

  group('NatsHeaders.from', () {
    test('mixed-shape literal round-trips via firstOrNull/getAll/keys', () {
      final headers = NatsHeaders.from({
        'X-Trace-Id': 'abc-123',
        'X-Tag': ['urgent', 'customer-facing'],
        'X-Correlation-Id': 'xyz-789',
      });
      expect(headers.firstOrNull('X-Trace-Id'), equals('abc-123'));
      expect(headers.getAll('X-Trace-Id'), equals(['abc-123']));
      expect(headers.getAll('X-Tag'), equals(['urgent', 'customer-facing']));
      expect(headers.firstOrNull('X-Tag'), equals('urgent'));
      expect(headers.firstOrNull('X-Correlation-Id'), equals('xyz-789'));
      expect(
        headers.keys,
        containsAllInOrder(<String>['X-Trace-Id', 'X-Tag', 'X-Correlation-Id']),
      );
    });

    test('empty map is value-equal to NatsHeaders.empty()', () {
      final headers = NatsHeaders.from(const <String, Object>{});
      expect(headers, equals(const NatsHeaders.empty()));
      expect(headers.hashCode, equals(const NatsHeaders.empty().hashCode));
      expect(headers.isEmpty, isTrue);
    });

    test('Map<String, String> passes without casts (covariance)', () {
      const Map<String, String> input = {'X-Trace-Id': 'abc'};
      final headers = NatsHeaders.from(input);
      expect(headers.firstOrNull('X-Trace-Id'), equals('abc'));
    });

    test('Map<String, List<String>> passes without casts (covariance)', () {
      const Map<String, List<String>> input = {
        'X-Tag': ['a', 'b'],
      };
      final headers = NatsHeaders.from(input);
      expect(headers.getAll('X-Tag'), equals(['a', 'b']));
    });

    test('throws ArgumentError when a value is int — names key and type', () {
      expect(
        () => NatsHeaders.from(<String, Object>{'X-Retry-Count': 3}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'message',
            allOf(contains('X-Retry-Count'), contains('int')),
          ),
        ),
      );
    });

    test('throws ArgumentError when a value is List<int> — names key', () {
      expect(
        () => NatsHeaders.from(<String, Object>{
          'X-Mixed': <int>[1, 2],
        }),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'message',
            contains('X-Mixed'),
          ),
        ),
      );
    });
  });

  group('NatsHeaders.fromEntries', () {
    test('preserves duplicate-key insertion order', () {
      final headers = NatsHeaders.fromEntries(const [
        MapEntry('X-Tag', 'first'),
        MapEntry('X-Tag', 'second'),
        MapEntry('X-Tag', 'third'),
      ]);
      expect(headers.getAll('X-Tag'), equals(['first', 'second', 'third']));
      expect(headers.firstOrNull('X-Tag'), equals('first'));
    });

    test('empty entries iterable is value-equal to empty', () {
      final headers = NatsHeaders.fromEntries(const []);
      expect(headers, equals(const NatsHeaders.empty()));
    });
  });

  group('NatsHeaders key validation', () {
    test('rejects empty key', () {
      expect(
        () => NatsHeaders.from(const {'': 'v'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects whitespace-only key', () {
      expect(
        () => NatsHeaders.from(const {' ': 'v'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects key containing CR', () {
      expect(
        () => NatsHeaders.from(const {'X\rBad': 'v'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects key containing LF', () {
      expect(
        () => NatsHeaders.from(const {'X\nBad': 'v'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects key containing NUL', () {
      expect(
        () => NatsHeaders.from(const {'X\u0000Bad': 'v'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects key containing colon', () {
      expect(
        () => NatsHeaders.from(const {'X:Bad': 'v'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects key containing space', () {
      expect(
        () => NatsHeaders.from(const {'X Bad': 'v'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('accepts tchar-only key with valid punctuation', () {
      final headers = NatsHeaders.from(const {"!#\$%&'*+-.^_`|~0aZ": 'v'});
      expect(headers.firstOrNull("!#\$%&'*+-.^_`|~0aZ"), equals('v'));
    });
  });

  group('NatsHeaders value validation', () {
    test('rejects value containing CR', () {
      expect(
        () => NatsHeaders.from(const {'X-Tag': 'bad\rvalue'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects value containing LF', () {
      expect(
        () => NatsHeaders.from(const {'X-Tag': 'bad\nvalue'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects value containing NUL', () {
      expect(
        () => NatsHeaders.from(const {'X-Tag': 'bad\u0000value'}),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects multi-value list with one bad value', () {
      expect(
        () => NatsHeaders.from(const {
          'X-Tag': ['ok', 'bad\nvalue'],
        }),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('accepts empty-string value', () {
      final headers = NatsHeaders.from(const {'X-Tag': ''});
      expect(headers.firstOrNull('X-Tag'), equals(''));
    });

    test('accepts UTF-8 multi-byte characters', () {
      final headers = NatsHeaders.from(const {'X-Tag': 'café-✓'});
      expect(headers.firstOrNull('X-Tag'), equals('café-✓'));
    });
  });

  group('NatsHeaders.toMap', () {
    test('returns an UnmodifiableMapView — outer mutation throws', () {
      final headers = NatsHeaders.from(const {'X-Tag': 'v'});
      final map = headers.toMap();
      expect(() => map['X-New'] = ['x'], throwsUnsupportedError);
      expect(() => map.remove('X-Tag'), throwsUnsupportedError);
      expect(() => map.clear(), throwsUnsupportedError);
    });

    test('per-key list is unmodifiable — inner mutation throws', () {
      final headers = NatsHeaders.from(const {
        'X-Tag': ['a', 'b'],
      });
      final values = headers.toMap()['X-Tag']!;
      expect(() => values.add('c'), throwsUnsupportedError);
      expect(() => values[0] = 'z', throwsUnsupportedError);
    });

    test('reflects the headers content', () {
      final headers = NatsHeaders.from(const {
        'X-Trace-Id': 'abc',
        'X-Tag': ['a', 'b'],
      });
      final map = headers.toMap();
      expect(map['X-Trace-Id'], equals(['abc']));
      expect(map['X-Tag'], equals(['a', 'b']));
    });
  });

  group('NatsHeaders equality', () {
    test('same content with different key insertion orders compares equal', () {
      final a = NatsHeaders.from(const {'X-A': '1', 'X-B': '2'});
      final b = NatsHeaders.from(const {'X-B': '2', 'X-A': '1'});
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('same key but different per-key Add order compares NOT equal', () {
      final a = NatsHeaders.fromEntries(const [
        MapEntry('X-Tag', 'first'),
        MapEntry('X-Tag', 'second'),
      ]);
      final b = NatsHeaders.fromEntries(const [
        MapEntry('X-Tag', 'second'),
        MapEntry('X-Tag', 'first'),
      ]);
      expect(a, isNot(equals(b)));
    });

    test('per-key Add order also distinguishes hashCode (regression pin)', () {
      // Hash collisions are legal; this pins the contract that values are
      // hashed in order, so a value-order-insensitive hash refactor cannot
      // land silently.
      final a = NatsHeaders.fromEntries(const [
        MapEntry('X-Tag', 'first'),
        MapEntry('X-Tag', 'second'),
      ]);
      final b = NatsHeaders.fromEntries(const [
        MapEntry('X-Tag', 'second'),
        MapEntry('X-Tag', 'first'),
      ]);
      expect(a.hashCode, isNot(equals(b.hashCode)));
    });

    test('different content compares not equal', () {
      final a = NatsHeaders.from(const {'X-A': '1'});
      final b = NatsHeaders.from(const {'X-A': '2'});
      expect(a, isNot(equals(b)));
    });

    test('different key sets compare not equal', () {
      final a = NatsHeaders.from(const {'X-A': '1'});
      final b = NatsHeaders.from(const {'X-B': '1'});
      expect(a, isNot(equals(b)));
    });

    test('non-NatsHeaders objects are never equal', () {
      final a = NatsHeaders.from(const {'X-A': '1'});
      // ignore: unrelated_type_equality_checks
      expect(a == 'X-A: 1', isFalse);
      // ignore: unrelated_type_equality_checks
      expect(a == const <String, String>{'X-A': '1'}, isFalse);
    });
  });
}
