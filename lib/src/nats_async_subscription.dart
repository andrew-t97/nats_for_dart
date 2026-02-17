import 'dart:async';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'package:meta/meta.dart';

import 'nats_bindings.g.dart';
import 'nats_exceptions.dart';
import 'nats_message.dart';

/// A static routing table that maps subscription IDs to their
/// [StreamController]s. Used by the native callback to deliver messages
/// to the correct Dart stream.
final Map<int, StreamController<NatsMessage>> _subscriptionRoutes = {};

/// Monotonically increasing counter used to generate unique subscription IDs
/// for the routing table.
int _nextSubscriptionId = 1;

/// The native callback that the NATS C library invokes on its internal
/// threads when a message arrives.
///
/// Wrapped with [NativeCallable.listener] so the invocation is posted to
/// the originating Dart isolate's event loop — making it safe to call
/// from any thread.
void _onMessage(
  Pointer<natsConnection> nc,
  Pointer<natsSubscription> sub,
  Pointer<natsMsg> msg,
  Pointer<Void> closure,
) {
  final id = closure.address;
  final controller = _subscriptionRoutes[id];
  if (controller == null || controller.isClosed) {
    // No route or already closed — destroy the message and bail.
    natsMsg_Destroy(msg);
    return;
  }

  // Detect "503 No Responders" before copying — the raw pointer must
  // still be alive for this check.
  if (natsMsg_IsNoResponders(msg)) {
    final subject = natsMsg_GetSubject(msg).cast<Utf8>().toDartString();
    natsMsg_Destroy(msg);
    controller.addError(NatsNoRespondersException(subject));
    return;
  }

  // Eagerly copy data out of the native pointer and destroy it.
  // Wrap in try/catch to prevent unhandled exceptions from crashing
  // the isolate — this callback is invoked from a NativeCallable.listener.
  try {
    final message = NatsMessage.fromNativePtr(msg);
    controller.add(message);
  } catch (e, stackTrace) {
    // Safety net: destroy the native message in case fromNativePtr threw
    // before reaching its internal natsMsg_Destroy call. Calling destroy
    // on an already-destroyed pointer is a no-op in the C library.
    try {
      natsMsg_Destroy(msg);
    } catch (_) {}
    // Propagate the error through the stream so consumers can observe it.
    controller.addError(e, stackTrace);
  }
}

/// Shared [NativeCallable] singleton for all async subscriptions.
///
/// Because [_onMessage] demuxes by subscription ID via the closure pointer,
/// every subscription can share the same native callback. This avoids a race
/// where the C dispatcher invokes a per-subscription callable that Dart has
/// already closed.
NativeCallable<
  Void Function(
    Pointer<natsConnection>,
    Pointer<natsSubscription>,
    Pointer<natsMsg>,
    Pointer<Void>,
  )
>?
_sharedMessageCallable;

/// Lazily initialises and returns the shared message callable.
NativeCallable<
  Void Function(
    Pointer<natsConnection>,
    Pointer<natsSubscription>,
    Pointer<natsMsg>,
    Pointer<Void>,
  )
>
_getSharedMessageCallable() {
  return _sharedMessageCallable ??=
      NativeCallable<
        Void Function(
          Pointer<natsConnection>,
          Pointer<natsSubscription>,
          Pointer<natsMsg>,
          Pointer<Void>,
        )
      >.listener(_onMessage);
}

/// Closes the shared message callable.
///
/// Must only be called after `nats_CloseAndWait()` guarantees all C threads
/// have exited. Sets to `null` so a subsequent `_getSharedMessageCallable()`
/// re-creates it (e.g. in tests that open multiple libraries).
@internal
void closeSharedMessageCallable() {
  _sharedMessageCallable?.close();
  _sharedMessageCallable = null;
}

/// An asynchronous subscription that delivers messages via a Dart [Stream].
///
/// Messages are received on internal NATS threads and safely bridged to the
/// Dart event loop using [NativeCallable.listener].
final class NatsAsyncSubscription implements Finalizable {
  static final _finalizer = NativeFinalizer(
    Native.addressOf<NativeFunction<Void Function(Pointer<natsSubscription>)>>(
      natsSubscription_Destroy,
    ).cast(),
  );

  Pointer<natsSubscription>? _sub;
  bool _closed = false;
  final int _id;
  final StreamController<NatsMessage> _controller;

  /// Callback invoked on close to remove this subscription from
  /// the owning client's active-subscription set.
  void Function()? _onClose;

  NatsAsyncSubscription._(this._sub, this._id, this._controller, this._onClose);

  /// Creates a new [NatsAsyncSubscription] by allocating a routing slot and
  /// ensuring the shared [NativeCallable.listener] exists.
  ///
  /// The native subscription pointer is **not** set until [updateSubPtr] is
  /// called after the C subscribe call succeeds. If the C call fails,
  /// calling [close] on the returned object cleanly releases the routing
  /// slot and [StreamController] without attempting to destroy a native
  /// subscription.
  ///
  /// This is intended to be called from [NatsClient.subscribe] and
  /// [NatsClient.queueSubscribe].
  @internal
  factory NatsAsyncSubscription.create(void Function()? onClose) {
    final id = _nextSubscriptionId++;
    final controller = StreamController<NatsMessage>();
    _subscriptionRoutes[id] = controller;

    // Ensure the shared callable exists (lazy-init).
    _getSharedMessageCallable();

    final sub = NatsAsyncSubscription._(null, id, controller, onClose);
    return sub;
  }

  /// Returns the shared native callback pointer, suitable for passing to
  /// the C subscribe functions (e.g. `natsConnection_Subscribe`).
  ///
  /// Must be called after [create] (which ensures the shared callable
  /// exists) and before the C subscribe call.
  static natsMsgHandler nativeCallbackFor() {
    return _getSharedMessageCallable().nativeFunction;
  }

  /// Returns the closure pointer (carrying the subscription ID) for [sub],
  /// suitable for passing to the C subscribe functions.
  ///
  /// The NATS C library forwards this opaque pointer to every callback
  /// invocation, allowing [_onMessage] to look up the correct
  /// [StreamController] in the routing table.
  static Pointer<Void> closureFor(NatsAsyncSubscription sub) {
    return Pointer.fromAddress(sub._id);
  }

  /// The subscription ID in the routing table.
  int get id => _id;

  /// Updates the native subscription pointer after the C subscribe call
  /// has succeeded. Called by [NatsClient.subscribe].
  void updateSubPtr(Pointer<natsSubscription> sub) {
    _sub = sub;
    _finalizer.attach(this, _sub!.cast(), detach: this);
  }

  /// Sets the maximum number of pending messages and bytes that the C library
  /// will buffer for this subscription before flagging a slow consumer.
  ///
  /// Pass `-1` for either parameter to mean "no limit".
  /// Must be called before heavy message traffic begins.
  void setPendingLimits({int msgLimit = -1, int bytesLimit = -1}) {
    if (_closed || _sub == null) {
      throw StateError('Subscription is closed');
    }
    final status = natsSubscription_SetPendingLimits(
      _sub!,
      msgLimit,
      bytesLimit,
    );
    checkStatus(status, 'natsSubscription_SetPendingLimits');
  }

  /// A stream of messages delivered to this subscription.
  Stream<NatsMessage> get messages => _controller.stream;

  /// Whether this subscription has been closed.
  bool get isClosed => _closed;

  /// Unsubscribes and destroys this subscription, closing the message stream.
  ///
  /// Native resources are freed synchronously. The returned [Future]
  /// completes when the stream controller has finished notifying listeners.
  /// Callers that don't need to wait for stream draining can safely ignore
  /// the returned future.
  ///
  /// Safe to call multiple times; subsequent calls are no-ops.
  Future<void> unsubscribe() {
    if (_closed) return Future.value();
    _closed = true;

    // 1. Remove from routing table so any in-flight callbacks (already
    //    posted to the Dart event loop) see no controller and destroy
    //    the native message themselves.
    _subscriptionRoutes.remove(_id);

    // 2. Unsubscribe and destroy the native subscription — this tells
    //    the C library to stop delivering messages.
    if (_sub != null) {
      final subPtr = _sub!;
      _sub = null;
      // Detach the finalizer before manually destroying to prevent
      // double-free if GC runs after an explicit close.
      _finalizer.detach(this);
      final status = natsSubscription_Unsubscribe(subPtr);
      natsSubscription_Destroy(subPtr);
      // Ignore expected statuses during teardown (e.g. connection
      // already closed or subscription already invalid).
      if (status != natsStatus.NATS_OK &&
          status != natsStatus.NATS_CONNECTION_CLOSED &&
          status != natsStatus.NATS_INVALID_SUBSCRIPTION) {
        // Log or swallow — the subscription is being torn down.
      }
    }

    // 3. Remove from owning client's active set.
    _onClose?.call();
    _onClose = null;

    // 4. Close the stream to notify listeners. For a single-subscription
    //    StreamController, close() only completes when the done event is
    //    delivered to a subscriber. If nobody is listening, return
    //    immediately to avoid hanging indefinitely.
    if (_controller.hasListener) {
      return _controller.close();
    }
    _controller.close();
    return Future.value();
  }

  /// Alias for [unsubscribe].
  Future<void> close() => unsubscribe();
}
