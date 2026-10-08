import 'dart:math';
import 'dart:typed_data';

/// Lower-cases and strips punctuation so keywords match Whisper output.
String sanitizeText(String input) {
  return input
      .toLowerCase()
      .replaceAll(RegExp(r'[^\w\s]'), '')
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

  const DistressResult({
    required this.topLabel,
    required this.topScore,
    required this.distressLabel,
    required this.distressScore,
    required this.isDistress,
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

  final List<String> labels;
  final Set<String> distressLabels;
  final double threshold;
  late final List<int> _distressIdx;

  DistressClassifier(
    this.labels, {
    this.distressLabels = defaultDistressLabels,
    this.threshold = 0.5,
  }) {
    _distressIdx = [
      for (int i = 0; i < labels.length; i++)
        if (distressLabels.contains(labels[i])) i
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
    return DistressResult(
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
