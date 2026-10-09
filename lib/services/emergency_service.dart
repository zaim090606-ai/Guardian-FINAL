import 'dart:async';
import 'dart:convert';

import 'package:background_sms/background_sms.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logic/pdr_engine.dart';
import '../logic/sos_dispatcher.dart';
import '../logic/sos_guard.dart';
import '../logic/sos_packet.dart';
import 'ai_service.dart';
import 'audio_recorder_service.dart';
import 'pdr_services.dart';
import 'mesh_receiver_service.dart';
import 'prefs_kv.dart';
import 'relay_service.dart';

/// Turns a trigger (impact, voice, sound, button) into an SOS.
///
/// No single path is required: the Firestore upload, the SMS to contacts and
/// the offline mesh relay each run on their own and each failure is contained
/// and logged (see [SosDispatcher]).
class EmergencyService {
  static const String _contactKey = 'emergency_contact_number';
  static const String _cloudContactsKey = 'cloud_contacts_cache';
  static const String _attemptLogKey = 'sos_attempt_log';
  /// Hosting site of the Firebase project the app writes to (guardian-b7926).
  static const String _trackingBase = 'https://guardian-b7926.web.app';
  static const MethodChannel _smsChannel = MethodChannel('com.guardian.app/sms');

  /// How the mesh channel hands a packet to the relay. In the UI isolate
  /// (default) it advertises directly. The service isolate replaces it with a
  /// bridge, because Nearby Connections only works with an Activity.
  static Future<bool> Function(SosPacket) meshOffer = (packet) {
    // Our own packet must never be processed again if it bounces back.
    MeshReceiverService().markOwnPacket(packet.id);
    return RelayService().broadcast(packet);
  };

  /// Best location available right now, without waiting for a new GPS read.
  static Future<LocationFix?> Function() locationNow = _defaultLocationNow;

  /// Persisted "SOS active" record shared by both isolates.
  static final SosGuard guard = SosGuard(PrefsKeyValueStore());
  static SosSession _session = SosSession(guard);

  static String? _activeId;
  static Timer? _liveTimer;
  static Timer? _liveStop;

  /// Attaches an AI summary to the alert that is currently active, if any.
  static void updateIncidentContext(String summary) {
    final id = _activeId;
    if (id == null || summary.trim().isEmpty) return;
    unawaited(_mergeIntoDoc(id, {'aiSummary': summary.trim()}));
  }

  @pragma('vm:entry-point')
  static Future<void> triggerEmergencyDispatch({
    required double force,
    required String level,
    String audioTranscript = '',
  }) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final started = await guard.begin(generateAlertId(), now);
    if (!started.isNew) {
      debugPrint('[GUARDIAN_LOG] SOS ${started.id} already active; '
          'trigger "$level" sends nothing new.');
      return;
    }

    final docId = started.id;
    bool dispatched = false;
    try {
      _activeId = docId;
      _session = SosSession(guard);
      _session.onCancel(_stopTimers);
      _session.onCancel(() => unawaited(RelayService().stopRelay()));
      debugPrint('[GUARDIAN_LOG] SOS $docId triggered: $level (force $force)');

      // Nothing below this line waits for the network before the SMS starts.
      final LocationFix? fix = await locationNow();
      final lat = fix?.lat ?? 0.0;
      final lng = fix?.lng ?? 0.0;
      final source = fix?.source ?? 'unknown';
      final uncertainty = fix?.uncertaintyM ?? 0.0;
      final fixAgeS = fix?.ageSinceGpsS;
      final simulated = await _simulatedNow();

      final contacts = await _loadContactsFast();
      unawaited(refreshCloudContacts());
      final micGranted = await Permission.microphone.isGranted;

      final text = buildSosText(
        trackingUrl: buildTrackingUrl(_trackingBase, docId),
        lat: lat,
        lng: lng,
        source: source,
        uncertaintyM: uncertainty,
        trigger: level,
        simulated: simulated,
        fixAgeS: fixAgeS,
      );

      final packet = SosPacket(
        id: docId,
        lat: lat,
        lng: lng,
        source: source,
        uncertaintyM: uncertainty,
        timestampMs: DateTime.now().millisecondsSinceEpoch,
        message: text,
      );

      Map<String, dynamic> docData() {
        // Firebase objects are touched only here, inside the cloud channel.
        final user = FirebaseAuth.instance.currentUser;
        return <String, dynamic>{
          'userId': user?.uid ?? 'anonymous',
          'userPhone': user?.phoneNumber ?? 'unknown',
          'eventType': audioTranscript.isNotEmpty ? 'voice_trigger' : 'sensor_trigger',
          'riskLevel': level,
          'force': force,
          'transcript': audioTranscript,
          'alertMessage': text,
          'latitude': lat,
          'longitude': lng,
          'locationSource': source,
          'locationUncertaintyM': uncertainty,
          'isDeadReckoning': source == 'estimated',
          'locationFixTimeMs': fix?.timeMs,
          'locationAgeS': fixAgeS,
          'locationContext': fix?.context ?? '',
          'anchorUsed': fix?.anchorUsed ?? false,
          'anchorAgeS': fix?.anchorAgeS,
          'anchorRadiusM': fix?.anchorRadiusM,
          'locationSimulated': simulated,
          'status': 'triggered',
          'audioStatus': micGranted ? 'processing' : 'unavailable',
          'audioUrl': null,
          'timestamp': FieldValue.serverTimestamp(),
        };
      }

      final dispatcher = SosDispatcher(onAttempt: (a) => _recordAttempt(docId, a));
      final attempts = await dispatcher.dispatch(
        sosId: docId,
        cloud: () => _uploadAlert(docId, docData),
        sms: () => _sendSms(text, contacts),
        mesh: () => meshOffer(packet),
      );
      dispatched = attempts.any((a) => a.ok);
      debugPrint('[GUARDIAN_LOG] SOS $docId result: '
          '${attempts.map((a) => "${a.channel}=${a.ok ? "ok" : "fail"}").join(", ")}');

      // Everything below is best effort and never delays the alert itself.
      _startLiveTracking(docId);
      unawaited(_refineLocation(docId, fix));
      if (micGranted) {
        unawaited(_captureEvidence(docId, contacts));
      }
      unawaited(_enrichWithAi(
        docId,
        force: force,
        lat: lat,
        lng: lng,
        transcript: audioTranscript,
        level: level,
      ));
    } catch (e) {
      debugPrint('Error during emergency dispatch: $e');
    } finally {
      // No channel worked: free the guard so the user can try again.
      if (!dispatched) await stopLocal();
    }
  }

  // ------------------------------------------------------------------ cancel

  /// UI isolate: cancels the SOS here and tells the service isolate to do the
  /// same (`cancel_sos` reaches both isolates).
  static Future<void> cancelSos() async {
    await stopLocal();
    try {
      FlutterBackgroundService().invoke('cancel_sos');
    } catch (_) {}
  }

  /// Stops this isolate's tracking timers, Firestore location writes and relay
  /// advertising, and clears the persisted guard. Safe to call repeatedly.
  static Future<void> stopLocal() async {
    _stopTimers();
    _activeId = null;
    await _session.cancel();
    debugPrint('Live tracking and mesh relay stopped.');
  }

  static Future<void> stopLiveTracking() => stopLocal();

  static void _stopTimers() {
    _liveTimer?.cancel();
    _liveStop?.cancel();
    _liveTimer = null;
    _liveStop = null;
  }

  // ---------------------------------------------------------------- channels

  /// Cloud channel. Offline, the write is still handed to Firestore's local
  /// queue so the alert appears once the phone reconnects, but the channel
  /// reports failure at once so the mesh relay starts without waiting.
  static Future<bool> _uploadAlert(
    String docId,
    Map<String, dynamic> Function() buildData,
  ) async {
    final data = buildData();
    final conn = await Connectivity().checkConnectivity();
    if (conn.contains(ConnectivityResult.none)) {
      unawaited(_mergeIntoDoc(docId, data));
      throw StateError('no network connection (write queued locally)');
    }
    await FirebaseFirestore.instance
        .collection('emergency_logs')
        .doc(docId)
        .set(data, SetOptions(merge: true));
    return true;
  }

  /// SMS channel: native multipart first, background_sms as backup. Succeeds
  /// when at least one recipient got the message.
  static Future<bool> _sendSms(String message, List<String> recipients) async {
    if (recipients.isEmpty) {
      throw StateError('no emergency contacts saved');
    }

    var status = await Permission.sms.status;
    if (!status.isGranted) {
      status = await Permission.sms
          .request()
          .timeout(const Duration(seconds: 5), onTimeout: () => status);
    }
    if (!status.isGranted) {
      throw StateError('SMS permission not granted');
    }

    bool anySent = false;
    for (final number in recipients) {
      bool sent = false;
      try {
        sent = await _smsChannel.invokeMethod<bool>('sendMultipartSms', {
              'phoneNumber': number,
              'message': message,
            }) ??
            false;
      } catch (e) {
        // The native channel only exists in the UI engine; the service
        // isolate lands here and uses the plugin instead.
        debugPrint('Native SMS unavailable for $number ($e), using plugin.');
      }
      if (!sent) {
        try {
          final r = await BackgroundSms.sendMessage(
            phoneNumber: number,
            message: message,
          );
          sent = r == SmsStatus.sent;
        } catch (e) {
          debugPrint('Plugin SMS failed for $number: $e');
        }
      }
      anySent = anySent || sent;
    }
    return anySent;
  }

  // ---------------------------------------------------------------- location

  static Future<bool> _simulatedNow() async {
    try {
      return PdrService().simulateGpsLoss;
    } catch (_) {
      return false;
    }
  }

  /// The PDR estimate if there is one, otherwise the stored last real fix.
  static Future<LocationFix?> _defaultLocationNow() async {
    final pdr = PdrService();
    final fix = pdr.currentFix();
    if (fix != null) return fix;
    if (pdr.simulateGpsLoss) return null;
    return PdrService.loadLastKnown();
  }

  /// After the alert is out, tries for a fresh GPS reading (3 s) and updates
  /// the cloud document if it is better than what was sent.
  static Future<void> _refineLocation(String docId, LocationFix? sent) async {
    try {
      if (await _simulatedNow()) return;
      if (sent != null && sent.source == 'gps' && sent.ageSinceGpsS < 10) return;
      if (!await Geolocator.isLocationServiceEnabled()) return;
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return;
      }
      final p = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 3),
        ),
      );
      if (_activeId != docId) return;
      await _mergeIntoDoc(docId, {
        'latitude': p.latitude,
        'longitude': p.longitude,
        'locationSource': 'gps',
        'locationUncertaintyM': p.accuracy,
        'isDeadReckoning': false,
        'locationFixTimeMs': p.timestamp.millisecondsSinceEpoch,
        'locationAgeS': 0,
      });
    } catch (e) {
      debugPrint('Location refinement skipped: $e');
    }
  }

  // ----------------------------------------------------------- live tracking

  static void _startLiveTracking(String docId) {
    _stopTimers();
    _liveTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      final fix = await locationNow();
      if (fix == null) return;
      final simulated = await _simulatedNow();
      unawaited(_mergeIntoDoc(docId, {
        'latitude': fix.lat,
        'longitude': fix.lng,
        'locationSource': fix.source,
        'locationUncertaintyM': fix.uncertaintyM,
        'isDeadReckoning': fix.source == 'estimated',
        'locationFixTimeMs': fix.timeMs,
        'locationAgeS': fix.ageSinceGpsS,
        'locationContext': fix.context,
        'anchorUsed': fix.anchorUsed,
        'anchorAgeS': fix.anchorAgeS,
        'anchorRadiusM': fix.anchorRadiusM,
        'locationSimulated': simulated,
        'lastLiveUpdate': FieldValue.serverTimestamp(),
      }));
    });
    _liveStop = Timer(const Duration(hours: 1), () => unawaited(stopLocal()));
  }

  // ---------------------------------------------------------------- evidence

  static Future<void> _captureEvidence(
    String docId,
    List<String> contacts,
  ) async {
    try {
      final path = await AudioRecorderService.captureEmergencyAudio(durationSeconds: 30);
      if (path == null) {
        await _mergeIntoDoc(docId, {'audioStatus': 'failed'});
        return;
      }

      String analysis = '';
      try {
        analysis = await AIService.analyzeAudioEvidence(path)
            .timeout(const Duration(seconds: 90));
      } catch (e) {
        debugPrint('Audio analysis skipped: $e');
      }

      final url = await AudioRecorderService.uploadAudioToFirebase(path);
      await _mergeIntoDoc(docId, {
        'audioUrl': url,
        'audioStatus': url != null ? 'uploaded' : 'saved_locally',
        'audioAnalysis': analysis,
        'audioUploadedAt': FieldValue.serverTimestamp(),
      });

      if (analysis.isNotEmpty && contacts.isNotEmpty) {
        var clean = analysis.replaceAll('\n', ' ');
        if (clean.length > 140) clean = '${clean.substring(0, 137)}...';
        await _sendSms('Guardian audio update: $clean', contacts);
      }
    } catch (e) {
      debugPrint('Evidence capture failed: $e');
    }
  }

  /// Optional Gemini summary; skipped offline or without a key.
  static Future<void> _enrichWithAi(
    String docId, {
    required double force,
    required double lat,
    required double lng,
    required String transcript,
    required String level,
  }) async {
    if (!AIService.isConfigured) return;
    try {
      final conn = await Connectivity().checkConnectivity();
      if (conn.contains(ConnectivityResult.none)) return;
      final summary = await AIService.generateAlert(
        gForce: force,
        lat: lat,
        lng: lng,
        audioTranscript: transcript,
        level: level,
      ).timeout(const Duration(seconds: 15));
      if (summary != null) await _mergeIntoDoc(docId, {'aiSummary': summary});
    } catch (e) {
      debugPrint('AI summary skipped: $e');
    }
  }

  // ---------------------------------------------------------------- contacts

  /// Contacts from local storage only (the SharedPreferences list the Contacts
  /// screen writes, plus the last successful Firestore read). Never waits for
  /// the network. There is no built-in fallback number: with no contacts the
  /// SMS channel reports that clearly.
  static Future<List<String>> _loadContactsFast() async {
    final numbers = <String>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      for (final entry in prefs.getStringList('emergency_contacts') ?? const <String>[]) {
        numbers.add(extractPhone(entry));
      }
      final single = prefs.getString(_contactKey);
      if (single != null && single.isNotEmpty) numbers.add(normalizePhone(single));
      final cached = prefs.getString(_cloudContactsKey);
      if (cached != null && cached.isNotEmpty) {
        final list = jsonDecode(cached);
        if (list is List) {
          for (final n in list) {
            numbers.add(normalizePhone('$n'));
          }
        }
      }
    } catch (e) {
      debugPrint('Local contacts unreadable: $e');
    }
    return numbers.where((n) => n.isNotEmpty).toList();
  }

  /// Refreshes the local copy of the signed-in user's Firestore contacts.
  /// Runs in the background (3 s timeout) and never blocks the SMS.
  static Future<void> refreshCloudContacts() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .collection('contacts')
          .get()
          .timeout(const Duration(seconds: 3));
      final phones = <String>[
        for (final doc in snap.docs)
          if ((doc.data()['phone']?.toString() ?? '').isNotEmpty)
            normalizePhone(doc.data()['phone'].toString()),
      ];
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_cloudContactsKey, jsonEncode(phones));
    } catch (e) {
      debugPrint('Cloud contacts unavailable: $e');
    }
  }

  // ------------------------------------------------------------------ logging

  /// Every attempt is printed, appended to a local ring buffer (read it with
  /// [readAttemptLog]) and, when possible, to the alert document.
  static Future<void> _recordAttempt(
    String docId,
    SosAttempt a,
  ) async {
    debugPrint('[GUARDIAN_LOG] $a');
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final log = AttemptLog.decode(prefs.getString(_attemptLogKey))..add(a);
      await prefs.setString(_attemptLogKey, log.encode());
    } catch (_) {}
    unawaited(_mergeIntoDoc(docId, {
      'sosAttempts': FieldValue.arrayUnion([
        {
          'channel': a.channel,
          'ok': a.ok,
          'detail': a.detail,
          'ms': a.elapsedMs,
          'at': a.tsMs,
        }
      ]),
    }));
  }

  /// Most recent send attempts, oldest first.
  static Future<List<SosAttempt>> readAttemptLog() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return AttemptLog.decode(prefs.getString(_attemptLogKey)).items;
  }

  static Future<void> _mergeIntoDoc(
    String docId,
    Map<String, dynamic> data,
  ) async {
    try {
      await FirebaseFirestore.instance
          .collection('emergency_logs')
          .doc(docId)
          .set(data, SetOptions(merge: true))
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('Firestore merge skipped: $e');
    }
  }
}
