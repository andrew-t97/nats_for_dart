/// Mutual TLS (mTLS) pub/sub demo using the nats_for_dart library.
///
/// Connects to an mTLS-enabled `nats-server` that requires a client
/// certificate signed by the test CA, then publishes and receives a
/// round-trip message over the TLS channel.
///
/// Hostname verification runs automatically for any TLS connection;
/// passes `expectedHostname: 'localhost'` to override this. This is
/// useful when dialling by IP, going through an SNI-rewriting proxy,
/// or addressing an internal load-balancer hostname.
///
/// Prerequisites:
///   - `nats-server` running on localhost:4224 with the mTLS fixture config.
///     The integration-test fixture (`DockerNatsMtls`) starts and stops its
///     own container as part of `dart test`, so it isn't usable for ad-hoc
///     runs. For this demo, start one yourself — either:
///       * Native: `nats-server -c test/support/nats-mtls-native.conf`, or
///       * Docker: `docker run -d -p 4224:4224 -p 8224:8224 \
///                  -v "$(pwd)/test/support/certs:/certs:ro" \
///                  -v "$(pwd)/test/support/nats-mtls.conf:/etc/nats/nats-mtls.conf:ro" \
///                  nats:latest -c /etc/nats/nats-mtls.conf`
///   - Cert files in `test/support/certs/` (committed in the repo).
///
/// Run from the package root:
///   dart run example/mtls_demo.dart
library;

import 'package:nats_for_dart/nats_for_dart.dart';

Future<void> main() async {
  // 1. Initialise the library.
  print('Initialising NATS library...');
  NatsLibrary.init();

  NatsClient? client;
  NatsSyncSubscription? subscription;

  try {
    // 2. Connect to the mTLS-enabled NATS server. The `tls://` URL
    //    auto-enables TLS; the three cert paths drive the
    //    mutual handshake.
    print('Connecting to tls://localhost:4224 with mTLS...');
    client = NatsClient.connect(
      'tls://localhost:4224',
      options: const NatsOptions(
        clientCertPath: 'test/support/certs/client-cert.pem',
        clientKeyPath: 'test/support/certs/client-key.pem',
        caCertPath: 'test/support/certs/ca-cert.pem',
        expectedHostname: 'localhost',
      ),
    );
    print('Connected over mTLS!');

    // 3. Create a synchronous subscription on "test.mtls.demo".
    const subject = 'test.mtls.demo';
    print('Subscribing to "$subject"...');
    subscription = client.subscribeSync(subject);

    // 4. Publish a string message.
    const payload = 'Hello over mTLS!';
    print('Publishing: "$payload" → "$subject"');
    client.publish(subject, payload);

    // 5. Receive the message (with a 2-second timeout).
    print('Waiting for message...');
    final message = subscription.nextMessage(
      timeout: const Duration(seconds: 2),
    );

    // 6. Print the result.
    print('Received on "${message.subject}": ${message.dataAsString}');
  } catch (e) {
    print('Error: $e');
  } finally {
    // 7. Clean up.
    subscription?.close();
    await client?.close();

    // 8. Tear down the library.
    print('Closing NATS library...');
    NatsLibrary.close(timeoutMs: 5000);
    print('Done.');
  }
}
