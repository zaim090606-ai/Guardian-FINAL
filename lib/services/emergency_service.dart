import 'dart:async';

import 'package:background_sms/background_sms.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logic/pdr_engine.dart';
import '../logic/sos_dispatcher.dart';
import '../logic/sos_packet.dart';
import 'ai_service.dart';
import 'audio_recorder_service.dart';
import 'pdr_services.dart';
import 'relay_service.dart';

/// Turns a trigger (impact, voice, sound, button) into an SOS.
///
/// No single path is required: the Firestore upload, the SMS to contacts and
/// the offline mesh relay each run on their own and each failure is contained
/// and logged (see [SosDispatcher]).
class EmergencyService {
  static const String _contactKey = 'emergency_contact_number';
  static const String _attemptLogKey = 'sos_attempt_log';
  /// Hosting site of the Firebase project the app writes to (guardian-b7926).
  static const String _trackingBase = 'https://guardian-b7926.web.app';
  static const MethodChannel _smsChannel = MethodChannel('com.guardian.app/sms');

  static bool _isDispatching = false;
  static DocumentReference<Map<String, dynamic>>? _activeDoc;
  static Timer? _liveTimer;
  static Timer? _liveStop;

  /// Attaches an AI summary to the alert that is currently active, if any.
  static void updateIncidentContext(String summary) {
    final doc = _activeDoc;
    if (doc == null || summary.trim().isEmpty) return;
    unawaited(_mergeIntoDoc(doc, {'aiSummary': summary.trim()}));
  }

  @pragma('vm:entry-point')
  static Future<void> triggerEmergencyDispatch({
    required double force,
    required String level,
    String audioTranscript = '',
  }) async {
    if (_isDispatching) {
      debugPrint('Emergency dispatch already active. Suppressing duplicate trigger.');
      return;
    }

    _isDispatching = true;
    bool dispatched = false;
    try {
      final docRef = FirebaseFirestore.instance.collection('emergency_logs').doc();
      final docId = docRef.id;
      _activeDoc = docRef;
      debugPrint('[GUARDIAN_LOG] SOS $docId triggered: $level (force $force)');

      final LocationFix? fix = await _resolveLocation();
      final lat = fix?.lat ?? 0.0;
      final lng = fix?.lng ?? 0.0;
      final source = fix?.source ?? 'unknown';
      final uncertainty = fix?.uncertaintyM ?? 0.0;

      final contacts = await _loadContacts();
      final micGranted = await Permission.microphone.isGranted;

      final text = buildSosText(
        trackingUrl: buildTrackingUrl(_trackingBase, docId),
        lat: lat,
        lng: lng,
        source: source,
        uncertaintyM: uncertainty,
        trigger: level,
        simulated: PdrService().simulateGpsLoss,
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

      final user = FirebaseAuth.instance.currentUser;
      final docData = <String, dynamic>{
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
        'locationSimulated': PdrService().simulateGpsLoss,
        'status': 'triggered',
        'audioStatus': micGranted ? 'processing' : 'unavailable',
        'audioUrl': null,
        'timestamp': FieldValue.serverTimestamp(),
      };

      final dispatcher = SosDispatcher(onAttempt: (a) => _recordAttempt(docRef, a));
      final attempts = await dispatcher.dispatch(
        sosId: docId,
        cloud: () => _uploadAlert(docRef, docData),
        sms: () => _sendSms(text, contacts),
        mesh: () => RelayService().broadcast(packet),
      );
      dispatched = attempts.any((a) => a.ok);
      debugPrint('[GUARDIAN_LOG] SOS $docId result: '
          '${attempts.map((a) => "${a.channel}=${a.ok ? "ok" : "fail"}").join(", ")}');

      // Everything below is best effort and never delays the alert itself.
      _startLiveTracking(docRef);
      if (micGranted) {
        unawaited(_captureEvidence(docRef, contacts));
      }
      unawaited(_enrichWithAi(
        docRef,
        force: force,
        lat: lat,
        lng: lng,
        transcript: audioTranscript,
        level: level,
      ));
    } catch (e) {
      debugPrint('Error during emergency dispatch: $e');
    } finally {
      if (dispatched) {
        Future.delayed(const Duration(minutes: 2), () => _isDispatching = false);
      } else {
        _isDispatching = false;
      }
    }
  }

  // ---------------------------------------------------------------- channels

  /// Cloud channel. Offline, the write is still handed to Firestore's local
  /// queue so the alert appears once the phone reconnects, but the channel
  /// reports failure at once so the mesh relay starts without waiting.
  static Future<bool> _uploadAlert(
    DocumentReference<Map<String, dynamic>> docRef,
    Map<String, dynamic> data,
  ) async {
    final conn = await Connectivity().checkConnectivity();
    if (conn.contains(ConnectivityResult.none)) {
      unawaited(_mergeIntoDoc(docRef, data));
      throw StateError('no network connection (write queued locally)');
    }
    await docRef.set(data, SetOptions(merge: true));
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

  /// GPS if available, otherwise the dead-reckoned estimate from the PDR
  /// engine, otherwise the last known position.
  static Future<LocationFix?> _resolveLocation() async {
    final pdr = PdrService();
    try {
      if (!pdr.simulateGpsLoss && await Geolocator.isLocationServiceEnabled()) {
        final perm = await Geolocator.checkPermission();
        if (perm != LocationPermission.denied &&
            perm != LocationPermission.deniedForever) {
          final p = await Geolocator.getCurrentPosition(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              timeLimit: Duration(seconds: 3),
            ),
          );
          pdr.feedGps(p);
        }
      }
    } catch (e) {
      debugPrint('No fresh GPS fix: $e');
    }

    LocationFix? fix = pdr.currentFix();
    if (fix == null && !pdr.simulateGpsLoss) {
      fix = await PdrService.loadLastKnown();
    }
    if (fix == null && !pdr.simulateGpsLoss) {
      try {
        final last = await Geolocator.getLastKnownPosition();
        if (last != null) {
          pdr.feedGps(last);
          fix = pdr.currentFix();
        }
      } catch (_) {}
    }
    return fix;
  }

  // ----------------------------------------------------------- live tracking

  static void _startLiveTracking(DocumentReference<Map<String, dynamic>> docRef) {
    _liveTimer?.cancel();
    _liveStop?.cancel();
    _liveTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final fix = PdrService().currentFix();
      if (fix == null) return;
      unawaited(_mergeIntoDoc(docRef, {
        'latitude': fix.lat,
        'longitude': fix.lng,
        'locationSource': fix.source,
        'locationUncertaintyM': fix.uncertaintyM,
        'isDeadReckoning': fix.source == 'estimated',
        'locationSimulated': PdrService().simulateGpsLoss,
        'lastLiveUpdate': FieldValue.serverTimestamp(),
      }));
    });
    _liveStop = Timer(const Duration(hours: 1), () => stopLiveTracking());
  }

  static Future<void> stopLiveTracking() async {
    _liveTimer?.cancel();
    _liveStop?.cancel();
    _liveTimer = null;
    _liveStop = null;
    _activeDoc = null;
    debugPrint('Live tracking stopped.');
  }

  // ---------------------------------------------------------------- evidence

  static Future<void> _captureEvidence(
    DocumentReference<Map<String, dynamic>> docRef,
    List<String> contacts,
  ) async {
    try {
      final path = await AudioRecorderService.captureEmergencyAudio(durationSeconds: 30);
      if (path == null) {
        await _mergeIntoDoc(docRef, {'audioStatus': 'failed'});
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
      await _mergeIntoDoc(docRef, {
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
    DocumentReference<Map<String, dynamic>> docRef, {
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
      if (summary != null) await _mergeIntoDoc(docRef, {'aiSummary': summary});
    } catch (e) {
      debugPrint('AI summary skipped: $e');
    }
  }

  // ---------------------------------------------------------------- contacts

  /// Local contacts first (work offline), then the signed-in user's Firestore
  /// contacts if they can be read quickly. There is no built-in fallback
  /// number: with no contacts the SMS channel reports that clearly.
  static Future<List<String>> _loadContacts() async {
    final numbers = <String>{};

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      for (final entry in prefs.getStringList('emergency_contacts') ?? const <String>[]) {
        numbers.add(extractPhone(entry));
      }
      final single = prefs.getString(_contactKey);
      if (single != null && single.isNotEmpty) numbers.add(normalizePhone(single));
    } catch (e) {
      debugPrint('Local contacts unreadable: $e');
    }

    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('contacts')
            .get()
            .timeout(const Duration(seconds: 3));
        for (final doc in snap.docs) {
          final phone = doc.data()['phone']?.toString() ?? '';
          if (phone.isNotEmpty) numbers.add(normalizePhone(phone));
        }
      } catch (e) {
        debugPrint('Cloud contacts unavailable: $e');
      }
    }

    return numbers.where((n) => n.isNotEmpty).toList();
  }

  // ------------------------------------------------------------------ logging

  /// Every attempt is printed, appended to a local ring buffer (read it with
  /// [readAttemptLog]) and, when possible, to the alert document.
  static Future<void> _recordAttempt(
    DocumentReference<Map<String, dynamic>> docRef,
    SosAttempt a,
  ) async {
    debugPrint('[GUARDIAN_LOG] $a');
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final log = AttemptLog.decode(prefs.getString(_attemptLogKey))..add(a);
      await prefs.setString(_attemptLogKey, log.encode());
    } catch (_) {}
    unawaited(_mergeIntoDoc(docRef, {
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
    DocumentReference<Map<String, dynamic>> docRef,
    Map<String, dynamic> data,
  ) async {
    try {
      await docRef
          .set(data, SetOptions(merge: true))
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('Firestore merge skipped: $e');
    }
  }
}
