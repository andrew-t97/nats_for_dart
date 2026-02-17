import 'jetstream_context.dart';
import 'nats_async_subscription.dart';
import 'nats_bindings.g.dart';
import 'nats_exceptions.dart';
import 'nats_options.dart';

/// Global library initialisation and teardown for the NATS C client.
///
/// Call [NatsLibrary.init] once before creating any connections and
/// [NatsLibrary.close] after all connections have been destroyed.
final class NatsLibrary {
  NatsLibrary._();

  /// Initialises the NATS C library with default settings.
  ///
  /// This must be called (once) before any connections are created. Passing
  /// `-1` uses the library defaults.
  static void init() {
    checkStatus(nats_Open(-1), 'nats_Open');
  }

  /// Tears down the NATS C library and waits for resources to be released.
  ///
  /// Pass `0` to wait indefinitely.
  static void close({int timeoutMs = 0}) {
    checkStatus(nats_CloseAndWait(timeoutMs), 'nats_CloseAndWait');

    // All C threads have exited — safe to close shared NativeCallables.
    closeSharedMessageCallable();
    JsAsyncSubscription.closeSharedCallable();
    closeSharedLifecycleCallables();
  }
}
