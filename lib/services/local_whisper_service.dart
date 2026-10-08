import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:whisper_ggml_plus/whisper_ggml_plus.dart';

class LocalWhisperService {
  static bool _isInitialized = false;
  static const WhisperModel _model = WhisperModel.tiny;
  static const String _modelAssetPath = 'assets/models/ggml-tiny.bin';

  static final WhisperController _controller = WhisperController();

  /// Copies the bundled quantized GGML tiny model into the app's model
  /// directory (if it isn't there yet) so transcription works fully offline.
  static Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      final String modelPath = await _controller.getPath(_model);
      final File modelFile = File(modelPath);

      if (!await modelFile.exists()) {
        final ByteData data = await rootBundle.load(_modelAssetPath);
        await modelFile.parent.create(recursive: true);
        await modelFile.writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        );
      }

      _isInitialized = true;
      debugPrint("✅ Local Whisper GGML Engine ready (model at $modelPath).");
    } catch (e) {
      debugPrint("❌ Failed to initialize local Whisper model: $e");
    }
  }

  /// Transcribes a recorded local audio file offline.
  /// Note: the file must be 16kHz mono WAV unless you also add
  /// whisper_ggml_plus_ffmpeg for automatic conversion.
  static Future<String> transcribe(String audioFilePath) async {
    if (!_isInitialized) {
      await initialize();
    }

    try {
      final result = await _controller.transcribe(
        model: _model,
        audioPath: audioFilePath,
        lang: 'auto',
      );

      return result?.transcription.text.trim() ?? "";
    } catch (e) {
      debugPrint("❌ Whisper GGML Transcription Error: $e");
      return "";
    }
  }
}