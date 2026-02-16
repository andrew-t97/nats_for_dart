# Contributing to nats_for_dart

Thank you for your interest in contributing! This guide covers the development and maintenance workflows for this package.

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

> **Note:** If upgrading from a release where `version.h` is not pre-generated (only `version.h.in` exists), manually create `version.h` from `version.h.in` by substituting the version values before building.

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
