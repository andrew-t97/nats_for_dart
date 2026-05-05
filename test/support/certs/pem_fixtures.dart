/// Placeholder PEM strings for unit tests that exercise PEM-bearing
/// configuration paths without performing real cryptographic parsing.
///
/// Located under `test/support/certs/` because that directory is excluded
/// from the `detect-private-key` pre-commit hook; otherwise the
/// `BEGIN PRIVATE KEY` armor below would trip the scanner even though
/// the bodies are non-cryptographic placeholders.
library;

const caCertPemFixture =
    '-----BEGIN CERTIFICATE-----\nMIIBkTCCATegAwIBAgI...\n-----END CERTIFICATE-----\n';

const clientCertPemFixture =
    '-----BEGIN CERTIFICATE-----\nMIIClientCert...\n-----END CERTIFICATE-----\n';

const clientKeyPemFixture =
    '-----BEGIN PRIVATE KEY-----\nMIIClientKey...\n-----END PRIVATE KEY-----\n';
