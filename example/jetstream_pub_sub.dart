// JetStream publish/subscribe demonstration.
//
// Requires: `nats-server -js` running on localhost:4222.

import 'package:nats_dart/nats_dart.dart';

void main() {
  NatsLibrary.init();

  final client = NatsClient.connect('nats://localhost:4222');
  final js = client.jetStream();

  try {
    // 1. Create a stream for orders
    final streamInfo = js.addStream(JsStreamConfig(
      name: 'ORDERS',
      subjects: ['orders.>'],
      storage: jsStorageType.js_MemoryStorage,
    ));
    print('Created stream: ${streamInfo.name}');

    // 2. Publish 5 messages
    for (var i = 1; i <= 5; i++) {
      final ack = js.publishString('orders.new', 'Order #$i');
      print('Published to ${ack.stream} seq=${ack.sequence}');
    }

    // 3. Create a pull subscription with a durable consumer
    final pullSub = js.pullSubscribe('orders.new', 'order-processor');

    // 4. Fetch the batch and process
    final messages = pullSub.fetch(5, timeout: Duration(seconds: 5));
    print('\nReceived ${messages.length} messages:');
    for (final msg in messages) {
      final meta = msg.metadata();
      print(
        '  seq=${meta.streamSequence} data="${msg.dataAsString}" '
        'delivered=${meta.numDelivered}',
      );
      msg.ack();
      msg.destroy();
    }

    // 5. Clean up
    pullSub.close();
    js.deleteStream('ORDERS');
    print('\nStream deleted. Done!');
  } finally {
    js.close();
    client.close();
    NatsLibrary.close(timeoutMs: 5000);
  }
}
