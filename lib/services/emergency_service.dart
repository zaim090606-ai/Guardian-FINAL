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

import '../logic/alert_schema.dart';
import '../logic/pdr_engine.dart';
import '../logic/pdr_snapshot.dart';
import '../logic/sos_dispatcher.dart';
import '../logic/sos_guard.dart';
import '../logic/sos_packet.dart';
import 'ai_service.dart';
import 'audio_recorder_service.dart';
import 'auth_service.dart';
import 'diagnostics_hub.dart';
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

  /// Withdraws the offered packet. In the UI isolate this stops advertising
  /// directly; the service isolate replaces it with a `relay_stop` message,
  /// because the relay only runs in the UI isolate.
  static void Function() meshStop = () => unawaited(RelayService().stopRelay());

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
    Timer? beat;
    try {
      _activeId = docId;
      _session = SosSession(guard);
      _session.onCancel(_stopTimers);
      _session.onCancel(() => meshStop());
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
        // The owner's uid is added when the document is written; personal
        // fields (phone, transcript, audio) go to the private document.
        return <String, dynamic>{
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
          'timestamp': FieldValue.serverTimestamp(),
        };
      }

      // Keeps the guard fresh while the channels run (up to ~30 s).
      beat = Timer.periodic(const Duration(seconds: 10), (_) =>
          unawaited(guard.heartbeat(docId, DateTime.now().millisecondsSinceEpoch)));
      final dispatcher = SosDispatcher(onAttempt: (a) => _recordAttempt(docId, a));
      final attempts = await dispatcher.dispatch(
        sosId: docId,
        cloud: () => _uploadAlert(docId, docData),
        sms: () => _sendSms(text, contacts),
        mesh: () => meshOffer(packet),
      );
      beat.cancel();
      dispatched = attempts.any((a) => a.ok);
      debugPrint('[GUARDIAN_LOG] SOS $docId result: '
          '${attempts.map((a) => "${a.channel}=${a.ok ? "ok" : "fail"}").join(", ")}');

      // The user may have cancelled while the channels were running: do not
      // start tracking or recording, and withdraw a relay that started late.
      if (_activeId != docId) {
        meshStop();
        debugPrint('[GUARDIAN_LOG] SOS $docId cancelled during dispatch.');
        return;
      }

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
      beat?.cancel();
      // No channel worked: free the guard so the user can try again.
      if (!dispatched) await stopLocal();
    }
  }

  // ------------------------------------------------------------------ cancel

  /// UI isolate: cancels the SOS here and tells the service isolate to do the
  /// same; the service answers with `relay_stop` for its own offer.
  static Future<void> cancelSos() async {
    // An SOS sent by the service isolate is advertised from this isolate, so
    // withdraw it here whichever isolate dispatched it.
    meshStop();
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
    final uid = await AuthService.ensureUid();
    if (uid == null) {
      // Never write a made-up owner: keep the alert and send it after sign-in.
      await AuthService.savePending(docId, data);
      AuthService.startRetryLoop();
      throw StateError('not signed in (alert kept, will be sent after sign-in)');
    }
    final conn = await Connectivity().checkConnectivity();
    if (conn.contains(ConnectivityResult.none)) {
      unawaited(_mergeIntoDoc(docId, data));
      throw StateError('no network connection (write queued locally)');
    }
    await _writeAlert(docId, data, uid);
    return true;
  }

  /// Writes the public document, then the private one (best effort).
  static Future<void> _writeAlert(
      String docId, Map<String, dynamic> data, String uid) async {
    final parts = AlertSchema.split(data, uid);
    final ref = FirebaseFirestore.instance.collection('emergency_logs').doc(docId);
    await ref.set(parts.public, SetOptions(merge: true));
    if (parts.private.length > 1) {
      try {
        await ref
            .collection('private')
            .doc('details')
            .set(parts.private, SetOptions(merge: true))
            .timeout(const Duration(seconds: 10));
      } catch (e) {
        debugPrint('Private alert details skipped: $e');
      }
    }
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

  /// True in the foreground-service isolate, which owns PDR. The UI isolate
  /// reads the service's published snapshot instead.
  static bool isServiceIsolate = false;

  static Future<bool> _simulatedNow() async {
    try {
      if (isServiceIsolate) return PdrService().simulateGpsLoss;
      final snap = DiagnosticsHub.pdrSnapshot();
      if (snap != null && snap.isFresh(DateTime.now().millisecondsSinceEpoch)) {
        return snap.simulate;
      }
      return await PdrSettings(PrefsKeyValueStore()).readSimulate();
    } catch (_) {
      return false;
    }
  }

  /// The PDR estimate if there is one, otherwise the stored last real fix,
  /// otherwise the platform's last known position. Never waits for a new GPS
  /// reading.
  static Future<LocationFix?> _defaultLocationNow() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    LocationFix? fix;
    if (isServiceIsolate) {
      fix = PdrService().currentFix();
    } else {
      fix = DiagnosticsHub.pdrSnapshot()?.locationFix(now);
    }
    if (fix != null) return fix;
    if (await _simulatedNow()) return null;
    fix = await PdrService.loadLastKnown();
    if (fix != null) return fix;
    try {
      final last = await Geolocator.getLastKnownPosition();
      if (last != null) {
        return LocationFix(
          lat: last.latitude,
          lng: last.longitude,
          source: 'last_known',
          uncertaintyM: last.accuracy,
          timeMs: clampFixTime(last.timestamp.millisecondsSinceEpoch, now),
        );
      }
    } catch (_) {}
    return null;
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
      unawaited(guard.heartbeat(docId, DateTime.now().millisecondsSinceEpoch));
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

  /// Merges fields into the alert. Public fields go to emergency_logs/<id>
  /// and personal ones to its private document; every write carries the
  /// owner's uid. Skipped (and logged) when the phone is not signed in.
  static Future<void> _mergeIntoDoc(
    String docId,
    Map<String, dynamic> data,
  ) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) {
        debugPrint('Firestore merge skipped: not signed in');
        return;
      }
      await _writeAlert(docId, data, uid).timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('Firestore merge skipped: $e');
    }
  }
}
