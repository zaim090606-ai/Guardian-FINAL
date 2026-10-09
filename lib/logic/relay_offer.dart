import 'dart:async';

import 'sos_packet.dart';

/// Thrown when the mesh relay cannot be reached, with a reason for the log.
class RelayUnavailable implements Exception {
  final String reason;
  const RelayUnavailable(this.reason);
  @override
  String toString() => reason;
}

/// Service-isolate side of the relay bridge. Nearby Connections only works in
/// the UI isolate (it needs an Activity), so the service hands the packet to
/// the UI isolate and waits for its acknowledgement.
class RelayOfferClient {
  static const String unavailableReason =
      'relay unavailable: app UI not running';

  /// Sends an event to the UI isolate.
  final void Function(String event, Map<String, dynamic> data) send;

  /// Acknowledgements from the UI isolate: {id, ok, reason?}.
  final Stream<Map<String, dynamic>?> acks;
  final Duration timeout;

  RelayOfferClient({
    required this.send,
    required this.acks,
    this.timeout = const Duration(seconds: 8),
  });

  /// True when the UI isolate started advertising. Throws [RelayUnavailable]
  /// when nobody answers in time or the UI reports a failure.
  Future<bool> offer(SosPacket packet) async {
    final completer = Completer<Map<String, dynamic>>();
    final sub = acks.listen((e) {
      if (e != null && e['id'] == packet.id && !completer.isCompleted) {
        completer.complete(e);
      }
    });
    try {
      send('relay_offer', packet.toJson());
      final ack = await completer.future.timeout(timeout);
      if (ack['ok'] == true) return true;
      throw RelayUnavailable('${ack['reason'] ?? 'relay did not start'}');
    } on TimeoutException {
      throw const RelayUnavailable(unavailableReason);
    } finally {
      await sub.cancel();
    }
  }
}
