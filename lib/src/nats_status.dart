import 'nats_bindings.g.dart' as ffi;

/// Status code returned by the NATS C client library.
///
/// Wraps the C-style `natsStatus` FFI enum with Dart-idiomatic names.
/// Most operations surface these through exceptions, but you may encounter
/// them directly when working with lower-level FFI calls.
enum NatsStatus {
  /// Operation completed successfully.
  ok(0),

  /// Generic, unclassified error.
  error(1),

  /// Error parsing a protocol message or unexpected server response.
  protocolError(2),

  /// Network I/O error during communication with the server.
  ioError(3),

  /// A protocol message exceeded the read-buffer size.
  lineTooLong(4),

  /// The operation failed because the connection is closed.
  connectionClosed(5),

  /// Unable to connect; the server could not be reached or is not running.
  noServer(6),

  /// The server closed the connection because it did not receive PINGs at
  /// the expected interval.
  staleConnection(7),

  /// The client is configured to use TLS, but the server is not.
  secureConnectionWanted(8),

  /// The server requires a TLS connection.
  secureConnectionRequired(9),

  /// The connection was disconnected. Depending on configuration, it may
  /// reconnect automatically.
  connectionDisconnected(10),

  /// Authentication with the server failed.
  connectionAuthFailed(11),

  /// The requested action is not permitted.
  notPermitted(12),

  /// The requested resource was not found (internal error).
  notFound(13),

  /// The URL is malformed — for example, no host was specified.
  addressMissing(14),

  /// The subject string is invalid (e.g. null or empty).
  invalidSubject(15),

  /// An invalid argument was passed to a function.
  invalidArg(16),

  /// The subscription has been closed and can no longer be used.
  invalidSubscription(17),

  /// The timeout value must be a positive number.
  invalidTimeout(18),

  /// An unexpected state was encountered, such as calling NextMsg on an
  /// asynchronous subscriber.
  illegalState(19),

  /// The pending-message limit was reached; messages are being dropped.
  slowConsumer(20),

  /// The payload exceeds the maximum size allowed by the server.
  maxPayload(21),

  /// The maximum number of delivered messages was reached (e.g. via
  /// AutoUnsubscribe).
  maxDeliveredMsgs(22),

  /// A buffer is too small to hold the data.
  insufficientBuffer(23),

  /// The operation failed due to insufficient memory.
  noMemory(24),

  /// A system-level function returned an error.
  sysError(25),

  /// The operation timed out.
  timeout(26),

  /// The NATS library failed to initialize.
  failedToInitialize(27),

  /// The NATS library has not been initialized yet.
  notInitialized(28),

  /// An SSL/TLS error occurred while establishing a connection.
  sslError(29),

  /// The server does not support the requested action.
  noServerSupport(30),

  /// The connection has not been established yet; a retry is in progress.
  notYetConnected(31),

  /// The connection or subscription is draining; some operations will fail.
  draining(32),

  /// An invalid queue name was used when creating a queue subscription.
  invalidQueueName(33),

  /// No responders were available when the server received the request.
  noResponders(34),

  /// A JetStream consumer sequence mismatch was detected.
  mismatch(35),

  /// The library detected that server heartbeats have been missed on a
  /// JetStream subscription.
  missedHeartbeat(36),

  /// The byte-limit for received messages was exceeded.
  limitReached(37),

  /// The Pin ID in the request does not match the currently pinned consumer
  /// subscriber ID on the server.
  pinIdMismatch(38);

  /// The underlying integer code from the C library.
  final int value;

  /// Creates a [NatsStatus] with the given integer [value].
  const NatsStatus(this.value);

  /// Returns the [NatsStatus] corresponding to the given integer [value].
  ///
  /// Throws [ArgumentError] if [value] does not match any known status.
  static NatsStatus fromValue(int value) => switch (value) {
    0 => ok,
    1 => error,
    2 => protocolError,
    3 => ioError,
    4 => lineTooLong,
    5 => connectionClosed,
    6 => noServer,
    7 => staleConnection,
    8 => secureConnectionWanted,
    9 => secureConnectionRequired,
    10 => connectionDisconnected,
    11 => connectionAuthFailed,
    12 => notPermitted,
    13 => notFound,
    14 => addressMissing,
    15 => invalidSubject,
    16 => invalidArg,
    17 => invalidSubscription,
    18 => invalidTimeout,
    19 => illegalState,
    20 => slowConsumer,
    21 => maxPayload,
    22 => maxDeliveredMsgs,
    23 => insufficientBuffer,
    24 => noMemory,
    25 => sysError,
    26 => timeout,
    27 => failedToInitialize,
    28 => notInitialized,
    29 => sslError,
    30 => noServerSupport,
    31 => notYetConnected,
    32 => draining,
    33 => invalidQueueName,
    34 => noResponders,
    35 => mismatch,
    36 => missedHeartbeat,
    37 => limitReached,
    38 => pinIdMismatch,
    _ => throw ArgumentError('Unknown value for NatsStatus: $value'),
  };
}

/// Converts from the C-style `natsStatus` to Dart-idiomatic [NatsStatus].
NatsStatus fromCStatus(ffi.natsStatus cStatus) =>
    NatsStatus.fromValue(cStatus.value);
