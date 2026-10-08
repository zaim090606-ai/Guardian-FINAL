import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';

import '../logic/sos_packet.dart';

/// Sender side of the offline mesh: advertises over Nearby Connections and
/// hands the SOS packet to every Guardian device that connects.
class RelayService {
  static final RelayService _instance = RelayService._internal();
  factory RelayService() => _instance;
  RelayService._internal();

  static const String serviceId = 'com.guardian.emergency.relay';
  static const Strategy strategy = Strategy.P2P_CLUSTER;

  /// How long a packet keeps being offered to new peers.
  static const Duration offerWindow = Duration(minutes: 5);

  final Map<String, SosPacket> _active = {};
  final Map<String, Timer> _expiry = {};
  bool _advertising = false;

  bool get isAdvertising => _advertising;

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
        return false;
      }

      _active[packet.id] = packet;
      _expiry[packet.id]?.cancel();
      _expiry[packet.id] = Timer(offerWindow, () => _expire(packet.id));

      if (_advertising) return true;

      final started = await Nearby().startAdvertising(
        'GUARDIAN_SOS',
        strategy,
        onConnectionInitiated: (String id, ConnectionInfo info) async {
          try {
            await Nearby().acceptConnection(
              id,
              onPayLoadRecieved: (String endpointId, Payload payload) {},
              onPayloadTransferUpdate:
                  (String endpointId, PayloadTransferUpdate update) {},
            );
          } catch (e) {
            debugPrint('Mesh relay accept failed: $e');
          }
        },
        onConnectionResult: (String id, Status status) {
          if (status == Status.CONNECTED) _sendAll(id);
        },
        onDisconnected: (String id) {
          debugPrint('Mesh relay peer disconnected: $id');
        },
        serviceId: serviceId,
      );

      _advertising = started;
      debugPrint('Mesh relay advertising: $started');
      return started;
    } catch (e) {
      debugPrint('Mesh relay error: $e');
      _advertising = false;
      return false;
    }
  }

  void _sendAll(String endpointId) {
    for (final packet in _active.values) {
      try {
        Nearby().sendBytesPayload(
          endpointId,
          Uint8List.fromList(utf8.encode(jsonEncode(packet.toJson()))),
        );
      } catch (e) {
        debugPrint('Mesh relay send failed: $e');
      }
    }
    // Free the slot for the next peer once the bytes have been handed over.
    Timer(const Duration(seconds: 5), () {
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

  /// Stops advertising, e.g. when the SOS is cancelled.
  Future<void> stopRelay() async {
    for (final t in _expiry.values) {
      t.cancel();
    }
    _expiry.clear();
    _active.clear();
    if (!_advertising) return;
    _advertising = false;
    try {
      await Nearby().stopAdvertising();
      await Nearby().stopAllEndpoints();
    } catch (e) {
      debugPrint('Mesh relay stop failed: $e');
    }
  }
}
