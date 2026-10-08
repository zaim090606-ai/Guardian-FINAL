import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import '../logic/countdown.dart';

/// Live counters for the Diagnostics screen. The relay and audio engines run
/// in the foreground-service isolate, which publishes a snapshot every two
/// seconds; the UI isolate listens and shows the latest one.
class DiagnosticsHub {
  static final DiagnosticsHub instance = DiagnosticsHub._();
  DiagnosticsHub._();

  /// Latest snapshot received from the service isolate (UI side).
  static final ValueNotifier<Map<String, dynamic>> remote =
      ValueNotifier<Map<String, dynamic>>(const {});

  final EventLog relayEvents = EventLog(capacity: 10);

  bool advertising = false;
  bool discovering = false;
  int connectedPeers = 0;

  String get relayState => connectedPeers > 0
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

  void relayEvent(String text) =>
      relayEvents.add(text, DateTime.now().millisecondsSinceEpoch);

  Map<String, dynamic> snapshot() => {
        'relayState': relayState,
        'peersFound': peersFound,
        'sent': sent,
        'received': received,
        'queued': queued,
        'uploaded': uploaded,
        'pending': pending,
        'events': relayEvents.toJson(),
        'yamnetLoaded': yamnetLoaded,
        'whisperLoaded': whisperLoaded,
        'micStatus': micStatus,
        'lastLabel': lastLabel,
        'lastScore': lastScore,
        'lastDetectionMs': lastDetectionMs,
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
