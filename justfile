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