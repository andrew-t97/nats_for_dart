import 'package:meta/meta.dart';

/// Immutable configuration for a [NatsClient] connection.
///
/// Pass an instance of this class to `NatsClient.connect` (or
/// `connectAsync`) via the `options:` named parameter. Every field is either
/// nullable — where `null` means "use the native client default" — or has a
/// documented default value. This mirrors the idiomatic Dart config shape
/// used elsewhere in this library (`JsStreamConfig`, `JsConsumerConfig`,
/// `KvConfig`).
///
/// The URL of the server is passed positionally to `NatsClient.connect` and
/// is deliberately **not** a field here. Use [servers] to connect to a
/// cluster with fail-over.
///
/// Example:
/// ```dart
/// const options = NatsOptions(
///   name: 'my-client',
///   maxReconnect: 5,
///   reconnectWait: Duration(seconds: 2),
/// );
/// final client = NatsClient.connect('nats://localhost:4222', options: options);
/// ```
@immutable
final class NatsOptions {
  /// A human-readable name for this connection, visible in server monitoring.
  final String? name;

  /// Cluster server URLs. When non-empty, this list is used instead of the
  /// positional `url` argument to `NatsClient.connect`; the client will
  /// attempt to connect to each server in order (or randomly, unless
  /// [noRandomize] is `true`).
  ///
  /// The default is `const []`, which is structurally immutable. Callers who
  /// supply their own list must not mutate it after construction — the
  /// configuration captures the reference rather than making a defensive
  /// copy, so later mutations would silently change these options.
  final List<String> servers;

  /// Username for `user`/`password` authentication.
  ///
  /// Must be provided together with [password]; supplying one without the
  /// other is a configuration error that will be surfaced when the options
  /// are applied to the native handle. Mutually exclusive with [token].
  final String? user;

  /// Password for `user`/`password` authentication. See [user]. Mutually
  /// exclusive with [token].
  final String? password;

  /// Token for single-token authentication. Mutually exclusive with
  /// [user]/[password].
  final String? token;

  /// Maximum number of reconnection attempts before the connection is
  /// permanently closed. `null` = use the native default.
  final int? maxReconnect;

  /// Wait time between reconnection attempts. `null` = use the native
  /// default.
  final Duration? reconnectWait;

  /// Size of the internal reconnect buffer in bytes. When disconnected,
  /// publish calls buffer into this space until the connection is
  /// re-established; once the buffer fills, subsequent publish calls fail.
  /// `null` = use the native default.
  final int? reconnectBufSize;

  /// When `true`, the server acknowledges every protocol message. `null` =
  /// use the native default.
  final bool? verbose;

  /// When `true`, the server performs extra protocol checks. `null` = use
  /// the native default.
  final bool? pedantic;

  /// When `true`, servers in [servers] are tried in order rather than in
  /// randomised order. `null` = use the native default.
  final bool? noRandomize;

  /// Interval between client → server pings. `null` = use the native
  /// default.
  final Duration? pingInterval;

  /// Maximum number of outstanding pings before the connection is considered
  /// stale. `null` = use the native default.
  final int? maxPingsOut;

  /// Size of the internal read/write buffers in bytes. `null` = use the
  /// native default.
  final int? ioBufSize;

  /// Connection establishment timeout. `null` = use the native default.
  final Duration? timeout;

  /// Path to a user credentials file (JWT, or chained JWT + seed).
  ///
  /// When the JWT and seed live in separate files, set [credentialsSeedFile]
  /// to the seed path as well.
  final String? credentialsFile;

  /// Path to a user credentials seed file. Only used when
  /// [credentialsFile] points to a JWT-only file.
  final String? credentialsSeedFile;

  /// Creates an immutable [NatsOptions] configuration.
  ///
  /// All fields are optional. Unset nullable fields fall back to the native
  /// client's defaults when the options are applied to a connection.
  const NatsOptions({
    this.name,
    this.servers = const [],
    this.user,
    this.password,
    this.token,
    this.maxReconnect,
    this.reconnectWait,
    this.reconnectBufSize,
    this.verbose,
    this.pedantic,
    this.noRandomize,
    this.pingInterval,
    this.maxPingsOut,
    this.ioBufSize,
    this.timeout,
    this.credentialsFile,
    this.credentialsSeedFile,
  });
}
