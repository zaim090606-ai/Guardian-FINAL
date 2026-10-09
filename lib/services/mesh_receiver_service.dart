import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logic/relay_policy.dart';
import '../logic/sos_packet.dart';
import 'diagnostics_hub.dart';
import 'pdr_services.dart';
import 'relay_service.dart';

/// Receiver side of the mesh. Discovers Guardian devices that are advertising
/// an SOS, validates and de-duplicates what they send, uploads it to
/// Firestore when this device has internet, otherwise queues it (persisted)
/// and offers it to further peers until the hop limit is reached.
class MeshReceiverService {
  static final MeshReceiverService _instance = MeshReceiverService._internal();
  factory MeshReceiverService() => _instance;
  MeshReceiverService._internal();

  static const String _queueKey = 'mesh_pending_queue';
  static const int maxHops = 5;

  final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  bool _notificationsReady = false;

  late final RelayHandler _handler = RelayHandler(
    maxHops: maxHops,
    nowMs: () => DateTime.now().millisecondsSinceEpoch,
    upload: _uploadToFirestore,
    forward: (p) async {
      await RelayService().broadcast(p);
    },
  );

  final Set<String> _requested = {};
  StreamSubscription<List<ConnectivityResult>>? _connSub;
  Timer? _retryTimer;
  bool _isDiscovering = false;

  bool get isDiscovering => _isDiscovering;
  /// Marks a packet this device created as seen so it is never re-handled.
  void markOwnPacket(String id) {
    _handler.seen.markIfNew(id);
    _ownIds.add(id);
    unawaited(_persistOwnIds());
  }

  static const String _ownIdsKey = 'own_packet_ids';
  OwnPacketIds _ownIds = OwnPacketIds();

  Future<void> _restoreOwnIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      _ownIds = OwnPacketIds.decode(prefs.getString(_ownIdsKey));
      for (final id in _ownIds.ids) {
        _handler.seen.markIfNew(id);
      }
    } catch (e) {
      debugPrint('Own packet ids unreadable: $e');
    }
  }

  Future<void> _persistOwnIds() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_ownIdsKey, _ownIds.encode());
    } catch (_) {}
  }

  int get pendingCount => _handler.queue.length;

  /// Starts listening for peers. Safe to call repeatedly; does nothing (and
  /// never throws) when permissions are missing.
  Future<void> startEmergencyListener() async {
    if (_isDiscovering) return;
    try {
      await _initNotifications();
      await _restoreQueue();
      await _restoreOwnIds();
      _startRetryLoop();

      if (!await RelayService.hasMeshPermissions()) {
        debugPrint('Mesh receiver: Bluetooth/Location permission missing.');
        DiagnosticsHub.instance.relayUnavailableReason =
            'Bluetooth / Nearby / Location permission missing';
        return;
      }

      _isDiscovering = await Nearby().startDiscovery(
        'GUARDIAN_RELAY_NODE',
        RelayService.strategy,
        onEndpointFound:
            (String endpointId, String endpointName, String serviceId) {
          DiagnosticsHub.instance.peersFound++;
          DiagnosticsHub.instance.relayEvent('Found peer $endpointName');
          _connectTo(endpointId);
        },
        onEndpointLost: (String? endpointId) {
          if (endpointId != null) _requested.remove(endpointId);
        },
        serviceId: RelayService.serviceId,
      );
      DiagnosticsHub.instance.discovering = _isDiscovering;
      if (_isDiscovering) {
        DiagnosticsHub.instance.relayUnavailableReason = null;
      } else {
        DiagnosticsHub.instance.relayUnavailableReason =
            'discovery could not start';
      }
      DiagnosticsHub.instance.relayEvent(_isDiscovering
          ? 'Discovering nearby SOS senders'
          : 'Discovery could not start');
      debugPrint('Mesh receiver discovering: $_isDiscovering');
    } catch (e) {
      _isDiscovering = false;
      DiagnosticsHub.instance.relayUnavailableReason = 'Nearby error: $e';
      debugPrint('Mesh receiver failed to start: $e');
    }
  }

  Future<void> _connectTo(String endpointId) async {
    if (!_requested.add(endpointId)) return;
    try {
      await Nearby().requestConnection(
        'GUARDIAN_RELAY_NODE',
        endpointId,
        onConnectionInitiated: (String id, ConnectionInfo info) async {
          await Nearby().acceptConnection(
            id,
            onPayLoadRecieved: (String from, Payload payload) {
              final bytes = payload.bytes;
              if (payload.type == PayloadType.BYTES && bytes != null) {
                _onPayload(bytes);
              }
            },
            onPayloadTransferUpdate:
                (String from, PayloadTransferUpdate update) {},
          );
        },
        onConnectionResult: (String id, Status status) {
          if (status == Status.CONNECTED) {
            DiagnosticsHub.instance.connectedPeers++;
            _sendBeacon(id);
          } else {
            _requested.remove(endpointId);
          }
        },
        onDisconnected: (String id) {
          final h = DiagnosticsHub.instance;
          if (h.connectedPeers > 0) h.connectedPeers--;
          _requested.remove(endpointId);
        },
      );
    } catch (e) {
      _requested.remove(endpointId);
      debugPrint('Mesh receiver connect failed: $e');
    }
  }

  /// Replies to an SOS sender with this phone's position, but only when it has
  /// a real, accurate, fresh GPS fix and is not simulating GPS loss.
  void _sendBeacon(String endpointId) {
    try {
      final b = PdrService().beaconForSharing();
      if (b == null) {
        DiagnosticsHub.instance.relayEvent('No anchor beacon offered (no good GPS fix)');
        return;
      }
      Nearby().sendBytesPayload(
          endpointId, Uint8List.fromList(utf8.encode(jsonEncode(b.toJson()))));
      DiagnosticsHub.instance.relayEvent('Offered an anchor beacon to the sender');
    } catch (e) {
      debugPrint('Mesh receiver beacon failed: $e');
    }
  }

  Future<void> _onPayload(List<int> bytes) async {
    try {
      final h = DiagnosticsHub.instance;
      h.received++;
      final outcome = await _handler.handleRaw(utf8.decode(bytes));
      switch (outcome) {
        case RelayOutcome.uploaded:
          h.uploaded++;
        case RelayOutcome.queued:
          h.queued++;
        case RelayOutcome.invalid:
        case RelayOutcome.duplicate:
          break;
      }
      h.pending = _handler.queue.length;
      h.relayEvent('Received packet: ${outcome.name}');
      debugPrint('Mesh payload outcome: $outcome');
      if (outcome == RelayOutcome.uploaded || outcome == RelayOutcome.queued) {
        await _persistQueue();
        await _notify(outcome == RelayOutcome.uploaded);
      }
    } catch (e) {
      debugPrint('Mesh payload handling failed: $e');
    }
  }

  /// True only when the packet is confirmed stored in Firestore. Needs
  /// internet: a transaction cannot complete offline.
  Future<bool> _uploadToFirestore(SosPacket p) async {
    final conn = await Connectivity().checkConnectivity();
    if (conn.contains(ConnectivityResult.none)) return false;
    try {
      final ref = FirebaseFirestore.instance.collection('emergency_logs').doc(p.id);
      await FirebaseFirestore.instance.runTransaction((tx) async {
        final snap = await tx.get(ref);
        final relayInfo = {
          'relayedByMesh': true,
          'relayedAt': FieldValue.serverTimestamp(),
          'relayHop': p.hop,
        };
        if (snap.exists) {
          // The origin already uploaded this alert; only note the relay.
          tx.update(ref, relayInfo);
        } else {
          tx.set(ref, {
            ...relayInfo,
            'latitude': p.lat,
            'longitude': p.lng,
            'locationSource': p.source,
            'locationUncertaintyM': p.uncertaintyM,
            'isDeadReckoning': p.source == 'estimated',
            'originTimestamp': Timestamp.fromMillisecondsSinceEpoch(p.timestampMs),
            'alertMessage': p.message,
            'status': p.id.startsWith('test-') ? 'test' : 'mesh_relayed',
            'riskLevel': p.id.startsWith('test-') ? 'TEST' : 'HIGH',
            'eventType': 'mesh_relay',
            'simulated': p.id.startsWith('test-'),
          });
        }
      }).timeout(const Duration(seconds: 10));
      return true;
    } catch (e) {
      debugPrint('Mesh upload failed (will retry): $e');
      return false;
    }
  }

  void _startRetryLoop() {
    _connSub ??= Connectivity().onConnectivityChanged.listen((results) {
      if (!results.contains(ConnectivityResult.none)) _flush();
    });
    _retryTimer ??= Timer.periodic(const Duration(seconds: 60), (_) => _flush());
  }

  Future<void> _flush() async {
    if (_handler.queue.length == 0) return;
    final n = await _handler.flush();
    if (n > 0) {
      DiagnosticsHub.instance.uploaded += n;
      DiagnosticsHub.instance.pending = _handler.queue.length;
      DiagnosticsHub.instance.relayEvent('Retry uploaded $n queued alert(s)');
      debugPrint('Mesh queue: uploaded $n queued alert(s).');
      await _persistQueue();
    }
  }

  Future<void> _restoreQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final restored = PacketQueue.decode(prefs.getString(_queueKey));
      for (final p in restored.items) {
        _handler.queue.add(p);
        _handler.seen.markIfNew(p.id);
      }
    } catch (e) {
      debugPrint('Mesh queue restore failed: $e');
    }
  }

  Future<void> _persistQueue() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_queueKey, _handler.queue.encode());
    } catch (e) {
      debugPrint('Mesh queue persist failed: $e');
    }
  }

  Future<void> _initNotifications() async {
    if (_notificationsReady) return;
    try {
      await _notifications.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      _notificationsReady = true;
    } catch (e) {
      debugPrint('Mesh notifications unavailable: $e');
    }
  }

  Future<void> _notify(bool uploaded) async {
    if (!_notificationsReady) return;
    try {
      await _notifications.show(
        id: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title: 'Emergency signal received',
        body: uploaded
            ? 'A nearby SOS was relayed to the cloud.'
            : 'A nearby SOS was stored and will be sent when you are online.',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'guardian_mesh_alerts',
            'Mesh Emergency Relays',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    } catch (e) {
      debugPrint('Mesh notification failed: $e');
    }
  }

  Future<void> stopListener() async {
    _retryTimer?.cancel();
    _retryTimer = null;
    await _connSub?.cancel();
    _connSub = null;
    if (_isDiscovering) {
      try {
        await Nearby().stopDiscovery();
      } catch (_) {}
      _isDiscovering = false;
      DiagnosticsHub.instance.discovering = false;
    }
    _requested.clear();
  }
}
