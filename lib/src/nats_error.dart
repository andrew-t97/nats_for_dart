import 'nats_status.dart';

final class NatsError {
  /// The [NatsStatus] error code.
  final NatsStatus status;

  NatsError(this.status);

  @override
  String toString() => 'NatsError(${status.name})';
}
