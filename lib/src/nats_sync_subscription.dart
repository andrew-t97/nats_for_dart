import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:meta/meta.dart';

import 'nats_bindings.g.dart';
import 'nats_exceptions.dart';
import 'nats_message.dart';

/// A synchronous subscription that can be polled for messages.
///
/// **Warning:** [nextMessage] calls the blocking C function
/// `natsSubscription_NextMsg`, which blocks the calling isolate's event
/// loop until a message arrives or the timeout expires. In Flutter apps
/// this will freeze the UI.
///
/// Use [NatsAsyncSubscription] (via [NatsClient.subscribe]) for
/// Flutter-friendly, non-blocking message delivery. This class is intended
/// for CLI tools, scripts, and tests where blocking is acceptable.
final class NatsSyncSubscription implements Finalizable {
  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(Pointer<natsSubscription>)>>(
      natsSubscription_Destroy,
    ).cast(),
  );

  Pointer<natsSubscription>? _sub;
  bool _closed = false;

  /// Whether this subscription has been closed.
  bool get isClosed => _closed;

  /// Callback invoked on unsubscribe so the owning client can remove this
  /// subscription from its active-subscription set.
  void Function()? _onUnsubscribe;

  NatsSyncSubscription._(this._sub, this._onUnsubscribe) {
    _finalizer.attach(this, _sub!.cast(), detach: this);
  }

  /// Creates a new [NatsSyncSubscription] wrapping the given native pointer.
  ///
  /// [onUnsubscribe] is called once when the subscription is closed, allowing
  /// the owning client to remove it from its tracking set.
  ///
  /// This is intended to be called from [NatsClient.subscribeSync].
  @internal
  factory NatsSyncSubscription.create(
    Pointer<natsSubscription> sub,
    void Function()? onUnsubscribe,
  ) {
    return NatsSyncSubscription._(sub, onUnsubscribe);
  }

  /// Polls for the next message, blocking the current isolate up to [timeout].
  ///
  /// **This is a blocking FFI call.** The Dart event loop will not process
  /// any events (timers, I/O, UI frames) until this method returns. In
  /// Flutter, prefer [NatsAsyncSubscription] instead.
  ///
  /// Returns a [NatsMessage] with eagerly-copied data. The underlying native
  /// message is destroyed before this method returns.
  NatsMessage nextMessage({Duration timeout = const Duration(seconds: 5)}) {
    _ensureOpen();
    final msgPtrPtr = calloc<Pointer<natsMsg>>();
    try {
      final status = natsSubscription_NextMsg(
        msgPtrPtr,
        _sub!,
        timeout.inMilliseconds,
      );
      checkStatus(status, 'natsSubscription_NextMsg');
      return NatsMessage.fromNativePtr(msgPtrPtr.value);
    } finally {
      calloc.free(msgPtrPtr);
    }
  }

  /// Unsubscribes and destroys this subscription.
  void unsubscribe() {
    if (_closed) return;
    _closed = true;
    _onUnsubscribe?.call();
    _onUnsubscribe = null;
    if (_sub != null) {
      final subPtr = _sub!;
      _sub = null;
      // Detach the finalizer before manually destroying to prevent
      // double-free if GC runs after an explicit close.
      _finalizer.detach(this);
      // Ignore expected statuses during teardown (e.g. connection already
      // closed or subscription already invalid).
      final status = natsSubscription_Unsubscribe(subPtr);
      // Always destroy regardless of unsubscribe outcome.
      natsSubscription_Destroy(subPtr);
      if (status != natsStatus.NATS_OK &&
          status != natsStatus.NATS_CONNECTION_CLOSED &&
          status != natsStatus.NATS_INVALID_SUBSCRIPTION) {
        checkStatus(status, 'natsSubscription_Unsubscribe');
      }
    }
  }

  /// Alias for [unsubscribe].
  void close() => unsubscribe();

  void _ensureOpen() {
    if (_closed) {
      throw StateError('Subscription is already closed');
    }
  }
}
