import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

void main(List<String> args) async {
  await build(args, _build);
}

Future<void> _build(BuildInput input, BuildOutputBuilder output) async {
  if (!input.config.buildCodeAssets) return;

  // Guard: ensure vendored source is present.
  final natsHeader = File.fromUri(
    input.packageRoot.resolve('third_party/nats_c/src/nats.h'),
  );
  if (!natsHeader.existsSync()) {
    throw StateError(
      'Vendored nats.c source not found at third_party/nats_c/.\n'
      'The third_party/nats_c/ directory should contain the nats.c source files.',
    );
  }

  final libresslSourcesFile = File.fromUri(
    input.packageRoot.resolve('third_party/libressl/sources.txt'),
  );
  if (!libresslSourcesFile.existsSync()) {
    throw StateError(
      'Vendored LibreSSL source not found at third_party/libressl/.\n'
      'Run scripts/update_libressl.sh to populate third_party/libressl/.',
    );
  }

  final targetOS = input.config.code.targetOS;

  final cmake = await _findCmake();
  if (cmake == null) {
    throw StateError(
      'cmake not found. Install cmake 3.28 or later:\n'
      '  macOS:   brew install cmake\n'
      '  Linux:   apt install cmake\n'
      '  Windows: https://cmake.org/download/ or update Visual Studio 2022',
    );
  }

  final cmakeBuildDir = Directory.fromUri(
    input.outputDirectory.resolve('cmake_build/'),
  );
  await cmakeBuildDir.create(recursive: true);

  // Configure — architecture is auto-detected by CMakeLists.txt via
  // CMAKE_SYSTEM_PROCESSOR; no -DNATS_TARGET_ARCH flag is needed.
  await _runProcess(cmake, [
    '-S',
    input.packageRoot.toFilePath(),
    '-B',
    cmakeBuildDir.path,
    '-DCMAKE_BUILD_TYPE=Release',
  ]);

  // Build — --parallel lets cmake use all available cores.
  await _runProcess(cmake, [
    '--build',
    cmakeBuildDir.path,
    '--config',
    'Release',
    '--parallel',
  ]);

  final libName = switch (targetOS) {
    OS.windows => 'nats.dll',
    OS.macOS => 'libnats.dylib',
    _ => 'libnats.so',
  };
  final libFile = Uri.file('${cmakeBuildDir.path}/lib/$libName');

  output.assets.code.add(
    CodeAsset(
      package: input.packageName,
      name: 'src/nats_bindings.g.dart',
      linkMode: DynamicLoadingBundled(),
      file: libFile,
    ),
  );

  output.dependencies.add(input.packageRoot.resolve('CMakeLists.txt'));
  output.dependencies.add(
    input.packageRoot.resolve('third_party/libressl/sources.txt'),
  );
  // Track the NATS C source directory so that adding/removing files triggers a rebuild.
  output.dependencies.add(input.packageRoot.resolve('third_party/nats_c/src/'));
}

Future<String?> _findCmake() async {
  // Try the name directly first — works if cmake is on PATH on any platform.
  final probe = await Process.run('cmake', ['--version']);
  if (probe.exitCode == 0) return 'cmake';
  // macOS fallbacks: Homebrew (Apple Silicon and Intel).
  for (final path in ['/opt/homebrew/bin/cmake', '/usr/local/bin/cmake']) {
    if (File(path).existsSync()) return path;
  }
  // Windows fallback: cmake bundled with Visual Studio 2022.
  final vsDir = Platform.environment['VSINSTALLDIR'];
  if (vsDir != null) {
    final vsCmake =
        '$vsDir\\Common7\\IDE\\CommonExtensions\\'
        'Microsoft\\CMake\\CMake\\bin\\cmake.exe';
    if (File(vsCmake).existsSync()) return vsCmake;
  }
  return null;
}

Future<void> _runProcess(String executable, List<String> args) async {
  final result = await Process.run(executable, args);
  if (result.exitCode != 0) {
    throw StateError(
      '`$executable ${args.join(' ')}` failed (exit ${result.exitCode}).\n'
      '${result.stderr}',
    );
  }
}
