import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart'; // Required for permissions

class MeshReceiverService {
  static final MeshReceiverService _instance = MeshReceiverService._internal();
  factory MeshReceiverService() => _instance;
  
  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  MeshReceiverService._internal() {
    // FIX 6: Initialize notifications so .show() doesn't crash
    _initNotifications(); 
  }

  static const String _serviceId = "com.guardian.emergency.relay";
  static const Strategy _strategy = Strategy.P2P_CLUSTER;
  bool _isDiscovering = false;

  final Set<String> _processedAlerts = {};

  Future<void> _initNotifications() async {
    const AndroidInitializationSettings initSettingsAndroid =
        AndroidInitializationSettings('@mipmap/ic_launcher');
    const InitializationSettings initSettings =
        InitializationSettings(android: initSettingsAndroid);
    await _notificationsPlugin.initialize(settings: initSettings);
  }

  Future<void> startEmergencyListener() async {
    if (_isDiscovering) return;

    try {
      // FIX 3: Replaced the removed Nearby() permission methods with permission_handler
      bool locationGranted = await Permission.location.isGranted;
      bool bluetoothGranted = await Permission.bluetooth.isGranted;

      if (!locationGranted || !bluetoothGranted) {
        debugPrint("⚠️ Bluetooth/Location permissions not granted.");
        return;
      }

      _isDiscovering = await Nearby().startDiscovery(
        "GUARDIAN_RELAY_NODE",
        _strategy,
        // FIX 4: Corrected parameter order (endpointName before serviceId)
        onEndpointFound: (String endpointId, String endpointName, String serviceId) async {
          debugPrint("📡 Node Discovered: $endpointName ($endpointId)");

          await Nearby().requestConnection(
            "GUARDIAN_RELAY_NODE",
            endpointId,
            onConnectionInitiated: (String id, ConnectionInfo info) async {
              await Nearby().acceptConnection(
                id,
                // FIX 1: Spelled exactly how it is misspelled in the plugin source
                onPayLoadRecieved: (String endpointId, Payload payload) {
                  if (payload.type == PayloadType.BYTES && payload.bytes != null) {
                    _processIncomingPayload(payload.bytes!);
                  }
                },
                // FIX 2: Added the now-required transfer update callback
                onPayloadTransferUpdate: (String endpointId, PayloadTransferUpdate update) {
                  // Leave empty if you don't need transfer progress bars
                },
              );
            },
            onConnectionResult: (String id, Status status) {
              debugPrint("🔗 Mesh Status for $id:$status");
            },
            onDisconnected: (String id) {
              debugPrint("🔌 Disconnected from SOS Node $id");
            },
          );
        },
        // FIX 5: Removed the `?` making it a non-nullable String
        onEndpointLost: (String? endpointId) {
  debugPrint("📡 Lost contact with node $endpointId");
},
        serviceId: _serviceId,
      );
    } catch (e) {
      debugPrint("❌ Error: $e");
    }
  }

  Future<void> _processIncomingPayload(List<int> bytes) async {
    try {
      String jsonString = utf8.decode(bytes);
      // Added `as Map<String, dynamic>` to prevent Dart 3 strict-type casting errors
      Map<String, dynamic> data = jsonDecode(jsonString) as Map<String, dynamic>;

      String alertId = data['alertId'] ?? '';
      double lat = (data['lat'] as num?)?.toDouble() ?? 0.0;
      double lng = (data['lng'] as num?)?.toDouble() ?? 0.0;
      String message = data['message'] ?? '';
      int timestamp = data['timestamp'] ?? DateTime.now().millisecondsSinceEpoch;

      if (alertId.isNotEmpty && _processedAlerts.contains(alertId)) {
        return; // Skip duplicate
      }
      if (alertId.isNotEmpty) {
        _processedAlerts.add(alertId);
      }

      await FirebaseFirestore.instance
          .collection('emergency_logs')
          .doc(alertId)
          .set({
        'relayedByMesh': true,
        'relayedAt': FieldValue.serverTimestamp(),
        'originTimestamp': Timestamp.fromMillisecondsSinceEpoch(timestamp),
        'latitude': lat,
        'longitude': lng,
        'alertMessage': message,
        'status': 'mesh_relayed',
      }, SetOptions(merge: true));

      await _showRelayNotification(alertId);
    } catch (e) {
      debugPrint("❌ Failed to process payload: $e");
    }
  }

  Future<void> _showRelayNotification(String alertId) async {
    const AndroidNotificationDetails androidDetails =
        AndroidNotificationDetails(
      'guardian_mesh_alerts',
      'Mesh Emergency Relays',
      importance: Importance.high,
      priority: Priority.high,
    );

    const NotificationDetails notificationDetails =
        NotificationDetails(android: androidDetails);

    await _notificationsPlugin.show(
  id: alertId.hashCode,
  title: 'Emergency Signal Relayed',
  body: 'Your device successfully captured and relayed a peer SOS beacon.',
  notificationDetails: notificationDetails,
);
  }

  Future<void> stopListener() async {
    if (_isDiscovering) {
      await Nearby().stopDiscovery();
      _isDiscovering = false;
    }
  }
}