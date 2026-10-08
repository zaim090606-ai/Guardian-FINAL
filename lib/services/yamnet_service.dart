import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../logic/trigger_logic.dart';

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

/// Offline sound classifier (YAMNet, 521 AudioSet classes) used to spot
/// screams, sirens, glass breaking and similar. If the model cannot be loaded
/// [isAvailable] stays false and every classify call returns null.
class YamnetService {
  static const int windowSamples = 15600; // 0.975 s at 16 kHz
  static const int _classCount = 521;

  Interpreter? _interpreter;
  DistressClassifier? _classifier;
  bool _failed = false;
  List<int> _outputIndexes = const [];
  int _scoreOutput = 0;
  List<List<int>> _outputShapes = const [];

  bool get isAvailable => _interpreter != null && _classifier != null;

  Future<void> initialize() async {
    if (isAvailable || _failed) return;
    try {
      final options = InterpreterOptions()..threads = 2;
      final interpreter = await Interpreter.fromAsset(
        'assets/models/yamnet.tflite',
        options: options,
      );

      final labelData =
          await rootBundle.loadString('assets/models/yamnet_labels.txt');
      final labels = labelData
          .split('\n')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList();

      final outputs = interpreter.getOutputTensors();
      _outputShapes = [for (final t in outputs) List<int>.from(t.shape)];
      _outputIndexes = List.generate(outputs.length, (i) => i);
      _scoreOutput = _outputShapes.indexWhere(
        (s) => s.isNotEmpty && s.last == _classCount,
      );
      if (_scoreOutput < 0) {
        throw StateError('no ${_classCount}-class output in YAMNet model');
      }

      final classifier = DistressClassifier(labels);
      if (!classifier.hasDistressClasses) {
        throw StateError('label file has none of the distress classes');
      }

      _interpreter = interpreter;
      _classifier = classifier;
      debugPrint('YAMNet loaded (outputs: $_outputShapes).');
    } catch (e) {
      _failed = true;
      _interpreter?.close();
      _interpreter = null;
      debugPrint('YAMNet unavailable, sound detection off: $e');
    }
  }

  /// Classifies one 15 600-sample window (shorter input is zero padded).
  Future<DistressResult?> classifyWindow(Float32List pcm) async {
    final interpreter = _interpreter;
    final classifier = _classifier;
    if (interpreter == null || classifier == null) return null;

    try {
      final input = Float32List(windowSamples);
      final n = pcm.length > windowSamples ? windowSamples : pcm.length;
      input.setRange(0, n, pcm);

      final outputs = <int, Object>{
        for (final i in _outputIndexes)
          i: List<double>.filled(
            _outputShapes[i].fold<int>(1, (a, b) => a * b),
            0.0,
          ).reshape(_outputShapes[i]),
      };
      interpreter.runForMultipleInputs([input], outputs);

      final flat = <double>[];
      _flatten(outputs[_scoreOutput]!, flat);
      // Output may hold several frames; keep the strongest score per class.
      final scores = List<double>.filled(_classCount, 0.0);
      for (int i = 0; i < flat.length; i++) {
        final c = i % _classCount;
        if (flat[i] > scores[c]) scores[c] = flat[i];
      }
      return classifier.classify(scores);
    } catch (e) {
      debugPrint('YAMNet inference error: $e');
      return null;
    }
  }

  /// Splits a recording into consecutive windows and classifies each.
  Future<List<DistressResult>> classifySamples(Float32List pcm) async {
    final results = <DistressResult>[];
    for (int start = 0;
        start + windowSamples ~/ 2 <= pcm.length;
        start += windowSamples) {
      final end =
          start + windowSamples > pcm.length ? pcm.length : start + windowSamples;
      final r = await classifyWindow(Float32List.sublistView(pcm, start, end));
      if (r != null) results.add(r);
    }
    return results;
  }

  /// Single-window convenience used by the evidence analysis.
  Future<YamnetResult?> classifyAudioFrame(Float32List pcm) async {
    final r = await classifyWindow(pcm);
    if (r == null) return null;
    return YamnetResult(
      label: r.isDistress ? r.distressLabel : r.topLabel,
      confidence: r.isDistress ? r.distressScore : r.topScore,
      isDistress: r.isDistress,
    );
  }

  static void _flatten(Object o, List<double> out) {
    if (o is num) {
      out.add(o.toDouble());
    } else if (o is List) {
      for (final e in o) {
        _flatten(e as Object, out);
      }
    }
  }

  void dispose() {
    _interpreter?.close();
    _interpreter = null;
    _classifier = null;
  }
}
