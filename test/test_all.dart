// test/test_all.dart
import 'package:test/test.dart';

import 'nats_client_test.dart' as nats_client_test;
import 'nats_async_test.dart' as nats_async_test;
import 'jetstream_test.dart' as jetstream_test;
import 'kv_test.dart' as kv_test;
import 'request_reply_test.dart' as request_reply_test;

void main() {
  // Each group runs its own init/close cycle sequentially
  group('NatsClient Tests', nats_client_test.main);
  group('Async Tests', nats_async_test.main);
  group('JetStream Tests', jetstream_test.main);
  group('KeyValue Tests', kv_test.main);
  group('Request-Reply Tests', request_reply_test.main);
}
