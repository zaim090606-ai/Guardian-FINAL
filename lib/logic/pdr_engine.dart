import 'dart:math';

class LocationFix {
  final double lat;
  final double lng;

  /// 'gps' or 'estimated'.
  final String source;
  final double uncertaintyM;

  /// When the position was measured. For an estimated fix this is the time of
  /// the last real GPS fix, not "now".
  final int timeMs;

  /// When this fix object was produced ("now").
  final int generatedAtMs;

  const LocationFix({
    required this.lat,
    required this.lng,
    required this.source,
    required this.uncertaintyM,
    required this.timeMs,
    int? generatedAtMs,
  }) : generatedAtMs = generatedAtMs ?? timeMs;

  /// Seconds since the position was last confirmed by GPS (0 for a live fix).
  int get ageSinceGpsS => ((generatedAtMs - timeMs) / 1000).round().clamp(0, 1 << 30);
}

/// "just now", "45 s", "3 min", "2 h" style age for SMS and screens.
String formatAge(int seconds) {
  if (seconds < 10) return 'just now';
  if (seconds < 60) return '$seconds s ago';
  if (seconds < 3600) return '${seconds ~/ 60} min ago';
  return '${seconds ~/ 3600} h ago';
}

/// Rising-edge peak detector on the linear-acceleration magnitude (m/s^2).
class StepDetector {
  final double threshold;
  final int minIntervalMs;
  double _last = 0.0;
  int _lastStepMs = -1000000;

  StepDetector({this.threshold = 2.0, this.minIntervalMs = 300});

  bool process(double magnitude, int tMs) {
    bool step = false;
    if (magnitude > threshold &&
        _last <= threshold &&
        tMs - _lastStepMs >= minIntervalMs) {
      _lastStepMs = tMs;
      step = true;
    }
    _last = magnitude;
    return step;
  }
}

/// Tilt-compensated compass heading of the device +Y axis, in degrees
/// clockwise from magnetic north (same maths as Android getRotationMatrix).
/// Returns null when accelerometer and magnetometer are (anti)parallel.
double? headingFromSensors({
  required double ax,
  required double ay,
  required double az,
  required double mx,
  required double my,
  required double mz,
}) {
  double hx = my * az - mz * ay;
  double hy = mz * ax - mx * az;
  double hz = mx * ay - my * ax;
  final normH = sqrt(hx * hx + hy * hy + hz * hz);
  if (normH < 0.1) return null;
  hx /= normH;
  hy /= normH;
  hz /= normH;
  final normA = sqrt(ax * ax + ay * ay + az * az);
  if (normA == 0) return null;
  final nax = ax / normA, naz = az / normA;
  final my2 = naz * hx - nax * hz;
  final deg = atan2(hy, my2) * 180 / pi;
  return (deg + 360) % 360;
}

/// Circular low-pass filter for headings in degrees.
double smoothHeading(double? previous, double next, {double alpha = 0.2}) {
  if (previous == null) return next;
  final diff = ((next - previous + 540) % 360) - 180;
  return (previous + alpha * diff + 360) % 360;
}

/// Pedestrian dead reckoning anchored on the latest usable GPS fix.
///
/// GPS fixes re-anchor the position. Steps keep advancing an estimate in the
/// background so that when GPS goes stale the estimate is already current.
class PdrEngine {
  final double strideM;
  final int staleAfterMs;
  final double driftFraction;
  final double maxUsableAccuracyM;

  double? _lat;
  double? _lng;
  double _gpsLat = 0, _gpsLng = 0, _gpsAccuracy = 0;
  int? _lastGpsMs;
  double? _heading;
  double _distanceSinceFix = 0;
  double _extraUncertaintyM = 0;
  int _steps = 0;

  PdrEngine({
    this.strideM = 0.75,
    this.staleAfterMs = 8000,
    this.driftFraction = 0.15,
    this.maxUsableAccuracyM = 100,
  });

  int get steps => _steps;
  double get distanceSinceFixM => _distanceSinceFix;
  bool get hasAnchor => _lat != null;

  void onGpsFix(double lat, double lng, double accuracyM, int tMs) {
    if (accuracyM > maxUsableAccuracyM || (lat == 0 && lng == 0)) return;
    _lat = lat;
    _lng = lng;
    _gpsLat = lat;
    _gpsLng = lng;
    _gpsAccuracy = accuracyM;
    _lastGpsMs = tMs;
    _distanceSinceFix = 0;
    _extraUncertaintyM = 0;
  }

  void onHeading(double degrees) => _heading = degrees;

  /// Counts one stride. Distance and steps accrue whenever there is an anchor
  /// so uncertainty keeps growing; only the position update needs a heading
  /// (we never guess a direction). A step with no heading adds 50% of its
  /// distance as extra uncertainty because the true direction is unknown.
  void onStep() {
    if (_lat == null) return;
    _distanceSinceFix += strideM;
    _steps++;
    final heading = _heading;
    if (heading == null) {
      _extraUncertaintyM += 0.5 * strideM;
      return;
    }
    final h = heading * pi / 180;
    const metersPerDegLat = 111111.0;
    _lat = _lat! + strideM * cos(h) / metersPerDegLat;
    _lng = _lng! + strideM * sin(h) / (metersPerDegLat * cos(_lat! * pi / 180));
  }

  LocationFix? currentFix(int nowMs) {
    if (_lat == null || _lastGpsMs == null) return null;
    if (nowMs - _lastGpsMs! <= staleAfterMs) {
      return LocationFix(
        lat: _gpsLat,
        lng: _gpsLng,
        source: 'gps',
        uncertaintyM: _gpsAccuracy,
        timeMs: _lastGpsMs!,
        generatedAtMs: nowMs,
      );
    }
    return LocationFix(
      lat: _lat!,
      lng: _lng!,
      source: 'estimated',
      uncertaintyM: _gpsAccuracy +
          driftFraction * _distanceSinceFix +
          _extraUncertaintyM,
      timeMs: _lastGpsMs!,
      generatedAtMs: nowMs,
    );
  }
}
