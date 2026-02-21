# Contributing to nats_for_dart

Thank you for your interest in contributing! This guide covers the development and maintenance workflows for this package.

## Development Setup

After cloning, install the pre-commit hooks so quality checks run automatically before each commit:

1. **Install pre-commit** (once per machine):
   ```bash
   brew install pre-commit   # macOS
   # or: pip install pre-commit
   ```

2. **Activate the hooks** (once per clone):
   ```bash
   just install-hooks
   ```

From then on, `git commit` will automatically run formatting and lint checks. To run all checks manually without committing:

```bash
just pre-commit
```

## Upgrading the vendored nats.c

The native C source lives in `third_party/nats_c/` as a vendored copy (currently v3.12.0). To upgrade to a new nats.c release:

1. **Clone or download** the new [nats.c release](https://github.com/nats-io/nats.c/releases).

2. **Run the update script:**
   ```bash
   ./scripts/update_vendor.sh /path/to/nats.c
   ```

3. **Check for added or removed `.c` files** and update the `_sources` list in `hook/build.dart` accordingly. The script will print file counts to help you spot differences.

4. **Regenerate FFI bindings:**
   ```bash
   dart run ffigen --config ffigen.yaml
   ```

5. **Run the test suite:**
   ```bash
   just test
   ```
   
6. **Update `NOTICE.md` and `README.md`** — if the new release changes the copyright
   year range or version number, update the version reference and copyright years in
   both `NOTICE.md` and the license section of `README.md`.

> **Note:** If upgrading from a release where `version.h` is not pre-generated (only `version.h.in` exists), manually create `version.h` from `version.h.in` by substituting the version values before building.

## Upgrading the vendored LibreSSL

The LibreSSL TLS library lives in `third_party/libressl/` (currently v4.1.0). To
upgrade:

1. **Run the update script:**
   ```bash
   ./scripts/update_libressl.sh <version>
   ```

2. **Update `third_party/libressl/VERSION`** to the new version number.

3. **Check for added or removed `.c` files** and update the `_libresslSources` list in
   `hook/build.dart` accordingly.

4. **Run the test suite:**
   ```bash
   just test
   ```

5. **Update `NOTICE.md` and `README.md`** — update the LibreSSL version and any
   copyright year changes in both files.

## Running tests

Tests automatically start a Docker NATS container with JetStream enabled via the `DockerNats` helper in `test/support/docker_nats.dart`. Docker must be installed and running.

```bash
# Run all tests — Docker container starts/stops automatically
just test

# Run a single test file
just test-single nats_client_test.dart
```

**How it works:** Each test file calls `DockerNats.start()` in `setUpAll` and `nats.stop()` in `tearDownAll`. The helper uses reference counting — the first `start()` launches the container, subsequent calls increment a counter, and the container is only removed when the last `stop()` decrements to zero. This means every test file is independently runnable.

If the container fails to start, you'll get a clear `StateError` indicating whether Docker is missing or the container couldn't launch.
