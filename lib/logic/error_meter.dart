import 'pdr_engine.dart' show distanceM;

/// Ground-truth error meter. While "Simulate GPS loss" is on, the real GPS is
/// still read silently; it is compared with the dead-reckoned estimate and is
/// never used to compute that estimate.
///
/// The "truth" is itself a GPS reading with its own error (typically 3-10 m
/// outdoors, more near buildings), and it can be up to [maxTruthAgeMs] old, so
/// small errors measured here are not exact.
class ErrorMeter {
  /// Truth older than this is not compared (the walker has moved on).
  static const int maxTruthAgeMs = 15000;

  bool _active = false;
  bool _hasRun = false;
  int _startMs = 0;
  double _walkedM = 0;
  double? _errorM;
  double _maxErrorM = 0;
  double? _truthLat, _truthLng;
  int _truthMs = 0;

  bool get active => _active;
  bool get hasRun => _hasRun;
  double get walkedM => _walkedM;

  /// Latest error vs real GPS, or null when there is no usable truth yet.
  double? get errorM => _errorM;
  double get maxErrorM => _maxErrorM;
  int get startMs => _startMs;
  bool get hasTruth => _truthLat != null;
  double? get truthLat => _truthLat;
  double? get truthLng => _truthLng;
  int get truthMs => _truthMs;

  /// Error as a percentage of the distance walked since GPS loss.
  double? get percent =>
      _errorM == null || _walkedM < 1 ? null : _errorM! / _walkedM * 100;

  void start(int nowMs) {
    _active = true;
    _hasRun = true;
    _startMs = nowMs;
    _walkedM = 0;
    _errorM = null;
    _maxErrorM = 0;
  }

  /// Freezes the numbers so the summary stays readable after the run.
  void stop() => _active = false;

  void onTruth(double lat, double lng, int ms) {
    _truthLat = lat;
    _truthLng = lng;
    _truthMs = ms;
  }

  /// Compares the current estimate with the latest truth.
  void onEstimate(double lat, double lng, double walkedM, int nowMs) {
    if (!_active) return;
    _walkedM = walkedM;
    final tl = _truthLat, tg = _truthLng;
    if (tl == null || tg == null || nowMs - _truthMs > maxTruthAgeMs) return;
    final e = distanceM(lat, lng, tl, tg);
    _errorM = e;
    if (e > _maxErrorM) _maxErrorM = e;
  }

  /// Screenshot-friendly one-liner, e.g. "112 m walked, final error 9 m, 8%".
  String summary() {
    if (!_hasRun) return 'No run yet: switch Simulate GPS loss on and walk.';
    final walked = '${_walkedM.round()} m walked';
    if (_errorM == null) return '$walked, no real GPS reading to compare with';
    final p = percent;
    final pct = p == null ? '' : ', ${p.round()}%';
    final label = _active ? 'current error' : 'final error';
    return '$walked, $label ${_errorM!.round()} m$pct';
  }
}
