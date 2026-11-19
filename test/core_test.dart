import 'package:aerostream/core/errors/plugin_error.dart';
import 'package:aerostream/core/json/json_read.dart';
import 'package:aerostream/core/result.dart';
import 'package:aerostream/core/utils/version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Result', () {
    test('carries a success value', () {
      const Result<int> result = Result<int>.ok(42);
      expect(result.isOk, isTrue);
      expect(result.valueOrNull, 42);
      expect(result.errorOrNull, isNull);
      expect(result.map((value) => value * 2).valueOrNull, 84);
    });

    test('carries a typed failure', () {
      const Result<int> result = Result<int>.err(
        PluginNetworkError('boom', statusCode: 503),
      );
      expect(result.isErr, isTrue);
      expect(result.valueOrNull, isNull);
      expect(result.errorOrNull, isA<PluginNetworkError>());
      expect(result.getOrElse((_) => -1), -1);
    });

    test('flatMap short-circuits on failure', () {
      const Result<int> failed = Result<int>.err(PluginParseError('nope'));
      var called = false;
      final chained = failed.flatMap((value) {
        called = true;
        return Result<String>.ok('$value');
      });
      expect(called, isFalse);
      expect(chained.isErr, isTrue);
    });

    test('value equality keeps tests readable', () {
      expect(const Ok<int>(1), const Ok<int>(1));
      expect(const Ok<int>(1) == const Ok<int>(2), isFalse);
      expect(const Err<int>(PluginParseError('a')), isNot(const Ok<int>(0)));
    });
  });

  group('PluginError', () {
    test('every error kind is addressable and none is retryable by accident', () {
      const errors = <PluginError>[
        PluginTimeoutError('t'),
        PluginParseError('p'),
        PluginNetworkError('n'),
        PluginSandboxError('s'),
        PluginUnsupportedError('u'),
        PluginCrashError('c'),
        PluginNotFoundError('nf'),
        PluginPermissionError('perm'),
        PluginCancelledError('cancel'),
        PluginUnknownError('unknown'),
      ];

      final kinds = errors.map((error) => error.kind).toSet();
      expect(kinds, hasLength(errors.length));

      final retryable = errors.where((error) => error.isRetryable).toSet();
      expect(retryable, {
        errors[0], // timeout
        errors[2], // network
        errors[5], // crash
      });

      for (final error in errors) {
        expect(error.userMessage, isNotEmpty);
      }
    });

    test('copyWithPlugin attaches the plugin id without losing the type', () {
      const error = PluginTimeoutError('slow', timeout: Duration(seconds: 5));
      final scoped = error.copyWithPlugin('dev.example.plugin');
      expect(scoped, isA<PluginTimeoutError>());
      expect(scoped.pluginId, 'dev.example.plugin');
      expect((scoped as PluginTimeoutError).timeout, const Duration(seconds: 5));
      expect(scoped.toString(), contains('dev.example.plugin'));
    });
  });

  group('PluginVersion', () {
    test('reads integers, doubles and strings', () {
      expect(PluginVersion.parse(25).parts, [25]);
      expect(PluginVersion.parse('1.2.3').parts, [1, 2, 3]);
      expect(PluginVersion.parse('v1.2.3').parts, [1, 2, 3]);
      expect(PluginVersion.parse('1.2.3-beta4').parts, [1, 2, 3, 4]);
      expect(PluginVersion.parse(null).isNone, isTrue);
      expect(PluginVersion.parse('').isNone, isTrue);
    });

    test('compares numerically, not lexically', () {
      expect(
        PluginVersion.parse(10) > PluginVersion.parse(9),
        isTrue,
        reason: '10 must beat 9, which string comparison gets wrong',
      );
      expect(
        PluginVersion.parse('1.10.0') > PluginVersion.parse('1.9.9'),
        isTrue,
      );
      expect(
        PluginVersion.parse('1.2') == PluginVersion.parse('1.2.0'),
        isTrue,
      );
    });

    test('isUpdate answers the repository question', () {
      expect(isUpdate(installed: 3, candidate: 4), isTrue);
      expect(isUpdate(installed: 4, candidate: 4), isFalse);
      expect(isUpdate(installed: 5, candidate: 4), isFalse);
      expect(isUpdate(installed: null, candidate: 1), isTrue);
    });
  });

  group('json_read', () {
    test('never throws on hostile input', () {
      final hostile = <Object?>[
        null,
        42,
        4.5,
        true,
        'text',
        <Object?>[1, 2],
        <String, Object?>{'a': 1},
        Object(),
      ];
      for (final value in hostile) {
        expect(() => readString(value), returnsNormally);
        expect(() => readInt(value), returnsNormally);
        expect(() => readDouble(value), returnsNormally);
        expect(() => readBool(value), returnsNormally);
        expect(() => readStringList(value), returnsNormally);
        expect(() => readStringMap(value), returnsNormally);
        expect(() => readMap(value), returnsNormally);
        expect(() => readMapList(value), returnsNormally);
        expect(() => readDate(value), returnsNormally);
      }
    });

    test('coerces where unambiguous and drops the rest', () {
      expect(readString('  hi  '), 'hi');
      expect(readString('   '), isNull);
      expect(readInt('12'), 12);
      expect(readInt(12.7), 13);
      expect(readDouble('1.5'), 1.5);
      expect(readBool('YES'), isTrue);
      expect(readBool('off', fallback: true), isFalse);
      expect(readStringList(<Object?>['a', 2, null, 'b']), ['a', '2', 'b']);
      expect(readStringMap(<Object?, Object?>{'a': 'b', 1: null}), {'a': 'b'});
      expect(readMapList(<Object?>[{'a': 1}, 'x']), hasLength(1));
      expect(readDate('2024-04-01'), DateTime(2024, 4, 1));
      expect(readDate('not a date'), isNull);
    });
  });
}
