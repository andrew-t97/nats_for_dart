import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

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

  // Discover OpenSSL via pkg-config.
  final opensslCflags = await _pkgConfig('openssl', '--cflags');
  final opensslLibDir = await _pkgConfig('openssl', '--variable=libdir');

  if (opensslCflags == null || opensslLibDir == null) {
    throw StateError(
      'pkg-config could not find openssl. '
      'Install OpenSSL development files:\n'
      '  macOS:  brew install openssl@3 pkg-config\n'
      '  Linux:  apt install libssl-dev pkg-config',
    );
  }

  final opensslIncludes =
      RegExp(r'-I(\S+)')
          .allMatches(opensslCflags)
          .map((m) => m.group(1)!)
          .toList();

  final targetOS = input.config.code.targetOS;

  final cbuilder = CBuilder.library(
    name: 'nats',
    assetName: 'src/nats_bindings.g.dart',
    std: 'c99',
    sources: _sources,
    includes: [
      'third_party/nats_c/src/',
      'third_party/nats_c/src/include/',
      ...opensslIncludes,
    ],
    defines: {
      '_REENTRANT': null,
      'NATS_HAS_TLS': null,
      'NATS_FORCE_HOST_VERIFICATION': null,
      if (targetOS == OS.macOS) 'DARWIN': null,
      if (targetOS == OS.linux) 'LINUX': null,
      if (targetOS == OS.linux) '_GNU_SOURCE': null,
    },
    libraries: [
      'ssl',
      'crypto',
      if (targetOS == OS.linux) 'pthread',
    ],
    libraryDirectories: [opensslLibDir],
  );

  await cbuilder.run(
    input: input,
    output: output,
    logger:
        Logger('')
          ..level = Level.ALL
          ..onRecord.listen((record) => print(record.message)),
  );
}

/// Shell out to pkg-config, injecting Homebrew paths on macOS since the
/// build-hook sandbox strips PKG_CONFIG_PATH from the environment.
Future<String?> _pkgConfig(String package, String flag) async {
  final env = <String, String>{};
  if (Platform.isMacOS) {
    env['PKG_CONFIG_PATH'] = [
      '/opt/homebrew/opt/openssl@3/lib/pkgconfig',
      '/usr/local/opt/openssl@3/lib/pkgconfig',
    ].join(':');
  }
  try {
    final result = await Process.run(
      'pkg-config',
      [flag, package],
      environment: env.isEmpty ? null : env,
    );
    if (result.exitCode == 0) return (result.stdout as String).trim();
    return null;
  } on ProcessException {
    return null;
  }
}

// ---------------------------------------------------------------------------
// 43 source files: 32 core + 7 glib + 4 unix (excludes stan/ and win/)
// ---------------------------------------------------------------------------

const _sources = [
  // Core (32 files)
  'third_party/nats_c/src/asynccb.c',
  'third_party/nats_c/src/buf.c',
  'third_party/nats_c/src/comsock.c',
  'third_party/nats_c/src/conn.c',
  'third_party/nats_c/src/crypto.c',
  'third_party/nats_c/src/dispatch.c',
  'third_party/nats_c/src/hash.c',
  'third_party/nats_c/src/js.c',
  'third_party/nats_c/src/jsm.c',
  'third_party/nats_c/src/kv.c',
  'third_party/nats_c/src/micro.c',
  'third_party/nats_c/src/micro_client.c',
  'third_party/nats_c/src/micro_endpoint.c',
  'third_party/nats_c/src/micro_error.c',
  'third_party/nats_c/src/micro_monitoring.c',
  'third_party/nats_c/src/micro_request.c',
  'third_party/nats_c/src/msg.c',
  'third_party/nats_c/src/nats.c',
  'third_party/nats_c/src/natstime.c',
  'third_party/nats_c/src/nkeys.c',
  'third_party/nats_c/src/nuid.c',
  'third_party/nats_c/src/object.c',
  'third_party/nats_c/src/opts.c',
  'third_party/nats_c/src/parser.c',
  'third_party/nats_c/src/pub.c',
  'third_party/nats_c/src/srvpool.c',
  'third_party/nats_c/src/stats.c',
  'third_party/nats_c/src/status.c',
  'third_party/nats_c/src/sub.c',
  'third_party/nats_c/src/timer.c',
  'third_party/nats_c/src/url.c',
  'third_party/nats_c/src/util.c',
  // glib (7 files)
  'third_party/nats_c/src/glib/glib.c',
  'third_party/nats_c/src/glib/glib_async_cb.c',
  'third_party/nats_c/src/glib/glib_dispatch_pool.c',
  'third_party/nats_c/src/glib/glib_gc.c',
  'third_party/nats_c/src/glib/glib_last_error.c',
  'third_party/nats_c/src/glib/glib_ssl.c',
  'third_party/nats_c/src/glib/glib_timer.c',
  // unix (4 files)
  'third_party/nats_c/src/unix/cond.c',
  'third_party/nats_c/src/unix/mutex.c',
  'third_party/nats_c/src/unix/sock.c',
  'third_party/nats_c/src/unix/thread.c',
];
