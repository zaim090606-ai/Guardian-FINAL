/// What the user is probably doing, inferred from sound and step activity.
enum MotionContext { walking, stationary, vehicle, unknown }

class LabelScore {
  final String label;
  final double score;
  const LabelScore(this.label, this.score);
}

/// YAMNet class names (exactly as in assets/models/yamnet_labels.txt) that
/// mean "the user is inside or next to a moving vehicle". Sirens, horns and
/// alarms are deliberately left out: they can be heard on foot.
const Set<String> vehicleLabels = {
  'Vehicle',
  'Motor vehicle (road)',
  'Car',
  'Car passing by',
  'Race car, auto racing',
  'Truck',
  'Bus',
  'Motorcycle',
  'Traffic noise, roadway noise',
  'Rail transport',
  'Train',
  'Railroad car, train wagon',
  'Subway, metro, underground',
  'Aircraft',
  'Aircraft engine',
  'Jet engine',
  'Propeller, airscrew',
  'Helicopter',
  'Fixed-wing aircraft, airplane',
  'Engine',
  'Light engine (high frequency)',
  'Medium engine (mid frequency)',
  'Heavy engine (low frequency)',
  'Accelerating, revving, vroom',
  'Idling',
};

/// Classifies motion context from audio chunks and step activity.
///
/// Vehicle needs [enterChunks] consecutive chunks with a vehicle label at
/// [minScore] or more; leaving vehicle needs [leaveChunks] consecutive chunks
/// without one (hysteresis, so one odd chunk does not flip the state).
/// When no labels are available (YAMNet not loaded) the context is unknown.
class MotionContextClassifier {
  final double minScore;
  final int enterChunks;
  final int leaveChunks;
  final int stationaryAfterMs;

  int _vehicleRun = 0;
  int _otherRun = 0;
  bool _inVehicle = false;
  bool _hasAudio = false;

  MotionContextClassifier({
    this.minScore = 0.4,
    this.enterChunks = 3,
    this.leaveChunks = 3,
    this.stationaryAfterMs = 10000,
  });

  bool get inVehicle => _inVehicle;

  /// Highest vehicle-class score in [labels], 0 if none.
  static double vehicleScore(Iterable<LabelScore> labels) {
    double best = 0;
    for (final l in labels) {
      if (vehicleLabels.contains(l.label) && l.score > best) best = l.score;
    }
    return best;
  }

  /// Feeds one audio chunk's labels. Null means "no audio classifier".
  void addChunk(List<LabelScore>? labels) {
    if (labels == null) {
      reset();
      return;
    }
    _hasAudio = true;
    if (vehicleScore(labels) >= minScore) {
      _vehicleRun++;
      _otherRun = 0;
    } else {
      _otherRun++;
      _vehicleRun = 0;
    }
    if (!_inVehicle && _vehicleRun >= enterChunks) _inVehicle = true;
    if (_inVehicle && _otherRun >= leaveChunks) _inVehicle = false;
  }

  void reset() {
    _vehicleRun = _otherRun = 0;
    _inVehicle = false;
    _hasAudio = false;
  }

  /// Context now, given the time of the latest step (null = none yet).
  MotionContext contextAt(int nowMs, int? lastStepMs) {
    if (!_hasAudio) return MotionContext.unknown;
    if (_inVehicle) return MotionContext.vehicle;
    if (lastStepMs != null && nowMs - lastStepMs <= stationaryAfterMs) {
      return MotionContext.walking;
    }
    return MotionContext.stationary;
  }

  /// Convenience: [addChunk] then [contextAt].
  MotionContext update({
    required List<LabelScore>? labels,
    required int nowMs,
    int? lastStepMs,
  }) {
    addChunk(labels);
    return contextAt(nowMs, lastStepMs);
  }
}
