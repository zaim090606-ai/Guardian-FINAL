import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';

import '../logic/advertising_controller.dart';
import '../logic/anchor_beacon.dart';
import '../logic/sos_guard.dart' show generateAlertId;
import '../logic/sos_packet.dart';
import 'diagnostics_hub.dart';

/// Sender side of the offline mesh: advertises over Nearby Connections and
/// hands the SOS packet to every Guardian device that connects.
class RelayService {
  static final RelayService _instance = RelayService._internal();
  factory RelayService() => _instance;
  RelayService._internal();

  static const String serviceId = 'com.guardian.emergency.relay';
  static const Strategy strategy = Strategy.P2P_CLUSTER;

  /// Longest a packet keeps being offered to new peers; it is withdrawn
  /// earlier when the SOS is cancelled (see [stopRelay]).
  static const Duration offerWindow = Duration(minutes: 30);

  final Map<String, SosPacket> _active = {};
  final Map<String, Timer> _expiry = {};
  final LinkedHashSet<String> _beaconSeen = LinkedHashSet<String>();

  /// How long the sender keeps a peer connected after handing over the packet,
  /// so the helper's beacon reply can arrive.
  static const Duration holdConnection = Duration(seconds: 20);

  late final AdvertisingController _adv = AdvertisingController(
    start: _startAdvertising,
    stopAll: () async {
      await Nearby().stopAdvertising();
      await Nearby().stopAllEndpoints();
    },
  );

  bool get isAdvertising => _adv.advertising;

  /// True when the runtime permissions Nearby Connections needs are granted.
  /// Does not prompt: the foreground-service isolate has no UI to show dialogs.
  static Future<bool> hasMeshPermissions() async {
    try {
      if (!await Permission.location.isGranted) return false;
      final modern = await Permission.bluetoothScan.isGranted &&
          await Permission.bluetoothAdvertise.isGranted &&
          await Permission.bluetoothConnect.isGranted;
      return modern || await Permission.bluetooth.isGranted;
    } catch (_) {
      return false;
    }
  }

  /// Starts offering [packet] to nearby peers. Returns true when advertising
  /// is running (delivery to a peer cannot be confirmed here).
  Future<bool> broadcast(SosPacket packet) async {
    try {
      if (!await hasMeshPermissions()) {
        debugPrint('Mesh relay: Bluetooth/Location permission missing.');
        DiagnosticsHub.instance.relayUnavailableReason =
            'Bluetooth / Nearby / Location permission missing';
        return false;
      }

      DiagnosticsHub.instance.relayEvent(
          'Offering ${packet.id} (hop ${packet.hop}, ${packet.source})');
      _active[packet.id] = packet;
      _expiry[packet.id]?.cancel();
      _expiry[packet.id] = Timer(offerWindow, () => _expire(packet.id));

      final started = await _adv.ensureStarted();
      DiagnosticsHub.instance.advertising = started;
      DiagnosticsHub.instance.relayUnavailableReason =
          started ? null : 'advertising could not start';
      DiagnosticsHub.instance.relayEvent(
          started ? 'Advertising SOS to nearby phones' : 'Advertising failed');
      debugPrint('Mesh relay advertising: $started');
      return started;
    } catch (e) {
      debugPrint('Mesh relay error: $e');
      DiagnosticsHub.instance.relayUnavailableReason = 'Nearby error: $e';
      return false;
    }
  }

  Future<bool> _startAdvertising() {
    return Nearby().startAdvertising(
      'GUARDIAN_SOS',
      strategy,
      onConnectionInitiated: (String id, ConnectionInfo info) async {
        try {
          await Nearby().acceptConnection(
            id,
            onPayLoadRecieved: (String endpointId, Payload payload) =>
                _onPayload(payload),
            onPayloadTransferUpdate:
                (String endpointId, PayloadTransferUpdate update) {},
          );
        } catch (e) {
          debugPrint('Mesh relay accept failed: $e');
        }
      },
      onConnectionResult: (String id, Status status) {
        if (status == Status.CONNECTED) {
          DiagnosticsHub.instance.connectedPeers++;
          DiagnosticsHub.instance.relayEvent('Peer connected (sender side)');
          _sendAll(id);
        }
      },
      onDisconnected: (String id) {
        final h = DiagnosticsHub.instance;
        if (h.connectedPeers > 0) h.connectedPeers--;
        debugPrint('Mesh relay peer disconnected: $id');
      },
      serviceId: serviceId,
    );
  }

  /// Beacons from helper phones are accepted only while an SOS of ours is
  /// being offered, and only after validation.
  void _onPayload(Payload payload) {
    final bytes = payload.bytes;
    if (payload.type != PayloadType.BYTES || bytes == null) return;
    if (_active.isEmpty) return;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final b = parseBeacon(utf8.decode(bytes), now);
      if (b == null) return;
      if (!_beaconSeen.add(b.dedupeKey)) return;
      if (_beaconSeen.length > 50) _beaconSeen.remove(_beaconSeen.first);
      // The service isolate owns PDR; whether the beacon is used shows up in
      // its Diagnostics snapshot ("Last anchor").
      DiagnosticsHub.instance.forwardAnchor(b);
      DiagnosticsHub.instance.relayEvent('Anchor beacon received, passed to PDR');
    } catch (e) {
      debugPrint('Mesh relay beacon handling failed: $e');
    }
  }

  void _sendAll(String endpointId) {
    for (final packet in _active.values) {
      try {
        Nearby().sendBytesPayload(
          endpointId,
          Uint8List.fromList(utf8.encode(jsonEncode(packet.toJson()))),
        );
        DiagnosticsHub.instance.sent++;
        DiagnosticsHub.instance.relayEvent('Sent ${packet.id} to a peer');
      } catch (e) {
        debugPrint('Mesh relay send failed: $e');
      }
    }
    // Free the slot for the next peer once the bytes have been handed over.
    Timer(holdConnection, () {
      try {
        Nearby().disconnectFromEndpoint(endpointId);
      } catch (_) {}
    });
  }

  void _expire(String id) {
    _active.remove(id);
    _expiry.remove(id)?.cancel();
    if (_active.isEmpty) stopRelay();
  }

  /// SIMULATED: offers a clearly labelled test packet so the relay can be
  /// demonstrated without a real emergency. The receiver marks it as a test.
  Future<bool> sendTestPacket({double lat = 0, double lng = 0}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    return broadcast(SosPacket(
      id: 'test-${generateAlertId()}',
      lat: lat,
      lng: lng,
      source: lat == 0 && lng == 0 ? 'unknown' : 'gps',
      uncertaintyM: 0,
      timestampMs: now,
      message: 'SIMULATED TEST SOS (not a real emergency)',
    ));
  }

  /// Stops advertising, e.g. when the SOS is cancelled. Also tries when the
  /// advertising state is uncertain (a start failed or is still running).
  Future<void> stopRelay() async {
    for (final t in _expiry.values) {
      t.cancel();
    }
    _expiry.clear();
    _active.clear();
    try {
      await _adv.stop();
    } catch (e) {
      debugPrint('Mesh relay stop failed: $e');
    }
    DiagnosticsHub.instance.advertising = _adv.advertising;
  }
}
