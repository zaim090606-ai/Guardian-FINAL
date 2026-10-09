import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import '../logic/anchor_beacon.dart';
import '../logic/countdown.dart';
import '../logic/pdr_snapshot.dart';
import 'pdr_services.dart';

/// Live counters for the Diagnostics screen. Relay counters are measured in
/// the UI isolate (Nearby Connections needs the Activity). The audio and PDR
/// engines run in the foreground-service isolate, which publishes a snapshot
/// every two seconds; the UI isolate listens and shows the latest one.
class DiagnosticsHub {
  static final DiagnosticsHub instance = DiagnosticsHub._();
  DiagnosticsHub._();

  /// Latest snapshot received from the service isolate (UI side).
  static final ValueNotifier<Map<String, dynamic>> remote =
      ValueNotifier<Map<String, dynamic>>(const {});

  /// UI isolate: the PDR snapshot the service published last, or null.
  static PdrSnapshot? pdrSnapshot() => PdrSnapshot.fromJson(remote.value['pdr']);

  /// Features switched off because a permission was denied, and numbers the
  /// SMS channel skipped as invalid (UI isolate).
  static final ValueNotifier<List<String>> permissionIssues =
      ValueNotifier<List<String>>(const []);
  static final ValueNotifier<List<String>> skippedNumbers =
      ValueNotifier<List<String>>(const []);

  final EventLog relayEvents = EventLog(capacity: 10);

  bool advertising = false;
  bool discovering = false;
  int connectedPeers = 0;

  /// Why Nearby Connections could not start (UI isolate), or null.
  String? relayUnavailableReason;

  /// Only states that were measured: "connected" needs a counted peer.
  String get relayState => relayUnavailableReason != null &&
          !advertising &&
          !discovering &&
          connectedPeers == 0
      ? 'unavailable'
      : connectedPeers > 0
          ? 'connected'
          : advertising
              ? 'advertising'
              : discovering
                  ? 'discovering'
                  : 'idle';
  int peersFound = 0;
  int sent = 0;
  int received = 0;
  int queued = 0;
  int uploaded = 0;
  int pending = 0;

  bool yamnetLoaded = false;
  bool whisperLoaded = false;
  String micStatus = 'unknown';
  String lastLabel = '';
  double lastScore = 0;
  int lastDetectionMs = 0;

  Timer? _timer;

  /// UI isolate: hands a beacon received over Nearby to the PDR owner (the
  /// service isolate).
  void forwardAnchor(AnchorBeacon b) {
    try {
      FlutterBackgroundService().invoke('anchor_beacon',
          b.agedTo(DateTime.now().millisecondsSinceEpoch).toJson());
    } catch (_) {}
  }

  void relayEvent(String text) =>
      relayEvents.add(text, DateTime.now().millisecondsSinceEpoch);

  Map<String, dynamic> snapshot() => {
        'yamnetLoaded': yamnetLoaded,
        'whisperLoaded': whisperLoaded,
        'micStatus': micStatus,
        'lastLabel': lastLabel,
        'lastScore': lastScore,
        'lastDetectionMs': lastDetectionMs,
        'pdr': PdrService().snapshot().toJson(),
      };

  /// Service isolate: push snapshots to the UI.
  void startPublishing(ServiceInstance service) {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 2), (_) {
      try {
        service.invoke('diag', snapshot());
      } catch (_) {}
    });
  }

  /// UI isolate: listen for snapshots.
  static void listen() {
    try {
      FlutterBackgroundService().on('diag').listen((event) {
        if (event != null) remote.value = Map<String, dynamic>.from(event);
      });
    } catch (e) {
      debugPrint('Diagnostics listener unavailable: $e');
    }
  }
}
