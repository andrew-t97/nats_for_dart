# Show all available commands
list:
    @just --list

# Run all tests (each file in its own process for native library isolation)
test:
    #!/usr/bin/env bash
    set -uo pipefail
    failed=0
    dart test test/nats_client_test.dart  || failed=1
    dart test test/nats_async_test.dart   || failed=1
    dart test test/jetstream_test.dart    || failed=1
    dart test test/kv_test.dart           || failed=1
    dart test test/request_reply_test.dart || failed=1
    exit $failed