import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ai_service.dart';
import 'emergency_service.dart';
import 'local_whisper_service.dart';
import 'yamnet_service.dart';

class VoiceService {
  static final AudioRecorder _recorder = AudioRecorder();
  static final YamnetService _yamnetService = YamnetService();

  static bool _isListening = false;
  static bool _isInitialized = false;
  static bool _isTriggered = false;
  static StreamSubscription<Uint8List>? _audioStreamSub;

  /// Global state toggle for user privacy
  static final ValueNotifier<bool> isEnabledNotifier = ValueNotifier<bool>(true);

  /// Reactive notifier to update UI transcript live
  static final ValueNotifier<String> transcriptNotifier = ValueNotifier<String>('');

  /// Reactive notifier for current active keywords (UI state sync)
  static final ValueNotifier<List<String>> keywordsNotifier = ValueNotifier<List<String>>([]);

  static final List<String> _rollingTranscript = [];
  static const String _customKeywordsKey = "custom_voice_keywords";

  /// Default emergency trigger words
  static final List<String> _defaultKeywords = [
    'help',
    'sos',
    'emergency',
    'save me',
    'danger',
    'call police',
    'bachao',
    'madad',
  ];

  static List<String> activeKeywords = [..._defaultKeywords];
  static Function()? onSosTriggered;

  static String get recentTranscript => _rollingTranscript.join(" ");

  /// Initialize Dual Engine (YAMNet + Whisper) and start background monitoring loop
  static Future<void> startListening({Function()? onSosTriggeredCallback}) async {
    if (onSosTriggeredCallback != null) {
      onSosTriggered = onSosTriggeredCallback;
    }

    await loadCustomKeywords();

    if (!isEnabledNotifier.value) {
      debugPrint("🎙️ Voice monitoring is currently disabled by user.");
      return;
    }

    var status = await Permission.microphone.request();
    if (!status.isGranted) {
      debugPrint("❌ Microphone permission denied.");
      return;
    }

    if (!_isInitialized) {
      await _yamnetService.initialize();
      await LocalWhisperService.initialize();
      _isInitialized = true;
    }

    if (_isInitialized && !_isListening) {
      _startContinuousChunkLoop();
    }
  }

  /// Turn voice monitoring ON or OFF
  static Future<void> toggleVoiceMonitoring(bool enabled) async {
    isEnabledNotifier.value = enabled;
    if (enabled) {
      await startListening();
    } else {
      await stopListening();
      transcriptNotifier.value = "Voice Monitoring Paused";
    }
  }

  /// Load custom keywords from SharedPreferences & notify UI listeners
  static Future<void> loadCustomKeywords() async {
    final prefs = await SharedPreferences.getInstance();
    List<String>? saved = prefs.getStringList(_customKeywordsKey);
    activeKeywords = [..._defaultKeywords];
    if (saved != null && saved.isNotEmpty) {
      for (String item in saved) {
        if (!activeKeywords.contains(item)) {
          activeKeywords.add(item);
        }
      }
    }
    keywordsNotifier.value = List.unmodifiable(activeKeywords);
  }

  /// Save a new custom trigger keyword
  static Future<bool> addCustomKeyword(String word) async {
    final cleanWord = _sanitizeText(word);
    if (cleanWord.isEmpty || activeKeywords.contains(cleanWord)) return false;

    final prefs = await SharedPreferences.getInstance();
    List<String> saved = prefs.getStringList(_customKeywordsKey) ?? [];
    if (!saved.contains(cleanWord)) {
      saved.add(cleanWord);
      await prefs.setStringList(_customKeywordsKey, saved);
    }
    await loadCustomKeywords();
    return true;
  }

  /// Remove a custom trigger keyword
  static Future<bool> removeCustomKeyword(String word) async {
    final cleanWord = _sanitizeText(word);
    if (_defaultKeywords.contains(cleanWord)) return false;

    final prefs = await SharedPreferences.getInstance();
    List<String> saved = prefs.getStringList(_customKeywordsKey) ?? [];
    if (saved.contains(cleanWord)) {
      saved.remove(cleanWord);
      await prefs.setStringList(_customKeywordsKey, saved);
      await loadCustomKeywords();
      return true;
    }
    return false;
  }

  /// Clean punctuation and standardize text
  static String _sanitizeText(String input) {
    return input
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s]'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Cycle audio snippet recording continuously for local edge inference
  static void _startContinuousChunkLoop() async {
    if (!isEnabledNotifier.value || _isListening) return;

    _isListening = true;
    debugPrint("🎙️ Dual-Engine Edge Audio Monitor Running...");

    try {
      final dir = await getTemporaryDirectory();
      
      while (_isListening && isEnabledNotifier.value) {
        if (_isTriggered) {
          await Future.delayed(const Duration(seconds: 2));
          continue;
        }

        final audioPath = '${dir.path}/temp_audio_chunk.wav';
        
        // Record 2.5 second audio slice at 16kHz mono PCM
        final hasPermission = await _recorder.hasPermission();
        if (!hasPermission) break;

        await _recorder.start(
          const RecordConfig(
            encoder: AudioEncoder.wav,
            sampleRate: 16000,
            numChannels: 1,
          ),
          path: audioPath,
        );

        await Future.delayed(const Duration(milliseconds: 2500));
        final path = await _recorder.stop();

        if (path != null && File(path).existsSync()) {
          await _processAudioChunk(path);
        }
      }
    } catch (e) {
      debugPrint("⚠️ Audio Loop Error: $e");
      _isListening = false;
      _restartListeningIfNeeded();
    }
  }

  /// Process 2.5s chunk across YAMNet & Whisper engines
  static Future<void> _processAudioChunk(String filePath) async {
    if (_isTriggered || !isEnabledNotifier.value) return;

    try {
      final file = File(filePath);
      final bytes = await file.readAsBytes();

      // Convert raw PCM bytes to Float32List for YAMNet
      Float32List float32Pcm = _convertBytesToFloat32(bytes);

      bool emergencyTriggered = false;
      String triggerReason = "";
      String acousticTag = "";

      // --- ENGINE 1: YAMNet Offline Acoustic Shield ---
      final yamnetResult = await _yamnetService.classifyAudioFrame(float32Pcm);
      if (yamnetResult != null && yamnetResult.isDistress) {
        emergencyTriggered = true;
        acousticTag = yamnetResult.label;
        triggerReason = "YAMNet Shield: ${yamnetResult.label} (${(yamnetResult.confidence * 100).toStringAsFixed(0)}%)";
        debugPrint("🚨 $triggerReason");
      }

      // --- ENGINE 2: Local Whisper Offline STT ---
      String transcript = await LocalWhisperService.transcribe(filePath);
      String cleanTranscript = _sanitizeText(transcript);

      if (cleanTranscript.isNotEmpty) {
        _rollingTranscript.add(transcript);
        if (_rollingTranscript.length > 8) _rollingTranscript.removeAt(0);
        transcriptNotifier.value = recentTranscript;
        debugPrint("🎙️ Whisper Offline Transcript: $cleanTranscript");
      }

      if (!emergencyTriggered && cleanTranscript.isNotEmpty) {
        for (String keyword in activeKeywords) {
          String cleanKeyword = _sanitizeText(keyword);
          if (cleanTranscript.contains(cleanKeyword)) {
            emergencyTriggered = true;
            triggerReason = "Whisper Keyword: '$keyword'";
            debugPrint("🚨 $triggerReason");
            break;
          }
        }
      }

      // --- INSTANT OFFLINE EMERGENCY DISPATCH ---
      if (emergencyTriggered && !_isTriggered) {
        _isTriggered = true;

        // SOLUTION 3 FIX: Ensure recorder is stopped and wait 600ms for Android to release physical mic
        if (await _recorder.isRecording()) {
          await _recorder.stop();
        }
        await Future.delayed(const Duration(milliseconds: 600));

        await EmergencyService.triggerEmergencyDispatch(
          force: 0.0,
          level: triggerReason,
          audioTranscript: transcript,
        );

        onSosTriggered?.call();

        // --- ASYNC HYBRID GEMINI ENRICHMENT (NON-BLOCKING) ---
        _enrichWithGeminiIfOnline(
          transcript: transcript,
          acousticLabel: acousticTag,
        );

        Timer(const Duration(seconds: 10), () {
          _isTriggered = false;
        });
      }
    } catch (e) {
      debugPrint("❌ Error processing audio chunk: $e");
    }
  }

  /// Converts 16-bit PCM WAV byte buffer to Float32 sample vector
  static Float32List _convertBytesToFloat32(Uint8List bytes) {
    // Skip 44-byte WAV header if present
    int offset = bytes.length > 44 ? 44 : 0;
    int numSamples = (bytes.length - offset) ~/ 2;
    Float32List samples = Float32List(numSamples);

    ByteData byteData = ByteData.sublistView(bytes, offset);
    for (int i = 0; i < numSamples; i++) {
      int sample = byteData.getInt16(i * 2, Endian.little);
      samples[i] = sample / 32768.0; // Normalize Int16 to [-1.0, 1.0]
    }
    return samples;
  }

  /// Sends telemetry to Gemini API asynchronously if internet is present
  static Future<void> _enrichWithGeminiIfOnline({
    required String transcript,
    required String acousticLabel,
  }) async {
    try {
      final connectivity = await Connectivity().checkConnectivity();
      if (connectivity.contains(ConnectivityResult.none)) {
        debugPrint("📡 Network unavailable. Skipping Gemini enrichment (Offline dispatch prioritized).");
        return;
      }

      final analysis = await AIService.analyzeIncidentContext(
        transcript: transcript,
        acousticLabel: acousticLabel,
      );

      if (analysis != null) {
        debugPrint("🧠 Gemini Incident Enrichment: [${analysis.threatLevel}] ${analysis.threatSummary}");
        EmergencyService.updateIncidentContext(analysis.threatSummary);
      }
    } catch (e) {
      debugPrint("⚠️ Non-blocking Gemini enrichment skipped: $e");
    }
  }

  static void _restartListeningIfNeeded() {
    if (!_isListening && !_isTriggered && isEnabledNotifier.value) {
      Future.delayed(const Duration(milliseconds: 1000), () {
        startListening();
      });
    }
  }

  static Future<void> stopListening() async {
    _isListening = false;
    await _audioStreamSub?.cancel();
    _audioStreamSub = null;
    await _recorder.stop();
  }

  static void clearTranscriptBuffer() {
    _rollingTranscript.clear();
    if (isEnabledNotifier.value) {
      transcriptNotifier.value = '';
    }
  }
}