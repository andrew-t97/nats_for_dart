/// Integration test for update_libressl.sh and update_nats.sh.
///
/// Runs a downgrade/upgrade round-trip to verify both scripts produce a valid
/// vendored tree. Phase 1 downgrades and validates structure only (compilation
/// skipped — versions may not be mutually compatible). Phase 2 upgrades back,
/// restores LibreSSL compatibility patches, regenerates FFI bindings, and runs
/// the full test suite.
///
/// Run directly:   dart test test/update_scripts_test.dart
/// Via justfile:   just test-update-scripts
@Timeout(Duration(minutes: 15))
library;

import 'dart:io';

import 'package:test/test.dart';

void main() {
  final packageRoot = Directory.current.path;
  final libresslCurr = _readVersion(
    '$packageRoot/third_party/libressl/VERSION',
  );
  final natsCurr = _normaliseNatsVersion(
    _readVersion('$packageRoot/third_party/nats_c/VERSION'),
  );
  final libresslPrev = _prevMinor(libresslCurr);
  final natsPrev = _prevMinor(natsCurr);

  // Restore patches before Phase 1 in case a previous run left them unpatched.
  setUpAll(() => _gitRestorePatches(packageRoot));

  // Always visible if the run fails or is interrupted.
  tearDownAll(() => _printRestorationHint(packageRoot, libresslCurr, natsCurr));

  // ---------------------------------------------------------------------------
  // Phase 1 — Downgrade
  // ---------------------------------------------------------------------------
  group('Phase 1 — Downgrade', () {
    late Directory tmpNatsPrev;
    setUpAll(
      () async =>
          tmpNatsPrev = await Directory.systemTemp.createTemp('nats_prev_'),
    );
    tearDownAll(() => tmpNatsPrev.delete(recursive: true));

    group('libressl downgrade to $libresslPrev', () {
      setUpAll(
        () => _runScript(packageRoot, 'scripts/update_libressl.sh', [
          libresslPrev,
        ]),
      );

      test('VERSION file matches $libresslPrev', () {
        final versionFile = File('$packageRoot/third_party/libressl/VERSION');
        expect(
          versionFile.existsSync(),
          isTrue,
          reason: 'VERSION file missing',
        );
        expect(versionFile.readAsStringSync().trim(), equals(libresslPrev));
      });

      test('required directories present (crypto, ssl, include)', () {
        final vendorDir = '$packageRoot/third_party/libressl';
        for (final dir in ['crypto', 'ssl', 'include']) {
          expect(
            Directory('$vendorDir/$dir').existsSync(),
            isTrue,
            reason: 'Missing required directory: $dir',
          );
        }
      });

      test('sources.txt has >= 400 entries', () {
        final sourcesFile = File(
          '$packageRoot/third_party/libressl/sources.txt',
        );
        expect(sourcesFile.existsSync(), isTrue, reason: 'sources.txt missing');
        final lines = sourcesFile
            .readAsLinesSync()
            .where((line) => line.isNotEmpty)
            .toList();
        expect(
          lines.length,
          greaterThanOrEqualTo(400),
          reason: 'sources.txt has only ${lines.length} entries',
        );
      });

      test('sources.txt has no duplicate lines', () {
        final sourcesFile = File(
          '$packageRoot/third_party/libressl/sources.txt',
        );
        final lines = sourcesFile
            .readAsLinesSync()
            .where((line) => line.isNotEmpty)
            .toList();
        final seen = <String>{};
        final duplicates = <String>{};
        for (final line in lines) {
          if (!seen.add(line)) duplicates.add(line);
        }
        expect(
          duplicates,
          isEmpty,
          reason: 'Duplicate lines in sources.txt: $duplicates',
        );
      });

      test('all sources.txt paths resolve to real files', () {
        final sourcesFile = File(
          '$packageRoot/third_party/libressl/sources.txt',
        );
        final lines = sourcesFile
            .readAsLinesSync()
            .where((line) => line.isNotEmpty)
            .toList();
        final missing = lines
            .where((path) => !File('$packageRoot/$path').existsSync())
            .take(10)
            .toList();
        expect(
          missing,
          isEmpty,
          reason: 'Missing files referenced in sources.txt: $missing',
        );
      });

      test('no ssl/ entry shares a basename with a crypto/ entry', () {
        final sourcesFile = File(
          '$packageRoot/third_party/libressl/sources.txt',
        );
        final lines = sourcesFile
            .readAsLinesSync()
            .where((line) => line.isNotEmpty)
            .toList();
        final cryptoBasenames = lines
            .where((path) => path.contains('/crypto/'))
            .map((path) => path.split('/').last)
            .toSet();
        final sslConflicts = lines
            .where((path) => path.contains('/ssl/'))
            .map((path) => path.split('/').last)
            .where(cryptoBasenames.contains)
            .toList();
        expect(
          sslConflicts,
          isEmpty,
          reason:
              'ssl/ entries share basenames with crypto/ entries: $sslConflicts',
        );
      });

      test('LICENSE present', () {
        expect(
          File('$packageRoot/third_party/libressl/LICENSE').existsSync(),
          isTrue,
          reason: 'LICENSE missing',
        );
      });
    });

    group('nats.c downgrade to $natsPrev', () {
      setUpAll(() async {
        await _gitClone(natsPrev, tmpNatsPrev.path);
        await _runScript(packageRoot, 'scripts/update_nats.sh', [
          tmpNatsPrev.path,
        ]);
      });

      test('VERSION file matches $natsPrev', () {
        final versionFile = File('$packageRoot/third_party/nats_c/VERSION');
        expect(
          versionFile.existsSync(),
          isTrue,
          reason: 'VERSION file missing',
        );
        final actual = _normaliseNatsVersion(
          versionFile.readAsStringSync().trim(),
        );
        expect(actual, equals(natsPrev));
      });

      test(
        'required directories present (src, src/glib, src/unix, src/include)',
        () {
          final vendorDir = '$packageRoot/third_party/nats_c';
          for (final dir in ['src', 'src/glib', 'src/unix', 'src/include']) {
            expect(
              Directory('$vendorDir/$dir').existsSync(),
              isTrue,
              reason: 'Missing required directory: $dir',
            );
          }
        },
      );

      test('critical source files present', () {
        final vendorDir = '$packageRoot/third_party/nats_c';
        const criticalFiles = [
          'src/conn.c',
          'src/nats.c',
          'src/js.c',
          'src/kv.c',
          'src/opts.c',
          'src/pub.c',
          'src/sub.c',
          'src/msg.c',
          'src/glib/glib.c',
          'src/glib/glib_ssl.c',
          'src/unix/sock.c',
          'src/unix/thread.c',
        ];
        for (final criticalFile in criticalFiles) {
          expect(
            File('$vendorDir/$criticalFile').existsSync(),
            isTrue,
            reason: 'Missing critical source file: $criticalFile',
          );
        }
      });

      test('.c file count is between 35 and 55', () async {
        final srcDir = Directory('$packageRoot/third_party/nats_c/src');
        final cFiles = await srcDir
            .list(recursive: true)
            .where((entity) => entity is File && entity.path.endsWith('.c'))
            .toList();
        expect(
          cFiles.length,
          greaterThanOrEqualTo(35),
          reason: 'Too few .c files: ${cFiles.length}',
        );
        expect(
          cFiles.length,
          lessThanOrEqualTo(55),
          reason: 'Too many .c files: ${cFiles.length}',
        );
      });

      test('LICENSE present', () {
        expect(
          File('$packageRoot/third_party/nats_c/LICENSE').existsSync(),
          isTrue,
          reason: 'LICENSE missing',
        );
      });
    });
  });

  // ---------------------------------------------------------------------------
  // Phase 2 — Upgrade
  // ---------------------------------------------------------------------------
  group('Phase 2 — Upgrade', () {
    late Directory tmpNatsCurr;
    setUpAll(
      () async =>
          tmpNatsCurr = await Directory.systemTemp.createTemp('nats_curr_'),
    );
    tearDownAll(() => tmpNatsCurr.delete(recursive: true));

    group('libressl upgrade to $libresslCurr', () {
      setUpAll(
        () => _runScript(packageRoot, 'scripts/update_libressl.sh', [
          libresslCurr,
        ]),
      );

      test('VERSION file matches $libresslCurr', () {
        final versionFile = File('$packageRoot/third_party/libressl/VERSION');
        expect(
          versionFile.existsSync(),
          isTrue,
          reason: 'VERSION file missing',
        );
        expect(versionFile.readAsStringSync().trim(), equals(libresslCurr));
      });

      test('required directories present (crypto, ssl, include)', () {
        final vendorDir = '$packageRoot/third_party/libressl';
        for (final dir in ['crypto', 'ssl', 'include']) {
          expect(
            Directory('$vendorDir/$dir').existsSync(),
            isTrue,
            reason: 'Missing required directory: $dir',
          );
        }
      });

      test('sources.txt has >= 400 entries', () {
        final sourcesFile = File(
          '$packageRoot/third_party/libressl/sources.txt',
        );
        expect(sourcesFile.existsSync(), isTrue, reason: 'sources.txt missing');
        final lines = sourcesFile
            .readAsLinesSync()
            .where((line) => line.isNotEmpty)
            .toList();
        expect(
          lines.length,
          greaterThanOrEqualTo(400),
          reason: 'sources.txt has only ${lines.length} entries',
        );
      });

      test('sources.txt has no duplicate lines', () {
        final sourcesFile = File(
          '$packageRoot/third_party/libressl/sources.txt',
        );
        final lines = sourcesFile
            .readAsLinesSync()
            .where((line) => line.isNotEmpty)
            .toList();
        final seen = <String>{};
        final duplicates = <String>{};
        for (final line in lines) {
          if (!seen.add(line)) duplicates.add(line);
        }
        expect(
          duplicates,
          isEmpty,
          reason: 'Duplicate lines in sources.txt: $duplicates',
        );
      });

      test('all sources.txt paths resolve to real files', () {
        final sourcesFile = File(
          '$packageRoot/third_party/libressl/sources.txt',
        );
        final lines = sourcesFile
            .readAsLinesSync()
            .where((line) => line.isNotEmpty)
            .toList();
        final missing = lines
            .where((path) => !File('$packageRoot/$path').existsSync())
            .take(10)
            .toList();
        expect(
          missing,
          isEmpty,
          reason: 'Missing files referenced in sources.txt: $missing',
        );
      });

      test('no ssl/ entry shares a basename with a crypto/ entry', () {
        final sourcesFile = File(
          '$packageRoot/third_party/libressl/sources.txt',
        );
        final lines = sourcesFile
            .readAsLinesSync()
            .where((line) => line.isNotEmpty)
            .toList();
        final cryptoBasenames = lines
            .where((path) => path.contains('/crypto/'))
            .map((path) => path.split('/').last)
            .toSet();
        final sslConflicts = lines
            .where((path) => path.contains('/ssl/'))
            .map((path) => path.split('/').last)
            .where(cryptoBasenames.contains)
            .toList();
        expect(
          sslConflicts,
          isEmpty,
          reason:
              'ssl/ entries share basenames with crypto/ entries: $sslConflicts',
        );
      });

      test('LICENSE present', () {
        expect(
          File('$packageRoot/third_party/libressl/LICENSE').existsSync(),
          isTrue,
          reason: 'LICENSE missing',
        );
      });
    });

    group('nats.c upgrade to $natsCurr', () {
      setUpAll(() async {
        await _gitClone(natsCurr, tmpNatsCurr.path);
        await _runScript(packageRoot, 'scripts/update_nats.sh', [
          tmpNatsCurr.path,
        ]);
      });

      test('VERSION file matches $natsCurr', () {
        final versionFile = File('$packageRoot/third_party/nats_c/VERSION');
        expect(
          versionFile.existsSync(),
          isTrue,
          reason: 'VERSION file missing',
        );
        final actual = _normaliseNatsVersion(
          versionFile.readAsStringSync().trim(),
        );
        expect(actual, equals(natsCurr));
      });

      test(
        'required directories present (src, src/glib, src/unix, src/include)',
        () {
          final vendorDir = '$packageRoot/third_party/nats_c';
          for (final dir in ['src', 'src/glib', 'src/unix', 'src/include']) {
            expect(
              Directory('$vendorDir/$dir').existsSync(),
              isTrue,
              reason: 'Missing required directory: $dir',
            );
          }
        },
      );

      test('critical source files present', () {
        final vendorDir = '$packageRoot/third_party/nats_c';
        const criticalFiles = [
          'src/conn.c',
          'src/nats.c',
          'src/js.c',
          'src/kv.c',
          'src/opts.c',
          'src/pub.c',
          'src/sub.c',
          'src/msg.c',
          'src/glib/glib.c',
          'src/glib/glib_ssl.c',
          'src/unix/sock.c',
          'src/unix/thread.c',
        ];
        for (final criticalFile in criticalFiles) {
          expect(
            File('$vendorDir/$criticalFile').existsSync(),
            isTrue,
            reason: 'Missing critical source file: $criticalFile',
          );
        }
      });

      test('.c file count is between 35 and 55', () async {
        final srcDir = Directory('$packageRoot/third_party/nats_c/src');
        final cFiles = await srcDir
            .list(recursive: true)
            .where((entity) => entity is File && entity.path.endsWith('.c'))
            .toList();
        expect(
          cFiles.length,
          greaterThanOrEqualTo(35),
          reason: 'Too few .c files: ${cFiles.length}',
        );
        expect(
          cFiles.length,
          lessThanOrEqualTo(55),
          reason: 'Too many .c files: ${cFiles.length}',
        );
      });

      test('LICENSE present', () {
        expect(
          File('$packageRoot/third_party/nats_c/LICENSE').existsSync(),
          isTrue,
          reason: 'LICENSE missing',
        );
      });
    });

    group('post-upgrade integration', () {
      test('libressl compatibility patches restored', () async {
        await _gitRestorePatches(packageRoot);
      });

      test('FFI bindings regenerated', () async {
        await _runScript(packageRoot, 'dart', [
          'run',
          'ffigen',
          '--config',
          'ffigen.yaml',
        ]);
      });

      test('dart test test/test_all.dart passes', () async {
        // inheritStdio streams nested test output to the terminal in real time
        // rather than buffering it silently for minutes.
        final process = await Process.start(
          'dart',
          ['test', 'test/test_all.dart'],
          workingDirectory: packageRoot,
          mode: ProcessStartMode.inheritStdio,
        );
        expect(await process.exitCode, 0);
      });
    });
  });
}

// -----------------------------------------------------------------------------
// Private helpers
// -----------------------------------------------------------------------------

String _readVersion(String path) => File(path).readAsStringSync().trim();

String _normaliseNatsVersion(String version) =>
    version.startsWith('v') ? version : 'v$version';

/// Returns the immediately preceding minor release (patch reset to 0).
/// Preserves a leading 'v' prefix: "v3.12.0" → "v3.11.0", "4.1.0" → "4.0.0".
String _prevMinor(String version) {
  final bare = version.startsWith('v') ? version.substring(1) : version;
  final parts = bare.split('.');
  final minor = int.parse(parts[1]);
  if (minor == 0) {
    throw ArgumentError(
      'Cannot compute previous minor for $version: minor is already 0',
    );
  }
  final prevBare = '${parts[0]}.${minor - 1}.0';
  return version.startsWith('v') ? 'v$prevBare' : prevBare;
}

/// Runs a short-lived script and captures its output.
/// Output is only shown when the test that triggered this call fails.
Future<void> _runScript(
  String packageRoot,
  String executable,
  List<String> args,
) async {
  final result = await Process.run(
    executable,
    args,
    workingDirectory: packageRoot,
  );
  printOnFailure(result.stdout.toString());
  printOnFailure(result.stderr.toString());
  expect(
    result.exitCode,
    0,
    reason: '$executable ${args.join(' ')} exited with ${result.exitCode}',
  );
}

/// Clones a specific nats.c tag into [targetDir] with real-time terminal output.
Future<void> _gitClone(String tag, String targetDir) async {
  final process = await Process.start('git', [
    'clone',
    '--depth',
    '1',
    '--branch',
    tag,
    'https://github.com/nats-io/nats.c',
    targetDir,
  ], mode: ProcessStartMode.inheritStdio);
  expect(await process.exitCode, 0, reason: 'git clone for $tag failed');
}

/// Restores the LibreSSL compatibility patches from git HEAD.
/// Must be called after any update_nats.sh run (which overwrites these files
/// with unpatched upstream sources) and before running dart test.
Future<void> _gitRestorePatches(String packageRoot) async {
  final result = await Process.run('git', [
    'checkout',
    'HEAD',
    '--',
    'third_party/nats_c/src/opts.c',
    'third_party/nats_c/src/conn.c',
  ], workingDirectory: packageRoot);
  printOnFailure(result.stdout.toString());
  printOnFailure(result.stderr.toString());
  expect(
    result.exitCode,
    0,
    reason: 'Failed to restore LibreSSL compatibility patches',
  );
}

/// Prints manual restoration commands — visible whenever the run fails or
/// is interrupted, because it runs in tearDownAll.
void _printRestorationHint(
  String packageRoot,
  String libresslCurr,
  String natsCurr,
) {
  print('''

If this run failed, restore the working tree manually:
  ./scripts/update_libressl.sh $libresslCurr
  TMP=\$(mktemp -d) && git clone --depth 1 --branch $natsCurr \\
    https://github.com/nats-io/nats.c \$TMP && \\
    ./scripts/update_nats.sh \$TMP && rm -rf \$TMP
  git checkout HEAD -- third_party/nats_c/src/opts.c third_party/nats_c/src/conn.c
  dart run ffigen --config ffigen.yaml
''');
}
