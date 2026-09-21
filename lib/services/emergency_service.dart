import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:geolocator/geolocator.dart';
import 'package:background_sms/background_sms.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/foundation.dart';
import 'dart:async';
// Black box evidence recorder service & Gemini AI Service
import 'audio_recorder_service.dart';
import '../ai_service.dart';

class EmergencyService {
  static const String _contactKey = "emergency_contact_number";

  // Safeguard: Lock flag to prevent overlapping triggers during high-impact shaking/tumbling
  static bool _isDispatching = false;

  static Future<void> triggerEmergencyDispatch
  ({
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
    debugPrint(
        "🚨 EMERGENCY TRIGGERED! Force: $force, Level: $level, Speech: '$audioTranscript'");

    try {
      // 1. Fetch live GPS coordinates with 3-second safeguard timeout
      Position? position = await _getCurrentLocation();
      double lat = position?.latitude ?? 0.0;
      double lng = position?.longitude ?? 0.0;

      // 2. CREATE FIRESTORE DOC FIRST (So we have a docId to send in the SMS link)
      String? docId = await _logEmergencyToFirestore(
          position, force, level, "Generating alert...", audioTranscript);

      // 3. GENERATE SMS MESSAGE WITH TRACKING LINK
      String trackingLink = "https://your-app-website.com/alert/$docId";

      String aiMessage = await AIService.generateAlert(
        gForce: force,
        lat: lat,
        lng: lng,
        audioTranscript: audioTranscript,
        level: level,
      );

      // Place the tracking link at the VERY TOP so cellular SMS character limits never truncate it
      String emergencyMessage =
          "🚨 URGENT SOS!\nTracking: $trackingLink\n\n$aiMessage";

      // Update Firestore with the final message
      if (docId != null) {
        await FirebaseFirestore.instance
            .collection('emergency_logs')
            .doc(docId)
            .update({
          'alertMessage': emergencyMessage,
        });
      }

      debugPrint("📨 Final SMS Payload: $emergencyMessage");

      // 4. Start 30-second background audio recording and stream upload to Firebase Storage
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

          // Update Firestore log entry with audio download URL and Gemini analysis
          if (docId != null) {
            await FirebaseFirestore.instance
                .collection('emergency_logs')
                .doc(docId)
                .update({
              'audioUrl': downloadUrl,
              'audioStatus': downloadUrl != null ? 'uploaded' : 'failed',
              'audioAnalysis': aiAudioReport,
              'audioUploadedAt': FieldValue.serverTimestamp(),
            });
            debugPrint(
                "✅ Emergency log document ($docId) updated with audio evidence & Gemini analysis!");
          }
        }
      });

      // 5. Fetch phone numbers dynamically from Firestore & SharedPreferences fallback
      List<String> recipients = await _fetchTrustedContactNumbers();

      if (recipients.isEmpty) {
        debugPrint("⚠️ No emergency contacts found!");
        return;
      }

      // 6. WhatsApp Cloud API (Bypassed / Fallback path)
      bool whatsappSent = await _sendViaWhatsAppAPI(
        emergencyMessage,
        recipients,
      );

      // 7. Fallback to Cellular SMS
      if (!whatsappSent) {
        debugPrint("🌐 Dispatching via Background Cellular SMS...");
        await _sendViaCellularSMS(emergencyMessage, recipients);
      }
    } catch (e) {
      debugPrint("❌ Error during emergency dispatch: $e");
    } finally {
      // Release lock after a 2-minute cooldown so future legitimate alerts can fire
      Future.delayed(const Duration(minutes: 2), () {
        _isDispatching = false;
        debugPrint(
            "🔓 Emergency cooldown ended. Service ready for new triggers.");
      });
    }
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

    return numbers.where((num) => num.isNotEmpty).toList();
  }

  /// Cleans raw strings like "Mom (+919876543210)" into dialable phone numbers "+919876543210"
  static String _cleanPhoneNumber(String input) {
    RegExp phoneRegex = RegExp(r'\+?[0-9]{8,15}');
    Iterable<Match> matches = phoneRegex.allMatches(input);
    if (matches.isNotEmpty) {
      return matches.first.group(0)!;
    }
    return input.replaceAll(RegExp(r'[^\d+]'), '');
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
    return false; // Kept as placeholder for API integration
  }

  /// Sends background SMS automatically (Non-blocking status check)
  static Future<void> _sendViaCellularSMS(
    String message,
    List<String> recipients,
  ) async {
    var status = await Permission.sms.status;
    if (!status.isGranted) {
      debugPrint("❌ SMS permission not pre-granted. Dispatch blocked.");
      return;
    }

    for (String recipient in recipients) {
      debugPrint("📲 Attempting background SMS to $recipient...");

      try {
        SmsStatus result = await BackgroundSms.sendMessage(
          phoneNumber: recipient,
          message: message,
        );

        if (result == SmsStatus.sent) {
          debugPrint("✅ SMS successfully sent to $recipient");
        } else {
          debugPrint("❌ Failed to send SMS to $recipient (Status: $result)");
        }
      } catch (e) {
        debugPrint("❌ Exception sending SMS to $recipient: $e");
      }
    }
  }

  /// Logs the initial emergency event and returns the document ID so audio uploads can reference it later
  static Future<String?> _logEmergencyToFirestore(
    Position? position,
    double force,
    String level,
    String generatedAlertText,
    String transcript,
  ) async {
    try {
      final user = FirebaseAuth.instance.currentUser;

      DocumentReference docRef =
          await FirebaseFirestore.instance.collection('emergency_logs').add({
        'userId': user?.uid ?? 'anonymous',
        'userPhone': user?.phoneNumber ?? 'unknown',
        'eventType': transcript.isNotEmpty ? 'voice_trigger' : 'sensor_trigger',
        'riskLevel': level,
        'force': force,
        'transcript': transcript,
        'alertMessage': generatedAlertText,
        'latitude': position?.latitude ?? 0.0,
        'longitude': position?.longitude ?? 0.0,
        'status': 'triggered',
        'audioStatus': 'processing',
        'audioUrl': null,
        'timestamp': FieldValue.serverTimestamp(),
      });
      debugPrint(
          "✅ Initial emergency event logged to Firestore ID: ${docRef.id}");
      return docRef.id;
    } catch (e) {
      debugPrint("❌ Failed to log emergency: $e");
      return null;
    }
  }
}