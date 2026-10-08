import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:background_sms/background_sms.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'dart:async';

// Offline, Evidence & AI Services
import 'audio_recorder_service.dart';
import 'ai_service.dart';
import 'pdr_services.dart';
import 'relay_service.dart';

class EmergencyService {
  static const String _contactKey = "emergency_contact_number";
  static const MethodChannel _smsChannel = MethodChannel('com.guardian.app/sms');

  static void updateIncidentContext(String summary) {
    debugPrint("🚨 Emergency Incident Context Updated: $summary");
  }

  // Safeguard: Lock flag to prevent overlapping triggers during high-impact shaking/tumbling
  static bool _isDispatching = false;
  static StreamSubscription<Position>? _positionStreamSubscription;

  @pragma('vm:entry-point')
  static Future<void> triggerEmergencyDispatch({
    required double force,
    required String level,
    String audioTranscript = "",
  }) async {
    // 0. Debounce check: Ignore rapid repeated sensor/voice triggers
    if (_isDispatching) {
      debugPrint(
          "⚠️ Emergency dispatch already active. Suppressing duplicate trigger.");
      return;
    }

    _isDispatching = true;
    bool dispatchSuccessful = false;
    debugPrint("[GUARDIAN_LOG] 1. Emergency trigger detected: Force=$force, Level=$level, Transcript='$audioTranscript'");

    try {
      // 1. Pre-generate Firestore document reference (Guarantees valid docId offline)
      debugPrint("[GUARDIAN_LOG] 2. Generating Firestore document ID...");
      DocumentReference docRef =
          FirebaseFirestore.instance.collection('emergency_logs').doc();
      String docId = docRef.id;
      debugPrint("[GUARDIAN_LOG] 3. Document ID generated: $docId");
      startLiveTracking(docId);   
      // 2. Fetch Live GPS with PDR (Dead Reckoning) Fallback
      Position? position = await _getCurrentLocation();
      double lat = position?.latitude ?? 0.0;
      double lng = position?.longitude ?? 0.0;

      if (position != null && (lat != 0.0 || lng != 0.0)) {
        // GPS active: Re-anchor Dead Reckoning Engine
        PdrService().setAnchorPosition(position);
      } else {
        // GPS failed/underground: Fallback to Pedestrian Dead Reckoning estimation
        var pdrData = PdrService().getEstimatedPosition();
        lat = pdrData['latitude'] ?? 0.0;
        lng = pdrData['longitude'] ?? 0.0;
        debugPrint(
            "🛰️ GPS unavailable. Dead Reckoning Fallback Position: Lat $lat, Lng $lng");
      }

      // 3. Log initial emergency event using the pre-generated docId
      debugPrint("[GUARDIAN_LOG] 4. Logging initial event to Firestore...");
      await _logEmergencyToFirestore(
        docRef: docRef,
        position: position,
        fallbackLat: lat,
        fallbackLng: lng,
        force: force,
        level: level,
        generatedAlertText: "Generating alert...",
        transcript: audioTranscript,
      );
      debugPrint("[GUARDIAN_LOG] 5. Initial Firestore log completed");

      // 4. Generate tracking link & AI alert message
      String trackingLink = "https://fir-b10e4.web.app/alert/$docId";
      debugPrint("[GUARDIAN_LOG] 6. Tracking link generated: $trackingLink");

      String aiMessage = await AIService.generateAlert(
        gForce: force,
        lat: lat,
        lng: lng,
        audioTranscript: audioTranscript,
        level: level,
      );
      debugPrint("[GUARDIAN_LOG] 7. AI alert message generated");

      // Place tracking link at the very top to avoid truncation in SMS
      String emergencyMessage =
          "🚨 URGENT SOS!\nTracking: $trackingLink\n\n$aiMessage";

      // Update Firestore with final AI message text with timeout safeguard
      debugPrint("[GUARDIAN_LOG] 8. Updating Firestore with alert message...");
      try {
        await docRef.update({
          'alertMessage': emergencyMessage,
        }).timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            debugPrint("⚠️ Firestore update timeout (5s) - continuing with SMS dispatch");
            return;
          },
        );
      } catch (e) {
        debugPrint("⚠️ Firestore update failed: $e - continuing with SMS dispatch");
      }

      debugPrint("[GUARDIAN_LOG] 9. SMS payload ready: ${emergencyMessage.substring(0, 100)}...");

      // 5. Start 30-second background audio recording and stream upload
      // 5. Start 30-second background audio recording and stream upload
      var micStatus = await Permission.microphone.status;
      if (!micStatus.isGranted) {
        micStatus = await Permission.microphone.request();
      }

      if (micStatus.isGranted) {
        AudioRecorderService.captureEmergencyAudio(durationSeconds: 30)
            .then((audioPath) async {
          if (audioPath != null) {
            debugPrint(
                "🎙️ 30-second emergency audio recording completed: $audioPath");

            // Run Gemini multimodal analysis on the recorded audio file
            String aiAudioReport =
                await AIService.analyzeAudioEvidence(audioPath);

            // Upload local file to Firebase Storage
            String? downloadUrl =
                await AudioRecorderService.uploadAudioToFirebase(audioPath);

            // Update Firestore log entry with audio evidence details with timeout safeguard
            try {
              await docRef.update({
                'audioUrl': downloadUrl,
                'audioStatus': downloadUrl != null ? 'uploaded' : 'failed',
                'audioAnalysis': aiAudioReport,
                'audioUploadedAt': FieldValue.serverTimestamp(),
              }).timeout(
                const Duration(seconds: 5),
                onTimeout: () {
                  debugPrint("⚠️ Firestore audio update timeout (5s) - audio evidence stored locally");
                  return;
                },
              );
            } catch (e) {
              debugPrint("⚠️ Firestore audio update failed: $e");
            }

            String cleanAnalysis = aiAudioReport.replaceAll('\n', ' ');
            if (cleanAnalysis.length > 140) {
              cleanAnalysis = "${cleanAnalysis.substring(0, 137)}...";
            }
            String followUpMessage = "🚨 Guardian Audio Update: $cleanAnalysis";

            List<String> contacts = await _fetchTrustedContactNumbers();
            if (contacts.isNotEmpty) {
              await _sendViaCellularSMS(followUpMessage, contacts);
            }

            debugPrint(
                "✅ Emergency log document ($docId) updated with audio evidence & Gemini analysis!");
          }
        });
      } else {
        debugPrint("❌ Microphone permission denied. Audio recording skipped.");
      }

      // 6. Fetch phone numbers dynamically
      debugPrint("[GUARDIAN_LOG] 10. Fetching emergency contact numbers...");
      List<String> recipients = await _fetchTrustedContactNumbers();

      if (recipients.isEmpty) {
        debugPrint("[GUARDIAN_LOG] 11. ❌ No emergency contacts found! Triggering Mesh Relay broadcast directly.");
      } else {
        debugPrint("[GUARDIAN_LOG] 11. Found ${recipients.length} emergency contact(s)");
      }

      // 7. Try WhatsApp API (Bypassed / Fallback path)
      debugPrint("[GUARDIAN_LOG] 12. Attempting WhatsApp dispatch...");
      bool whatsappSent = await _sendViaWhatsAppAPI(
        emergencyMessage,
        recipients,
      );

      bool smsSent = false;

      // 8. Cellular SMS Attempt
      if (!whatsappSent && recipients.isNotEmpty) {
        debugPrint("[GUARDIAN_LOG] 13. Dispatching via Background Cellular SMS...");
        smsSent = await _sendViaCellularSMS(emergencyMessage, recipients);
        if (smsSent) {
          debugPrint("[GUARDIAN_LOG] 14. ✅ SMS dispatch successful");
        } else {
          debugPrint("[GUARDIAN_LOG] 14. ❌ SMS dispatch failed");
        }
      }

      // 9. Mesh Relay Fallback (If SMS and WhatsApp both fail or zero cellular signal)
      if (!whatsappSent && !smsSent) {
        debugPrint("[GUARDIAN_LOG] 15. Primary cellular channels unavailable. Initiating Mesh Relay Broadcast...");
        await RelayService().broadcastEmergencyPacket(
          alertId: docId,
          lat: lat,
          lng: lng,
          message: emergencyMessage,
        );
        debugPrint("[GUARDIAN_LOG] 16. Mesh relay broadcast complete");
      }

      dispatchSuccessful = true;
      debugPrint("[GUARDIAN_LOG] 17. ✅ Emergency dispatch sequence completed successfully");
    } catch (e) {
      debugPrint("❌ Error during emergency dispatch: $e");
    } finally {
      if (dispatchSuccessful) {
        // Enforce 2-minute cooldown on success to prevent spamming
        Future.delayed(const Duration(minutes: 2), () {
          _isDispatching = false;
          debugPrint(
              "🔓 Emergency cooldown ended. Service ready for new triggers.");
        });
      } else {
        // Unlock immediately on failure/error so the user can retry right away
        _isDispatching = false;
        debugPrint(
            "🔓 Emergency dispatch unhandled or aborted. Lock released immediately.");
      }
    }
  }
  static void startLiveTracking(String docId) {
    _positionStreamSubscription?.cancel();
    _positionStreamSubscription = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
      ),
    ).listen((Position position) {
      FirebaseFirestore.instance
          .collection('emergency_logs')
          .doc(docId)
          .update({
        'latitude': position.latitude,
        'longitude': position.longitude,
        'lastLiveUpdate': FieldValue.serverTimestamp(),
      }).catchError((e) => debugPrint("⚠️ Live tracking update failed: $e"));
    });
  }

  static Future<void> stopLiveTracking() async {
    await _positionStreamSubscription?.cancel();
    _positionStreamSubscription = null;
    debugPrint("🛑 Live GPS tracking stopped.");
  }
  /// Fetches phone numbers from user's Firestore path, legacy collections, or SharedPreferences fallback
  static Future<List<String>> _fetchTrustedContactNumbers() async {
    Set<String> numbers = {};
    final user = FirebaseAuth.instance.currentUser;

    // 1. User-specific Firestore path
    if (user != null) {
      try {
        QuerySnapshot userContacts = await FirebaseFirestore.instance
            .collection('users')
            .doc(user.uid)
            .collection('contacts')
            .get();

        for (var doc in userContacts.docs) {
          var data = doc.data() as Map<String, dynamic>;
          if (data.containsKey('phone') && data['phone'].toString().isNotEmpty) {
            numbers.add(_cleanPhoneNumber(data['phone'].toString()));
          }
        }
      } catch (e) {
        debugPrint("❌ Failed to fetch user contacts: $e");
      }
    }

    // 2. Legacy root collection fallback
    if (numbers.isEmpty) {
      try {
        QuerySnapshot snapshot =
            await FirebaseFirestore.instance.collection('trusted_contacts').get();

        for (var doc in snapshot.docs) {
          var data = doc.data() as Map<String, dynamic>;
          if (data.containsKey('phone') && data['phone'].toString().isNotEmpty) {
            numbers.add(_cleanPhoneNumber(data['phone'].toString()));
          }
        }
      } catch (e) {
        debugPrint("❌ Failed to fetch contacts from Firestore: $e");
      }
    }

    // 3. Fallback to local storage
    if (numbers.isEmpty) {
      final prefs = await SharedPreferences.getInstance();

      List<String>? localList = prefs.getStringList('emergency_contacts');
      if (localList != null && localList.isNotEmpty) {
        for (String entry in localList) {
          numbers.add(_cleanPhoneNumber(entry));
        }
      }

      String? localContact = prefs.getString(_contactKey);
      if (localContact != null && localContact.isNotEmpty) {
        numbers.add(_cleanPhoneNumber(localContact));
      }
    }

    // 4. Hardcoded fallback emergency contact (E.164 format with +91)
    if (numbers.isEmpty) {
      debugPrint("⚠️ No contacts found. Using hardcoded fallback emergency contact.");
      numbers.add('+919412276920');
    }

    return numbers.where((number) => number.isNotEmpty).toList();
  }

  /// Sanitizes phone numbers: strips spaces, dashes, and letters
  /// Enforces E.164 format for Android 16 compatibility: auto-prepends +91 to 10-digit numbers
  static String _cleanPhoneNumber(String input) {
    // Strip all spaces, dashes, letters, and non-digit characters except '+'
    String cleaned = input.replaceAll(RegExp(r'[^\d+]'), '');

    // If it's exactly a 10-digit number without country code, prepend +91
    if (cleaned.length == 10 && !cleaned.startsWith('+')) {
      cleaned = '+91$cleaned';
    }

    return cleaned;
  }

  static Future<Position?> _getCurrentLocation() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return await Geolocator.getLastKnownPosition();

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      return await Geolocator.getLastKnownPosition();
    }

    try {
      // 3-second timeout safeguard so dispatch never hangs
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 3),
        ),
      );
    } catch (_) {
      return await Geolocator.getLastKnownPosition();
    }
  }

  static Future<bool> _sendViaWhatsAppAPI(
    String message,
    List<String> recipients,
  ) async {
    return false; // Placeholder for future API integration
  }

  /// Sends background SMS using native multipart method for Android 16 compatibility.
  /// Routes to native MethodChannel to handle UCS-2 encoding (emojis + URLs > 70 chars).
  /// Returns true if at least one SMS sent successfully.
  static Future<bool> _sendViaCellularSMS(
    String message,
    List<String> recipients,
  ) async {
    var status = await Permission.sms.status;
    if (!status.isGranted) {
      status = await Permission.sms.request();
    }

    if (!status.isGranted) {
      debugPrint("❌ SMS permission denied by user. Dispatch blocked.");
      return false;
    }

    bool atLeastOneSent = false;

    for (String recipient in recipients) {
      // Apply strict phone number sanitization: ensure E.164 format with +91
      String sanitizedNumber = _cleanPhoneNumber(recipient);

      debugPrint("📲 Attempting native multipart SMS to $sanitizedNumber...");

      try {
        // Route to native Kotlin MethodChannel for Android 16 multipart SMS dispatch
        final bool result = await _smsChannel.invokeMethod('sendMultipartSms', {
          'phoneNumber': sanitizedNumber,
          'message': message,
        });

        if (result) {
          debugPrint("✅ Native multipart SMS successfully sent to $sanitizedNumber");
          atLeastOneSent = true;
        } else {
          debugPrint("❌ Failed to send native SMS to $sanitizedNumber");
        }
      } catch (e) {
        debugPrint("❌ Exception sending native SMS to $sanitizedNumber: $e");

        // Fallback to background_sms package if native channel fails
        try {
          SmsStatus fallbackResult = await BackgroundSms.sendMessage(
            phoneNumber: sanitizedNumber,
            message: message,
          );

          if (fallbackResult == SmsStatus.sent) {
            debugPrint("✅ Fallback SMS sent to $sanitizedNumber");
            atLeastOneSent = true;
          }
        } catch (fallbackError) {
          debugPrint("❌ Fallback SMS also failed for $sanitizedNumber: $fallbackError");
        }
      }
    }

    return atLeastOneSent;
  }

  /// Logs the initial emergency event using the pre-created DocumentReference
  static Future<void> _logEmergencyToFirestore({
    required DocumentReference docRef,
    required Position? position,
    required double fallbackLat,
    required double fallbackLng,
    required double force,
    required String level,
    required String generatedAlertText,
    required String transcript,
  }) async {
    try {
      final user = FirebaseAuth.instance.currentUser;

      await docRef.set({
        'userId': user?.uid ?? 'anonymous',
        'userPhone': user?.phoneNumber ?? 'unknown',
        'eventType': transcript.isNotEmpty ? 'voice_trigger' : 'sensor_trigger',
        'riskLevel': level,
        'force': force,
        'transcript': transcript,
        'alertMessage': generatedAlertText,
        'latitude': position?.latitude ?? fallbackLat,
        'longitude': position?.longitude ?? fallbackLng,
        'isDeadReckoning': position == null,
        'status': 'triggered',
        'audioStatus': 'processing',
        'audioUrl': null,
        'timestamp': FieldValue.serverTimestamp(),
      });
      debugPrint("✅ Initial emergency event logged to Firestore ID: ${docRef.id}");
    } catch (e) {
      debugPrint("❌ Failed to log emergency to Firestore: $e");
    }
  }
}
     