import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:record/record.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logic/trigger_logic.dart';
import 'ai_service.dart';
import 'audio_recorder_service.dart';
import 'emergency_service.dart';
import 'diagnostics_hub.dart';
import 'local_whisper_service.dart';
import 'sos_countdown_service.dart';
import 'pdr_services.dart';
import 'yamnet_service.dart';

/// Always-on offline audio monitor.
///
/// The microphone loop only runs in the foreground-service isolate
/// (`startListening(background: true)`); the UI isolate just mirrors the
/// transcript and forwards the on/off switch, so two recorders never compete
/// for the microphone. Sound classes come from YAMNet and spoken keywords
/// from Whisper, which only runs on a chunk after YAMNet flagged speech, a
/// scream or a siren, or after the user taps the listen button. Either engine can be missing (permission, model load
/// failure, slow device) and the other keeps working.
class VoiceService {
  static AudioRecorder? _recorder;
  static final YamnetService _yamnetService = YamnetService();
  static final DistressDebouncer _debouncer = DistressDebouncer();

  static bool _isListening = false;
  static bool _enginesReady = false;
  static bool _isTriggered = false;
  static bool _uiAttached = false;
  static int _slowWhisperRuns = 0;
  static bool _userRequestedTranscript = false;

  /// Global state toggle for user privacy
  static final ValueNotifier<bool> isEnabledNotifier = ValueNotifier<bool>(true);

  /// Reactive notifier to update UI transcript live
  static final ValueNotifier<String> transcriptNotifier = ValueNotifier<String>('');

  /// Reactive notifier for current active keywords (UI state sync)
  static final ValueNotifier<List<String>> keywordsNotifier = ValueNotifier<List<String>>([]);

  /// Set by the service isolate to mirror transcripts to the UI.
  static void Function(String transcript)? onTranscript;

  static final List<String> _rollingTranscript = [];
  static const String _customKeywordsKey = 'custom_voice_keywords';
  static const Duration _chunk = Duration(milliseconds: 2500);

  static final List<String> _defaultKeywords = [
    'help',
    'sos',
    'emergency',
    'save me',
    'danger',
    'call police',
    'bachao',
    'madad',
    'बचाओ',
    'मदद',
  ];

  static List<String> activeKeywords = [..._defaultKeywords];

  static String get recentTranscript => _rollingTranscript.join(' ');

  /// UI isolate: loads keywords and mirrors the service's transcript.
  /// Service isolate (`background: true`): starts the microphone loop.
  static Future<void> startListening({bool background = false}) async {
    await loadCustomKeywords();

    if (!background) {
      _attachToService();
      return;
    }

    if (!isEnabledNotifier.value) {
      debugPrint('Voice monitoring is disabled by the user.');
      return;
    }
    if (_isListening) return;

    // The service isolate cannot show a permission dialog, so only check.
    final hub = DiagnosticsHub.instance;
    if (!await Permission.microphone.isGranted) {
      hub.micStatus = 'denied';
      debugPrint('Microphone permission missing: audio triggers are off.');
      return;
    }
    hub.micStatus = 'granted';

    if (!_enginesReady) {
      await _yamnetService.initialize();
      await LocalWhisperService.initialize();
      _enginesReady = true;
    }
    hub.yamnetLoaded = _yamnetService.isAvailable;
    hub.whisperLoaded = LocalWhisperService.isAvailable;
    if (!_yamnetService.isAvailable && !LocalWhisperService.isAvailable) {
      debugPrint('No audio engine could be loaded: audio triggers are off.');
      return;
    }

    unawaited(_chunkLoop());
  }

  static void _attachToService() {
    if (_uiAttached) return;
    _uiAttached = true;
    try {
      FlutterBackgroundService().on('transcript').listen((event) {
        final text = event?['text'];
        if (text is String) transcriptNotifier.value = text;
      });
    } catch (e) {
      debugPrint('Could not attach to background service: $e');
    }
  }

  /// Button: transcribe the next chunk with Whisper regardless of YAMNet.
  static void requestTranscription({bool fromService = false}) {
    if (!fromService) {
      try {
        FlutterBackgroundService().invoke('voice_transcribe_now');
      } catch (_) {}
      return;
    }
    _userRequestedTranscript = true;
  }

  /// Turn voice monitoring ON or OFF (from the UI or the service isolate).
  static Future<void> toggleVoiceMonitoring(bool enabled,
      {bool fromService = false}) async {
    isEnabledNotifier.value = enabled;
    if (!fromService) {
      try {
        FlutterBackgroundService().invoke('voice_enabled', {'enabled': enabled});
      } catch (_) {}
      if (!enabled) transcriptNotifier.value = 'Voice Monitoring Paused';
      return;
    }
    if (enabled) {
      await startListening(background: true);
    } else {
      await stopListening();
    }
  }

  static Future<void> loadCustomKeywords() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    final saved = prefs.getStringList(_customKeywordsKey);
    activeKeywords = [..._defaultKeywords];
    if (saved != null) {
      for (final item in saved) {
        if (!activeKeywords.contains(item)) activeKeywords.add(item);
      }
    }
    keywordsNotifier.value = List.unmodifiable(activeKeywords);
  }

  static Future<bool> addCustomKeyword(String word) async {
    final cleanWord = sanitizeText(word);
    if (cleanWord.isEmpty || activeKeywords.contains(cleanWord)) return false;

    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_customKeywordsKey) ?? [];
    if (!saved.contains(cleanWord)) {
      saved.add(cleanWord);
      await prefs.setStringList(_customKeywordsKey, saved);
    }
    await loadCustomKeywords();
    return true;
  }

  static Future<bool> removeCustomKeyword(String word) async {
    final cleanWord = sanitizeText(word);
    if (_defaultKeywords.contains(cleanWord)) return false;

    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_customKeywordsKey) ?? [];
    if (saved.contains(cleanWord)) {
      saved.remove(cleanWord);
      await prefs.setStringList(_customKeywordsKey, saved);
      await loadCustomKeywords();
      return true;
    }
    return false;
  }

  /// Records 2.5 s slices and runs both engines on each one.
  static Future<void> _chunkLoop() async {
    if (_isListening) return;
    _isListening = true;
    debugPrint('Audio monitor running '
        '(YAMNet: ${_yamnetService.isAvailable}, '
        'Whisper: ${LocalWhisperService.isAvailable}).');

    int failures = 0;
    try {
      final dir = await getTemporaryDirectory();
      final recorder = _recorder ??= AudioRecorder();

      while (_isListening && isEnabledNotifier.value) {
        // Stay off the microphone while an SOS is being handled or evidence
        // audio is being recorded.
        if (_isTriggered || AudioRecorderService.isCapturing) {
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }

        try {
          if (!await recorder.hasPermission()) {
            debugPrint('Microphone permission revoked: stopping monitor.');
            break;
          }
          final audioPath = '${dir.path}/temp_audio_chunk.wav';
          await recorder.start(
            const RecordConfig(
              encoder: AudioEncoder.wav,
              sampleRate: 16000,
              numChannels: 1,
            ),
            path: audioPath,
          );
          await Future<void>.delayed(_chunk);
          final path = await recorder.stop();
          failures = 0;

          if (path != null && File(path).existsSync()) {
            await _processAudioChunk(path);
          }
        } catch (e) {
          failures++;
          debugPrint('Audio chunk failed ($failures): $e');
          try {
            await recorder.stop();
          } catch (_) {}
          if (failures >= 5) {
            debugPrint('Microphone keeps failing: stopping monitor.');
            break;
          }
          await Future<void>.delayed(Duration(seconds: 2 * failures));
        }
      }
    } catch (e) {
      debugPrint('Audio loop error: $e');
    } finally {
      _isListening = false;
    }
  }

  static Future<void> _processAudioChunk(String filePath) async {
    if (_isTriggered || !isEnabledNotifier.value) return;

    try {
      final bytes = await File(filePath).readAsBytes();
      final samples = _pcm16WavToFloat32(bytes);

      // Quiet room: nothing to classify, and Whisper would only hallucinate.
      if (isSilent(samples)) {
        _debouncer.add(false);
        return;
      }

      bool acousticConfirmed = false;
      String acousticLabel = '';
      double acousticScore = 0;
      double speechScore = 0;

      if (_yamnetService.isAvailable) {
        final results = await _yamnetService.classifySamples(samples);
        for (final r in results) {
          final hub = DiagnosticsHub.instance;
          hub.lastLabel = r.isDistress ? r.distressLabel : r.topLabel;
          hub.lastScore = r.isDistress ? r.distressScore : r.topScore;
          hub.lastDetectionMs = DateTime.now().millisecondsSinceEpoch;
          PdrService().onSoundLabels(r.labelScores);
          if (r.speechScore > speechScore) speechScore = r.speechScore;
          if (_debouncer.add(r.isDistress)) {
            acousticConfirmed = true;
            acousticLabel = r.distressLabel;
            acousticScore = r.distressScore;
          }
        }
      }

      String transcript = '';
      final userRequested = _userRequestedTranscript;
      _userRequestedTranscript = false;
      if (shouldRunWhisper(
        whisperAvailable: LocalWhisperService.isAvailable,
        yamnetAvailable: _yamnetService.isAvailable,
        speechScore: speechScore,
        userRequested: userRequested,
        acousticConfirmed: acousticConfirmed,
      )) {
        final sw = Stopwatch()..start();
        transcript = await LocalWhisperService.transcribe(filePath);
        sw.stop();
        _trackWhisperSpeed(sw.elapsed);

        if (sanitizeText(transcript).isNotEmpty) {
          _rollingTranscript.add(transcript);
          if (_rollingTranscript.length > 8) _rollingTranscript.removeAt(0);
          transcriptNotifier.value = recentTranscript;
          onTranscript?.call(recentTranscript);
        }
      }

      final reason = decideTrigger(
        acousticConfirmed: acousticConfirmed,
        acousticLabel: acousticLabel,
        acousticScore: acousticScore,
        transcript: transcript,
        keywords: activeKeywords,
      );
      if (reason == null) return;

      debugPrint('Audio trigger: $reason');
      _isTriggered = true;
      _debouncer.reset();
      try {
        // Give the user a chance to cancel a false alarm before anything is sent.
        if (!await SosCountdownService.confirm(reason)) {
          debugPrint('Audio SOS cancelled by the user.');
          return;
        }
        await EmergencyService.triggerEmergencyDispatch(
          force: 0.0,
          level: reason,
          audioTranscript: transcript,
        );
        unawaited(_enrichWithGeminiIfOnline(
          transcript: transcript,
          acousticLabel: acousticLabel,
        ));
      } finally {
        Timer(const Duration(seconds: 10), () => _isTriggered = false);
      }
    } catch (e) {
      debugPrint('Error processing audio chunk: $e');
    }
  }

  /// A device that needs far longer than the chunk length to transcribe it
  /// cannot keep up, so Whisper is switched off and YAMNet carries on alone.
  static void _trackWhisperSpeed(Duration took) {
    if (took > const Duration(seconds: 8)) {
      _slowWhisperRuns++;
      if (_slowWhisperRuns >= 3) {
        LocalWhisperService.disable();
        debugPrint('Whisper too slow on this device: speech keywords off.');
      }
    } else {
      _slowWhisperRuns = 0;
    }
  }

  /// Reads 16-bit PCM from a WAV file as floats in [-1, 1].
  static Float32List _pcm16WavToFloat32(Uint8List bytes) {
    final offset = bytes.length > 44 ? 44 : 0;
    final n = (bytes.length - offset) ~/ 2;
    final out = Float32List(n);
    final data = ByteData.sublistView(bytes, offset);
    for (int i = 0; i < n; i++) {
      out[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return out;
  }

  /// Optional online enhancement; the SOS has already been sent.
  static Future<void> _enrichWithGeminiIfOnline({
    required String transcript,
    required String acousticLabel,
  }) async {
    try {
      final connectivity = await Connectivity().checkConnectivity();
      if (connectivity.contains(ConnectivityResult.none)) return;

      final analysis = await AIService.analyzeIncidentContext(
        transcript: transcript,
        acousticLabel: acousticLabel,
      );
      if (analysis != null) {
        EmergencyService.updateIncidentContext(analysis.threatSummary);
      }
    } catch (e) {
      debugPrint('Gemini enrichment skipped: $e');
    }
  }

  static Future<void> stopListening() async {
    _isListening = false;
    try {
      await _recorder?.stop();
    } catch (_) {}
  }

  static void clearTranscriptBuffer() {
    _rollingTranscript.clear();
    if (isEnabledNotifier.value) transcriptNotifier.value = '';
  }
}
