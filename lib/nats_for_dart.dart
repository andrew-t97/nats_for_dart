/// Dart FFI bindings for the NATS C client library.
///
/// Provides synchronous and asynchronous pub/sub, JetStream, and KeyValue
/// via a Dart-friendly wrapper around the native `libnats` shared library.
library;

export 'src/nats_async_subscription.dart' show NatsAsyncSubscription;
export 'src/nats_client.dart' show NatsClient;
export 'src/nats_exceptions.dart';
export 'src/nats_library.dart' show NatsLibrary;
export 'src/nats_message.dart' show NatsMessage;
export 'src/nats_sync_subscription.dart' show NatsSyncSubscription;
export 'src/nats_options.dart' show NatsOptions, NatsError;
export 'src/nats_bindings.g.dart'
    show
        natsStatus,
        jsRetentionPolicy,
        jsDiscardPolicy,
        jsStorageType,
        jsDeliverPolicy,
        jsAckPolicy,
        jsReplayPolicy,
        kvOperation;
export 'src/js_message.dart' show JsMessage, JsMessageMetadata, JsPubAckResult;
export 'src/jetstream_context.dart'
    show
        JetStreamContext,
        JsStreamConfig,
        JsConsumerConfig,
        JsStreamInfoResult,
        JsConsumerInfoResult,
        JsSyncSubscription,
        JsAsyncSubscription,
        JsPullSubscription;
export 'src/kv_store.dart'
    show KeyValueStore, KvConfig, KvEntry, JetStreamKeyValue;
