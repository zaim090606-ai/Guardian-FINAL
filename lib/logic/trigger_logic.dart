import 'dart:math';
import 'dart:typed_data';

import 'motion_context.dart';

/// Lower-cases and strips punctuation so keywords match Whisper output.
String sanitizeText(String input) {
  return input
      .toLowerCase()
      .replaceAll(RegExp(r'[^\p{L}\p{N}_\s]', unicode: true), '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

/// Returns the first keyword found as whole word(s) in [transcript], or null.
String? matchKeyword(String transcript, Iterable<String> keywords) {
  final clean = ' ${sanitizeText(transcript)} ';
  if (clean.trim().isEmpty) return null;
  for (final k in keywords) {
    final ck = sanitizeText(k);
    if (ck.isEmpty) continue;
    if (clean.contains(' $ck ')) return k;
  }
  return null;
}

/// Root-mean-square level of normalised samples.
double rms(Float32List samples) {
  if (samples.isEmpty) return 0.0;
  double sum = 0;
  for (final s in samples) {
    sum += s * s;
  }
  return sqrt(sum / samples.length);
}

/// True when a chunk is quiet enough that transcribing it is wasted effort.
bool isSilent(Float32List samples, {double threshold = 0.005}) =>
    rms(samples) < threshold;

class DistressResult {
  final String topLabel;
  final double topScore;
  final String distressLabel;
  final double distressScore;
  final bool isDistress;

  /// Best score among speech-like classes (speech, shouting, screaming, siren).
  final double speechScore;

  /// Every class scoring at least 0.1, used for the motion context.
  final List<LabelScore> labelScores;

  const DistressResult({
    required this.topLabel,
    required this.topScore,
    required this.distressLabel,
    required this.distressScore,
    required this.isDistress,
    this.speechScore = 0,
    this.labelScores = const [],
  });
}

/// Turns a 521-way YAMNet score vector into a distress decision. It looks at
/// the best-scoring distress class, not only the arg-max class, so a scream
/// over speech still counts.
class DistressClassifier {
  static const Set<String> defaultDistressLabels = {
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

  /// Classes that justify spending CPU on a Whisper transcription.
  static const Set<String> speechLabels = {
    'Speech',
    'Shout',
    'Yell',
    'Screaming',
    'Siren',
  };

  final List<String> labels;
  final Set<String> distressLabels;
  final double threshold;
  late final List<int> _distressIdx;
  late final List<int> _speechIdx;

  DistressClassifier(
    this.labels, {
    this.distressLabels = defaultDistressLabels,
    this.threshold = 0.5,
  }) {
    _distressIdx = [
      for (int i = 0; i < labels.length; i++)
        if (distressLabels.contains(labels[i])) i
    ];
    _speechIdx = [
      for (int i = 0; i < labels.length; i++)
        if (speechLabels.contains(labels[i])) i
    ];
  }

  bool get hasDistressClasses => _distressIdx.isNotEmpty;

  DistressResult classify(List<double> scores) {
    int top = 0;
    for (int i = 1; i < scores.length; i++) {
      if (scores[i] > scores[top]) top = i;
    }
    int best = -1;
    for (final i in _distressIdx) {
      if (i < scores.length && (best < 0 || scores[i] > scores[best])) best = i;
    }
    final topLabel = top < labels.length ? labels[top] : 'Unknown';
    final topScore = scores.isEmpty ? 0.0 : scores[top];
    final dLabel = best >= 0 ? labels[best] : '';
    final dScore = best >= 0 ? scores[best] : 0.0;
    double speech = 0;
    for (final i in _speechIdx) {
      if (i < scores.length && scores[i] > speech) speech = scores[i];
    }
    return DistressResult(
      labelScores: [
        for (int i = 0; i < scores.length && i < labels.length; i++)
          if (scores[i] >= 0.1) LabelScore(labels[i], scores[i])
      ],
      speechScore: speech,
      topLabel: topLabel,
      topScore: topScore,
      distressLabel: dLabel,
      distressScore: dScore,
      isDistress: best >= 0 && dScore >= threshold,
    );
  }
}

/// Requires [need] distress windows out of the last [of] windows, so a single
/// noisy window does not raise an SOS.
class DistressDebouncer {
  final int need;
  final int of;
  final List<bool> _recent = [];

  DistressDebouncer({this.need = 2, this.of = 3});

  bool add(bool distress) {
    _recent.add(distress);
    if (_recent.length > of) _recent.removeAt(0);
    return _recent.where((e) => e).length >= need;
  }

  void reset() => _recent.clear();
}

/// Decides whether the expensive Whisper pass runs on the current chunk.
/// YAMNet is the cheap always-on gate: Whisper only runs when YAMNet heard
/// speech/scream/siren, or the user asked for it. Without YAMNet there is no
/// gate, so every non-silent chunk is transcribed as before.
bool shouldRunWhisper({
  required bool whisperAvailable,
  required bool yamnetAvailable,
  required double speechScore,
  bool userRequested = false,
  bool acousticConfirmed = false,
  double speechThreshold = 0.3,
}) {
  if (!whisperAvailable) return false;
  if (acousticConfirmed) return false; // already decided, no need to transcribe
  if (userRequested) return true;
  if (!yamnetAvailable) return true;
  return speechScore >= speechThreshold;
}

/// Combines the audio engines into one decision. Returns the human-readable
/// trigger reason, or null when nothing warrants an SOS.
String? decideTrigger({
  required bool acousticConfirmed,
  String acousticLabel = '',
  double acousticScore = 0,
  String transcript = '',
  required Iterable<String> keywords,
}) {
  if (acousticConfirmed) {
    return 'YAMNet Shield: $acousticLabel (${(acousticScore * 100).round()}%)';
  }
  final k = matchKeyword(transcript, keywords);
  if (k != null) return "Whisper Keyword: '$k'";
  return null;
}
