import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:firebase_auth/firebase_auth.dart';

class AudioRecorderService {
  // Re-instantiate if null or closed to prevent cross-isolate state corruption
  static AudioRecorder? _audioRecorder;
  static String? _currentRecordingPath;

  static AudioRecorder _getRecorder() {
    _audioRecorder ??= AudioRecorder();
    return _audioRecorder!;
  }

  /// Ensures explicit runtime permissions at OS level
  static Future<bool> checkAndRequestPermissions() async {
    final status = await Permission.microphone.status;
    if (status.isGranted) return true;
    
    final result = await Permission.microphone.request();
    return result.isGranted;
  }

  /// Starts background audio recording (16kHz Mono WAV format for YAMNet/Whisper).
  static Future<String?> startEmergencyAudioRecording() async {
    try {
      final recorder = _getRecorder();

      // Check if already recording
      if (await recorder.isRecording()) {
        debugPrint("⚠️ Audio recording already in progress: $_currentRecordingPath");
        return _currentRecordingPath;
      }

      // Check permissions via permission_handler
      final hasPerm = await checkAndRequestPermissions();
      if (!hasPerm) {
        debugPrint("❌ Audio Recording Permission Not Granted at OS level.");
        return null;
      }

      // Allow 800ms for hardware buffers (e.g. SpeechToText) to release mic
      await Future.delayed(const Duration(milliseconds: 800));

      final Directory tempDir = await getTemporaryDirectory();
      final String filePath =
          '${tempDir.path}/sos_audio_${DateTime.now().millisecondsSinceEpoch}.wav';

      debugPrint("🎙️ Starting 16kHz WAV emergency audio recording...");

      await recorder.start(
        const RecordConfig(
          encoder: AudioEncoder.wav,        // Linear PCM WAV
          sampleRate: 16000,                 // 16kHz required for YAMNet & Whisper
          numChannels: 1,                    // Mono
          androidConfig: AndroidRecordConfig(
            audioSource: AndroidAudioSource.voiceRecognition, // Best for AI models & background capture
          ),
        ),
        path: filePath,
      );

      _currentRecordingPath = filePath;
      debugPrint("✅ Recording successfully started at: $filePath");
      return filePath;
    } catch (e) {
      debugPrint("❌ Exception starting emergency audio: $e");
      // Reset recorder instance on hardware crash
      await disposeRecorder();
      return null;
    }
  }

  /// Stops ongoing recording and returns verified file path.
  static Future<String?> stopEmergencyAudioRecording() async {
    try {
      if (_audioRecorder == null) return null;

      if (await _audioRecorder!.isRecording()) {
        final String? savedPath = await _audioRecorder!.stop();
        final String? returnPath = savedPath ?? _currentRecordingPath;
        _currentRecordingPath = null;

        if (returnPath != null && await File(returnPath).exists()) {
          final int fileSize = await File(returnPath).length();
          debugPrint("✅ Audio evidence saved ($fileSize bytes): $returnPath");
          
          if (fileSize == 0) {
            debugPrint("⚠️ Warning: Recorded audio file is 0 bytes!");
            return null;
          }
          return returnPath;
        }
      }
      return null;
    } catch (e) {
      debugPrint("❌ Exception stopping emergency audio: $e");
      return null;
    }
  }

  /// Captures emergency audio for a fixed duration.
  static Future<String?> captureEmergencyAudio({int durationSeconds = 30}) async {
    final String? path = await startEmergencyAudioRecording();
    if (path == null) return null;

    await Future.delayed(Duration(seconds: durationSeconds));
    return await stopEmergencyAudioRecording();
  }

  /// Uploads audio file to Firebase Storage. Preserves local file if offline.
  static Future<String?> uploadAudioToFirebase(String filePath) async {
    final File file = File(filePath);
    if (!await file.exists()) {
      debugPrint("❌ File does not exist for upload: $filePath");
      return null;
    }

    try {
      final String userId = FirebaseAuth.instance.currentUser?.uid ?? "anonymous_user";
      final String fileName = "sos_${DateTime.now().millisecondsSinceEpoch}.wav";
      final Reference storageRef = FirebaseStorage.instance
          .ref()
          .child('emergency_audio')
          .child(userId)
          .child(fileName);

      debugPrint("☁️ Uploading WAV audio evidence to Firebase Storage...");
      final UploadTask uploadTask = storageRef.putFile(
        file,
        SettableMetadata(contentType: 'audio/wav'),
      );

      final TaskSnapshot snapshot = await uploadTask;
      final String downloadUrl = await snapshot.ref.getDownloadURL();

      debugPrint("✅ Audio uploaded successfully! URL: $downloadUrl");

      if (await file.exists()) {
        await file.delete();
      }

      return downloadUrl;
    } catch (e) {
      debugPrint("⚠️ Upload failed (offline/network). Retaining file for store-and-forward: $e");
      return filePath;
    }
  }

  /// Safely cancel and release hardware recorder instance
  static Future<void> cancelRecording() async {
    try {
      if (_audioRecorder != null && await _audioRecorder!.isRecording()) {
        await _audioRecorder!.stop();
        _currentRecordingPath = null;
        debugPrint("⏹️ Emergency audio recording cancelled.");
      }
    } catch (e) {
      debugPrint("❌ Error cancelling recorder: $e");
    } finally {
      await disposeRecorder();
    }
  }

  /// Dispose recorder instance to free hardware memory
  static Future<void> disposeRecorder() async {
    try {
      await _audioRecorder?.dispose();
    } catch (_) {}
    _audioRecorder = null;
  }
}