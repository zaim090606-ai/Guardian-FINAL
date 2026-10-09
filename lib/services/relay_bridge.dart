import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import '../logic/relay_offer.dart';
import '../logic/sos_packet.dart';
import 'mesh_receiver_service.dart';
import 'relay_service.dart';

/// Connects the service isolate (voice and impact SOS) to the relay, which can
/// only run in the UI isolate. Relay works while the app is open or alive in
/// recents.
class RelayBridge {
  /// Service isolate: the function EmergencyService uses for its mesh channel.
  static Future<bool> Function(SosPacket) serviceOffer(ServiceInstance service) {
    final client = RelayOfferClient(
      send: (event, data) => service.invoke(event, data),
      acks: service.on('relay_ack'),
    );
    return client.offer;
  }

  /// UI isolate: answers relay offers from the service isolate.
  static void attachUi() {
    final bg = FlutterBackgroundService();
    // The service cancelled (or finished cancelling) an SOS it had offered.
    bg.on('relay_stop').listen((_) => unawaited(RelayService().stopRelay()));
    bg.on('relay_offer').listen((event) async {
      if (event == null) return;
      var ok = false;
      var reason = '';
      try {
        final packet = SosPacket.fromJson(
            Map<String, dynamic>.from(jsonDecode(jsonEncode(event)) as Map));
        MeshReceiverService().markOwnPacket(packet.id);
        ok = await RelayService().broadcast(packet);
        if (!ok) reason = 'relay could not start advertising';
      } catch (e) {
        reason = 'relay error: $e';
        debugPrint('relay_offer failed: $e');
      }
      try {
        bg.invoke('relay_ack', {'id': event['id'], 'ok': ok, 'reason': reason});
      } catch (_) {}
    });
  }
}
