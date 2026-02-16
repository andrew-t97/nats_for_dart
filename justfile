# Show all available commands
list:
    @just --list

# Run all quality checks (format, lint, tests) - perfect for pre-commit or CI
check:
    @echo "Running format check..."
    just format-check
    @echo "Running lint check..."
    just lint
    @echo "Running tests..."
    just test

# Format all Dart code in the project
format:
    dart format .

# Check if code is formatted correctly without making changes (CI-friendly)
format-check:
    dart format --output=none --set-exit-if-changed .

# Analyze code using configured lint rules (treats all issues as fatal)
lint:
    dart analyze --fatal-infos

# Apply automated lint fixes and verify no issues remain
lint-fix:
    dart fix --apply
    dart analyze --fatal-infos

# Check for outdated dependencies
deps-outdated:
    dart pub outdated

# Upgrade dependencies to latest resolvable versions (respects pubspec.yaml constraints)
deps-upgrade:
    dart pub upgrade

# Upgrade dependencies including major versions (modifies pubspec.yaml)
# WARNING: May introduce breaking changes - review carefully
deps-upgrade-major:
    dart pub upgrade --major-versions

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