import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'emergency_service.dart';

class VoiceService {
  static final SpeechToText _speech = SpeechToText();
  static bool _isListening = false;
  static bool _isInitialized = false;
  static bool _isTriggered = false;

  /// Global state toggle for user privacy
  static final ValueNotifier<bool> isEnabledNotifier = ValueNotifier<bool>(true);

  /// Reactive notifier to update UI transcript live
  static final ValueNotifier<String> transcriptNotifier = ValueNotifier<String>('');

  /// Reactive notifier for current active keywords (UI state sync)
  static final ValueNotifier<List<String>> keywordsNotifier = ValueNotifier<List<String>>([]);

  static final List<String> _rollingTranscript = [];
  static const String _customKeywordsKey = "custom_voice_keywords";

  /// Default emergency words
  static final List<String> _defaultKeywords = [
    'help',
    'sos',
    'emergency',
    'save me',
    'danger',
    'call police',
  ];

  static List<String> activeKeywords = [..._defaultKeywords];
  static Function()? onSosTriggered;

  static String get recentTranscript => _rollingTranscript.join(" ");

  /// Initialize and start listening loop
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
      _isInitialized = await _speech.initialize(
        onError: (val) {
          debugPrint('🎙️ Voice Error: ${val.errorMsg}');
          _restartListeningIfNeeded();
        },
        onStatus: (status) {
          debugPrint('🎙️ Voice Status: $status');
          if (status == 'done' || status == 'notListening') {
            _restartListeningIfNeeded();
          }
        },
      );
    }

    if (_isInitialized && !_isListening) {
      _listen();
    }
  }

  /// Turn voice monitoring ON or OFF
  static Future<void> toggleVoiceMonitoring(bool enabled) async {
    isEnabledNotifier.value = enabled;
    if (enabled) {
      await startListening();
    } else {
      stopListening();
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

  /// Remove a custom trigger keyword (Default keywords cannot be removed)
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
        .replaceAll(RegExp(r'[^\w\s]'), '') // Strip punctuation
        .replaceAll(RegExp(r'\s+'), ' ')    // Normalize spaces
        .trim();
  }

  static void _listen() {
    if (!isEnabledNotifier.value) return;

    _isListening = true;
    _speech.listen(
      listenFor: const Duration(seconds: 30),
      pauseFor: const Duration(seconds: 5),
      partialResults: true,
      onDevice: true, // Local offline recognition where supported
      onResult: (val) {
        String rawPhrase = val.recognizedWords;
        String cleanPhrase = _sanitizeText(rawPhrase);
        if (cleanPhrase.isEmpty) return;

        if (_rollingTranscript.isEmpty || _rollingTranscript.last != rawPhrase) {
          _rollingTranscript.add(rawPhrase);
          if (_rollingTranscript.length > 10) {
            _rollingTranscript.removeAt(0);
          }
          transcriptNotifier.value = recentTranscript;
        }

        debugPrint("🎙️ Speech Log (Clean): $cleanPhrase");

        // Scan against active keywords
        if (!_isTriggered && isEnabledNotifier.value) {
          for (String keyword in activeKeywords) {
            String cleanKeyword = _sanitizeText(keyword);
            if (cleanPhrase.contains(cleanKeyword)) {
              _isTriggered = true;
              stopListening();

              // Pass both the keyword level AND the actual raw transcript to Gemini!
              EmergencyService.triggerEmergencyDispatch(
                force: 0.0,
                level: "Voice Trigger ('$keyword')",
                audioTranscript: rawPhrase,
              );

              onSosTriggered?.call();

              Timer(const Duration(seconds: 10), () {
                _isTriggered = false;
              });
              break;
            }
          }
        }
      },
    );
  }

  static void _restartListeningIfNeeded() {
    if (_isListening && !_isTriggered && isEnabledNotifier.value) {
      _isListening = false;
      Future.delayed(const Duration(milliseconds: 500), () {
        startListening();
      });
    }
  }

  static void stopListening() {
    _isListening = false;
    _speech.stop();
  }

  static void clearTranscriptBuffer() {
    _rollingTranscript.clear();
    if (isEnabledNotifier.value) {
      transcriptNotifier.value = '';
    }
  }
}