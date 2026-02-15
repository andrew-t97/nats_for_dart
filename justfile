# Show all available commands
list:
    @just --list

# Run all tests using group-based test runner (sequential init/close cycles)
# Pass additional args like: just test --reporter compact
test *args:
    dart test test/test_all.dart {{args}}

# Run individual test file (for debugging)
# Pass additional args like: just test-single nats_client_test.dart --reporter compact
test-single FILE *args:
    dart test test/{{FILE}} {{args}}

# Generate test coverage report (excludes generated FFI bindings)
coverage:
    just test --coverage=coverage
    dart run coverage:format_coverage \
        --lcov \
        --in=coverage \
        --out=coverage/lcov.info \
        --report-on=lib
    lcov --remove coverage/lcov.info '*/nats_bindings.g.dart' \
        -o coverage/lcov.info
    genhtml coverage/lcov.info -o coverage/report
    @echo "Coverage report: coverage/report/index.html"