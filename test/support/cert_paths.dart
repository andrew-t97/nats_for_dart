/// Test-fixture cert/key paths, resolved relative to the package root.
///
/// `dart test` sets CWD to the package root, so these are valid for every
/// supported invocation (full suite, single file, aggregated runner). The
/// paired `docker_nats_tls.dart` and `docker_nats_mtls.dart` fixtures mount
/// `test/support/certs/` into the container at `/certs`, so test-side code
/// pointing at the host paths and server-side config pointing at the
/// container paths stay in sync via the recipe in `nats-tls.conf`.
library;

const String testCaCertPath = 'test/support/certs/ca-cert.pem';
const String testClientCertPath = 'test/support/certs/client-cert.pem';
const String testClientKeyPath = 'test/support/certs/client-key.pem';
