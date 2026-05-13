/// Message headers demo — pub/sub with a tracing-style header, then
/// JetStream publish-with-dedup using `Nats-Msg-Id`.
///
/// Prerequisites:
///   - `nats-server -js` running on localhost:4222 (JetStream enabled).
///
/// Run:
///   dart run example/headers_demo.dart
library;

import 'package:nats_for_dart/nats_for_dart.dart';

Future<void> main() async {
  NatsLibrary.init();

  final client = NatsClient.connect('nats://localhost:4222');
  final js = client.jetStream();

  try {
    _runPubSubScene(client);
    _runJetStreamDedupScene(js);
  } finally {
    js.close();
    await client.close();
    NatsLibrary.close(timeoutMs: 5000);
  }
}

/// Scene 1: publish a message carrying a tracing-style header and observe
/// it on the subscriber.
void _runPubSubScene(NatsClient client) {
  print('--- Scene 1: pub/sub with X-Trace-Id header ---');
  const subject = 'demo.trace';
  final subscription = client.subscribeSync(subject);
  try {
    final outgoing = NatsHeaders.from({
      'X-Trace-Id': '7a1c0f2b-5e8d-4f9a-b3c2-1d0e9f8a7c6b',
      'X-Origin': 'headers_demo.dart',
    });
    client.publish(subject, 'order confirmed', headers: outgoing);

    final received = subscription.nextMessage(
      timeout: const Duration(seconds: 2),
    );
    print('subject: ${received.subject}');
    print('body:    ${received.dataAsString}');
    print('headers:');
    for (final key in received.headers.keys) {
      for (final value in received.headers.getAll(key)) {
        print('  $key: $value');
      }
    }
  } finally {
    subscription.close();
  }
}

/// Scene 2: publish the same `Nats-Msg-Id` twice — JetStream deduplicates
/// the second attempt and the pub-ack carries `duplicate: true`.
void _runJetStreamDedupScene(JetStreamContext js) {
  print('\n--- Scene 2: JetStream Nats-Msg-Id dedup ---');
  const streamName = 'HEADERS_DEMO';
  js.addStream(
    JsStreamConfig(
      name: streamName,
      subjects: ['demo.dedup.>'],
      storage: StorageType.memory,
    ),
  );

  try {
    final dedupHeaders = NatsHeaders.from({'Nats-Msg-Id': 'order-42'});
    final first = js.publishString(
      'demo.dedup.orders',
      'payment for order-42',
      headers: dedupHeaders,
    );
    print('1st publish → seq=${first.sequence} duplicate=${first.duplicate}');

    final second = js.publishString(
      'demo.dedup.orders',
      'payment for order-42 (retry)',
      headers: dedupHeaders,
    );
    print('2nd publish → seq=${second.sequence} duplicate=${second.duplicate}');
  } finally {
    js.deleteStream(streamName);
  }
}
