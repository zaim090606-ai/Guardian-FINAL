import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart'; // add this import

class RelayService {
  static final RelayService _instance = RelayService._internal();
  factory RelayService() => _instance;
  RelayService._internal();

  static const String _serviceId = "com.guardian.emergency.relay";
  static const Strategy _strategy = Strategy.P2P_CLUSTER;
  bool _isBroadcasting = false;

  /// Broadcast SOS packet to all neighboring devices running Guardian
  Future<bool> broadcastEmergencyPacket({
    required String alertId,
    required double lat,
    required double lng,
    required String message,
  }) async {
    try {
      // Check location & bluetooth permissions required for P2P connection
      bool locationGranted = await Permission.location.isGranted;
bool bluetoothGranted = await Permission.bluetooth.isGranted;

if (!locationGranted || !bluetoothGranted) {
  await Permission.location.request();
  await Permission.bluetooth.request();
}
      String userName = "GUARDIAN_NODE_${alertId.substring(0, 5)}";
      
      Map<String, dynamic> payloadMap = {
        'alertId': alertId,
        'lat': lat,
        'lng': lng,
        'message': message,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      String payloadString = jsonEncode(payloadMap);

      // Start Advertising as an Emergency SOS Node
      bool advertisingStarted = await Nearby().startAdvertising(
        userName,
        _strategy,
        onConnectionInitiated: (String id, ConnectionInfo info) async {
          // Auto-accept incoming relay connection
          await Nearby().acceptConnection(
            id,
            onPayLoadRecieved: (String endpointId, Payload payload) {
  debugPrint("📥 Received Mesh Relay response from $endpointId");
},
          );
        },
        onConnectionResult: (String id, Status status) {
          if (status == Status.CONNECTED) {
            // Instantly transmit the emergency payload upon peer discovery
            Nearby().sendBytesPayload(
              id,
              Uint8List.fromList(utf8.encode(payloadString)),
            );
            debugPrint("📡 Emergency Payload broadcasted to peer: $id");
          }
        },
        onDisconnected: (String id) {
          debugPrint("🔌 Disconnected from mesh peer: $id");
        },
        serviceId: _serviceId,
      );

      _isBroadcasting = advertisingStarted;
      debugPrint("📡 Emergency Mesh Relay Active: $advertisingStarted");
      return advertisingStarted;
    } catch (e) {
      debugPrint("❌ Mesh Relay Error: $e");
      return false;
    }
  }

  /// Stop advertising when SOS is canceled or network connection is restored
  Future<void> stopRelay() async {
    if (_isBroadcasting) {
      await Nearby().stopAdvertising();
      await Nearby().stopAllEndpoints();
      _isBroadcasting = false;
      debugPrint("🛑 Mesh Relay Stopped.");
    }
  }
}