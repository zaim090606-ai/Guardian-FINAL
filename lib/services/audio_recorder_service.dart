import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';

class AudioRecorderService {
  static final AudioRecorder _audioRecorder = AudioRecorder();

  /// Captures emergency background audio evidence.
  /// Defaults to 30 seconds for optimal upload size and context.
  static Future<String?> captureEmergencyAudio({int durationSeconds = 30}) async {
    try {
      // 1. Guard against double-recording if already active
      if (await _audioRecorder.isRecording()) {
        debugPrint("⚠️ Audio recording already in progress.");
        return null;
      }

      // 2. Check microphone permission without launching blocking prompts
      if (!await _audioRecorder.hasPermission()) {
        debugPrint("❌ Audio Recording Permission Not Granted");
        return null;
      }

      // 3. Hardware Buffer: Brief delay to let SpeechToText fully release the microphone hardware
      await Future.delayed(const Duration(milliseconds: 300));

      // 4. Define target path in temporary directory
      final Directory tempDir = await getTemporaryDirectory();
      final String filePath =
          '${tempDir.path}/sos_audio_${DateTime.now().millisecondsSinceEpoch}.m4a';

      debugPrint("🎙️ Starting emergency audio recording ($durationSeconds seconds)...");

      // 5. Start recording (64kbps AAC-LC offers clear voice quality at half the file size)
      await _audioRecorder.start(
        const RecordConfig(
          encoder: AudioEncoder.aacLc,
          bitRate: 64000, 
          sampleRate: 16000, // Optimized for voice clarity
        ),
        path: filePath,
      );

      // 6. Record for specified duration
      await Future.delayed(Duration(seconds: durationSeconds));

      // 7. Stop recording and verify file exists
      final String? savedPath = await _audioRecorder.stop();

      if (savedPath != null && await File(savedPath).exists()) {
        debugPrint("✅ 30-Second Audio evidence saved locally: $savedPath");
        return savedPath;
      } else {
        debugPrint("❌ Audio file was not saved properly.");
        return null;
      }
    } catch (e) {
      debugPrint("❌ Exception recording emergency audio: $e");
      return null;
    }
  }

  /// Uploads a recorded audio file to Firebase Storage under `/emergency_audio/{userId}/{filename}`
  /// and returns the downloadable URL.
  static Future<String?> uploadAudioToFirebase(String filePath) async {
    try {
      final File file = File(filePath);
      if (!await file.exists()) {
        debugPrint("❌ File does not exist for upload: $filePath");
        return null;
      }

      final String userId = FirebaseAuth.instance.currentUser?.uid ?? "anonymous_user";
      final String fileName = "sos_${DateTime.now().millisecondsSinceEpoch}.m4a";
      final Reference storageRef = FirebaseStorage.instance
          .ref()
          .child('emergency_audio')
          .child(userId)
          .child(fileName);

      debugPrint("☁️ Uploading audio evidence to Firebase Storage...");
      final UploadTask uploadTask = storageRef.putFile(
        file,
        SettableMetadata(contentType: 'audio/mp4'),
      );

      final TaskSnapshot snapshot = await uploadTask;
      final String downloadUrl = await snapshot.ref.getDownloadURL();
      
      debugPrint("✅ Audio uploaded successfully! URL: $downloadUrl");

      // Cleanup local temp file post-upload
      if (await file.exists()) {
        await file.delete();
      }

      return downloadUrl;
    } catch (e) {
      debugPrint("❌ Exception uploading audio to Firebase Storage: $e");
      return null;
    }
  }

  /// Force stop recording if an emergency is cancelled by user
  static Future<void> cancelRecording() async {
    try {
      if (await _audioRecorder.isRecording()) {
        await _audioRecorder.stop();
        debugPrint("⏹️ Emergency audio recording cancelled.");
      }
    } catch (e) {
      debugPrint("❌ Error stopping recorder: $e");
    }
  }
}