import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:whisper_ggml_plus/whisper_ggml_plus.dart';

/// Offline speech-to-text. The GGML model ships in assets/models and is copied
/// to app storage on first run because the plugin needs a file path.
/// If the model cannot be prepared the service switches itself off and
/// [transcribe] returns an empty string; callers keep working.
class LocalWhisperService {
  static bool _isInitialized = false;
  static bool _failed = false;
  static const WhisperModel _model = WhisperModel.tiny;
  static const String _modelAssetPath = 'assets/models/ggml-tiny.bin';

  static final WhisperController _controller = WhisperController();

  /// False after a failed initialisation or when disabled for being too slow.
  static bool get isAvailable => !_failed;

  /// Turns the engine off for this session (e.g. device is too slow).
  static void disable() => _failed = true;

  static Future<void> initialize() async {
    if (_isInitialized || _failed) return;

    try {
      final String modelPath = await _controller.getPath(_model);
      final File modelFile = File(modelPath);

      if (!await modelFile.exists() || await modelFile.length() == 0) {
        final ByteData data = await rootBundle.load(_modelAssetPath);
        await modelFile.parent.create(recursive: true);
        // Write to a temp name first so an interrupted copy is never mistaken
        // for a complete model on the next start.
        final File tmp = File('$modelPath.tmp');
        await tmp.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
        await tmp.rename(modelPath);
      }

      _isInitialized = true;
      debugPrint('Local Whisper ready (model at $modelPath).');
    } catch (e) {
      _failed = true;
      debugPrint('Local Whisper unavailable, speech keywords off: $e');
    }
  }

  /// Transcribes a 16 kHz mono WAV file. Returns "" on any failure.
  static Future<String> transcribe(String audioFilePath) async {
    if (_failed) return '';
    if (!_isInitialized) await initialize();
    if (!_isInitialized) return '';

    try {
      final result = await _controller.transcribe(
        model: _model,
        audioPath: audioFilePath,
        lang: 'auto',
      );
      return result?.transcription.text.trim() ?? '';
    } catch (e) {
      debugPrint('Whisper transcription error: $e');
      return '';
    }
  }
}
