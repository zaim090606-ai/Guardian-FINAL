import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

class YamnetResult {
  final String label;
  final double confidence;
  final bool isDistress;

  YamnetResult({
    required this.label,
    required this.confidence,
    required this.isDistress,
  });
}

class YamnetService {
  Interpreter? _interpreter;
  List<String>? _labels;
  bool _isInitialized = false;

  /// High-priority acoustic distress signals
  static const Set<String> _distressLabels = {
    'Screaming',
    'Shout',
    'Yell',
    'Crying, sobbing',
    'Shatter',
    'Siren',
    'Explosion',
    'Groan',
    'Gunshot, gunfire',
  };

  /// Load TFLite model and labels from offline assets
  Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      _interpreter = await Interpreter.fromAsset('assets/models/yamnet.tflite');

      final labelData =
          await rootBundle.loadString('assets/models/yamnet_labels.txt');
      _labels = labelData
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      _isInitialized = true;
      debugPrint("✅ YAMNet TFLite Acoustic Model Loaded Successfully.");
    } catch (e) {
      debugPrint("❌ Failed to initialize YAMNet: $e");
    }
  }

  /// Classifies a 15,600 sample float vector (~0.975s audio at 16kHz)
  Future<YamnetResult?> classifyAudioFrame(Float32List pcmData) async {
    if (!_isInitialized || _interpreter == null) return null;

    try {
      // Normalize sample window length to exactly 15,600 samples required by YAMNet
      Float32List inputBuffer = Float32List(15600);
      int lengthToCopy = pcmData.length > 15600 ? 15600 : pcmData.length;
      inputBuffer.setRange(0, lengthToCopy, pcmData);

      var input = inputBuffer;
      var output = List<double>.filled(521, 0.0).reshape([1, 521]);

      _interpreter!.run(input, output);

      List<double> probabilities = List<double>.from(output[0]);

      int maxIndex = 0;
      double maxConfidence = 0.0;

      for (int i = 0; i < probabilities.length; i++) {
        if (probabilities[i] > maxConfidence) {
          maxConfidence = probabilities[i];
          maxIndex = i;
        }
      }

      String detectedLabel = (_labels != null && maxIndex < _labels!.length)
          ? _labels![maxIndex]
          : 'Unknown';

      bool isDistress =
          _distressLabels.contains(detectedLabel) && maxConfidence >= 0.50;

      return YamnetResult(
        label: detectedLabel,
        confidence: maxConfidence,
        isDistress: isDistress,
      );
    } catch (e) {
      debugPrint("❌ YAMNet Inference Error: $e");
      return null;
    }
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _isInitialized = false;
  }
}
