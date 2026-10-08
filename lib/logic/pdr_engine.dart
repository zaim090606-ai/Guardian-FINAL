import 'dart:math';

import 'motion_context.dart';
import 'pdr_config.dart';

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

  /// Motion context name (e.g. 'vehicle'), or '' when unknown.
  final String context;

  const LocationFix({
    required this.lat,
    required this.lng,
    required this.source,
    required this.uncertaintyM,
    required this.timeMs,
    int? generatedAtMs,
    this.context = '',
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

/// Plausible Earth-field strength in microtesla. Outside this range the
/// magnetometer is disturbed (metal, speakers, magnets) and the sample is
/// not trusted for a heading.
bool magneticFieldPlausible(double mx, double my, double mz,
    {double minUt = 25, double maxUt = 65}) {
  final m = sqrt(mx * mx + my * my + mz * mz);
  return m >= minUt && m <= maxUt;
}

/// Ground distance in metres between two nearby coordinates.
double distanceM(double lat1, double lng1, double lat2, double lng2) {
  const mPerDeg = 111111.0;
  final dy = (lat2 - lat1) * mPerDeg;
  final dx = (lng2 - lng1) * mPerDeg * cos((lat1 + lat2) / 2 * pi / 180);
  return sqrt(dx * dx + dy * dy);
}

/// Bearing in degrees clockwise from north from point 1 to point 2.
double bearingDeg(double lat1, double lng1, double lat2, double lng2) {
  const mPerDeg = 111111.0;
  final dy = (lat2 - lat1) * mPerDeg;
  final dx = (lng2 - lng1) * mPerDeg * cos((lat1 + lat2) / 2 * pi / 180);
  return (atan2(dx, dy) * 180 / pi + 360) % 360;
}

/// Signed circular difference a-b in degrees, in (-180, 180].
double angleDiff(double a, double b) => ((a - b + 540) % 360) - 180;

/// Pedestrian dead reckoning anchored on the latest usable GPS fix.
///
/// GPS fixes re-anchor the position. Steps keep advancing an estimate in the
/// background so that when GPS goes stale the estimate is already current.
///
/// While GPS is good the engine also learns, from GPS, the phone's compass
/// offset and the user's stride (see [PdrConfig]); both are applied when GPS
/// is lost.
class PdrEngine {
  /// ASSUMPTION (to be replaced by field measurements): estimated position
  /// error as a fraction of distance walked without GPS, uncalibrated.
  static const double driftUncalibrated = 0.15;

  /// ASSUMPTION (to be replaced by field measurements): same, once both the
  /// heading offset and the stride have been learned from GPS.
  static const double driftCalibrated = 0.10;

  static const double goodGpsAccuracyM = 15;
  static const double minLearnSpeedMps = 1.0;
  static const double minCourseBaselineM = 5;
  static const double strideWindowM = 20;
  static const double minStrideM = 0.45, maxStrideM = 1.0;
  static const double gravityChangeLimitDeg = 40;
  static const int minOffsetSamples = 3;
  static const int minStrideSamples = 2;

  /// ASSUMPTION: fastest plausible ground speed while in a vehicle whose
  /// direction we cannot know, and the cap on the radius that implies.
  static const double vehicleMaxSpeedMps = 8;
  static const double vehicleMaxGrowthM = 2000;

  final PdrConfig config;
  final double strideM;
  final int staleAfterMs;

  /// Fixed drift fraction override; null = 0.15 / 0.10 by calibration state.
  final double? driftFractionOverride;
  final double maxUsableAccuracyM;

  double? _lat;
  double? _lng;
  double _gpsLat = 0, _gpsLng = 0, _baseUncertaintyM = 0;
  int? _lastGpsMs;
  double? _heading;
  double _distanceSinceFix = 0;
  double _driftM = 0;
  double _extraUncertaintyM = 0;
  int _steps = 0;

  // Motion context (microphone).
  MotionContext _context = MotionContext.unknown;
  double _vehicleBankedM = 0;
  int _vehicleSinceMs = 0;

  // Learned from GPS.
  double _stride;
  int _strideSamples = 0;
  double _offSin = 0, _offCos = 0;
  int _offsetSamples = 0;
  bool _offsetValid = true;
  List<double>? _gravity;
  List<double>? _calGravity;

  // Learning windows (only valid across consecutive good GPS fixes).
  double? _courseRefLat, _courseRefLng;
  int _courseRefMs = 0;
  int _stepsSinceCourseRef = 0;
  double? _strideRefLat, _strideRefLng;
  int _stepsSinceStrideRef = 0;

  PdrEngine({
    PdrConfig? config,
    this.strideM = 0.75,
    this.staleAfterMs = 8000,
    double? driftFraction,
    this.maxUsableAccuracyM = 100,
  })  : config = config ?? PdrConfig(),
        driftFractionOverride = driftFraction,
        _stride = strideM;

  int get steps => _steps;
  double get distanceSinceFixM => _distanceSinceFix;
  bool get hasAnchor => _lat != null;
  double? get compassHeading => _heading;

  /// Context in effect (unknown when the microphone flag is off).
  MotionContext get context =>
      config.microphoneContext ? _context : MotionContext.unknown;
  bool get inVehicle => context == MotionContext.vehicle;

  /// Feeds the microphone-derived context. While vehicle, steps are ignored
  /// and the uncertainty grows with time (we do not guess a direction).
  void onContext(MotionContext c, int nowMs) {
    if (c == _context) return;
    final wasVehicle = _context == MotionContext.vehicle;
    if (wasVehicle) _vehicleBankedM = _vehicleGrowthM(nowMs);
    if (c == MotionContext.vehicle) _vehicleSinceMs = nowMs;
    _context = c;
  }

  double _vehicleGrowthM(int nowMs) {
    final live = inVehicle
        ? vehicleMaxSpeedMps * max(0, nowMs - _vehicleSinceMs) / 1000.0
        : 0.0;
    return min(vehicleMaxGrowthM, _vehicleBankedM + live);
  }

  /// Stride in use (learned when enabled and calibrated).
  double get currentStrideM => _stride;
  bool get strideCalibrated =>
      config.strideLearning && _strideSamples >= minStrideSamples;

  /// Learned "GPS course minus compass" in degrees, or null.
  double? get headingOffsetDeg =>
      !config.headingOffset || _offsetSamples < minOffsetSamples || !_offsetValid
          ? null
          : (atan2(_offSin, _offCos) * 180 / pi + 360) % 360;
  bool get headingOffsetCalibrated => headingOffsetDeg != null;
  bool get headingOffsetInvalidated =>
      config.headingOffset && _offsetSamples >= minOffsetSamples && !_offsetValid;

  double get driftFraction =>
      driftFractionOverride ??
      (headingOffsetCalibrated && strideCalibrated
          ? driftCalibrated
          : driftUncalibrated);

  void onGpsFix(double lat, double lng, double accuracyM, int tMs,
      {double? speedMps, double? courseDeg}) {
    if (accuracyM > maxUsableAccuracyM || (lat == 0 && lng == 0)) return;
    if (!_offsetValid) {
      // GPS is back: the old offset belonged to another phone orientation.
      _offSin = _offCos = 0;
      _offsetSamples = 0;
      _offsetValid = true;
      _calGravity = _gravity;
    }
    _learn(lat, lng, accuracyM, tMs, speedMps, courseDeg);
    _lat = lat;
    _lng = lng;
    _gpsLat = lat;
    _gpsLng = lng;
    _baseUncertaintyM = accuracyM;
    _lastGpsMs = tMs;
    _distanceSinceFix = 0;
    _driftM = 0;
    _extraUncertaintyM = 0;
    _vehicleBankedM = 0;
    _vehicleSinceMs = tMs;
  }

  void _learn(double lat, double lng, double acc, int tMs, double? speed,
      double? course) {
    if (acc > goodGpsAccuracyM) {
      _courseRefLat = _strideRefLat = null;
      return;
    }
    // Windows must not span a GPS gap.
    if (_courseRefLat != null && tMs - _courseRefMs > 30000) {
      _courseRefLat = _strideRefLat = null;
    }
    if (_courseRefLat == null) {
      _courseRefLat = lat;
      _courseRefLng = lng;
      _courseRefMs = tMs;
      _stepsSinceCourseRef = 0;
      _strideRefLat = lat;
      _strideRefLng = lng;
      _stepsSinceStrideRef = 0;
      return;
    }

    // Heading offset: GPS course vs compass, while walking.
    final disp = distanceM(_courseRefLat!, _courseRefLng!, lat, lng);
    if (config.headingOffset && _heading != null && _stepsSinceCourseRef > 0) {
      final dt = (tMs - _courseRefMs) / 1000.0;
      final v = speed ?? (dt > 0 ? disp / dt : 0);
      if (v >= minLearnSpeedMps) {
        double? c;
        if (course != null && course >= 0 && course < 360) {
          c = course;
        } else if (disp >= minCourseBaselineM) {
          c = bearingDeg(_courseRefLat!, _courseRefLng!, lat, lng);
        }
        if (c != null) {
          final d = angleDiff(c, _heading!) * pi / 180;
          const a = 0.25;
          if (_offsetSamples == 0) {
            _offSin = sin(d);
            _offCos = cos(d);
          } else {
            _offSin = (1 - a) * _offSin + a * sin(d);
            _offCos = (1 - a) * _offCos + a * cos(d);
          }
          _offsetSamples++;
          _calGravity = _gravity;
        }
      }
    }
    if (disp >= minCourseBaselineM) {
      _courseRefLat = lat;
      _courseRefLng = lng;
      _courseRefMs = tMs;
      _stepsSinceCourseRef = 0;
    }

    // Stride: GPS distance / steps over windows of at least 20 m.
    final sd = distanceM(_strideRefLat!, _strideRefLng!, lat, lng);
    if (sd >= strideWindowM) {
      if (config.strideLearning && _stepsSinceStrideRef > 0) {
        final sample = sd / _stepsSinceStrideRef;
        _stride = (_stride * 0.6 + sample * 0.4).clamp(minStrideM, maxStrideM);
        _strideSamples++;
      }
      _strideRefLat = lat;
      _strideRefLng = lng;
      _stepsSinceStrideRef = 0;
    }
  }

  void onHeading(double degrees) => _heading = degrees;

  /// Feed the accelerometer (gravity) vector in the device frame. A large
  /// turn of it since the heading offset was calibrated means the phone moved
  /// (e.g. hand to pocket) and the offset no longer applies.
  void onGravity(double ax, double ay, double az) {
    final n = sqrt(ax * ax + ay * ay + az * az);
    if (n < 1) return;
    final u = [ax / n, ay / n, az / n];
    final g = _gravity;
    if (g == null) {
      _gravity = u;
      _calGravity ??= u;
    } else {
      const a = 0.2;
      final m = [for (int i = 0; i < 3; i++) (1 - a) * g[i] + a * u[i]];
      final mn = sqrt(m[0] * m[0] + m[1] * m[1] + m[2] * m[2]);
      if (mn > 0) _gravity = [for (final v in m) v / mn];
    }
    final cal = _calGravity;
    if (cal != null &&
        config.headingOffset &&
        _offsetSamples >= minOffsetSamples &&
        _offsetValid) {
      final gg = _gravity!;
      final dot =
          (gg[0] * cal[0] + gg[1] * cal[1] + gg[2] * cal[2]).clamp(-1.0, 1.0);
      if (acos(dot) * 180 / pi > gravityChangeLimitDeg) _offsetValid = false;
    }
  }

  /// Counts one stride. Distance and steps accrue whenever there is an anchor
  /// so uncertainty keeps growing; only the position update needs a heading
  /// (we never guess a direction). A step with no heading adds 50% of its
  /// distance as extra uncertainty because the true direction is unknown.
  void onStep() {
    if (_lat == null || inVehicle) return;
    final stride = _stride;
    _distanceSinceFix += stride;
    _driftM += driftFraction * stride;
    _steps++;
    _stepsSinceCourseRef++;
    _stepsSinceStrideRef++;
    final raw = _heading;
    if (raw == null) {
      _extraUncertaintyM += 0.5 * stride;
      return;
    }
    if (headingOffsetInvalidated) _extraUncertaintyM += 0.5 * stride;
    final heading = raw + (headingOffsetDeg ?? 0);
    final h = heading * pi / 180;
    const metersPerDegLat = 111111.0;
    _lat = _lat! + stride * cos(h) / metersPerDegLat;
    _lng = _lng! + stride * sin(h) / (metersPerDegLat * cos(_lat! * pi / 180));
  }

  String get _contextName => context == MotionContext.unknown ? '' : context.name;

  LocationFix? currentFix(int nowMs) {
    if (_lat == null || _lastGpsMs == null) return null;
    if (nowMs - _lastGpsMs! <= staleAfterMs) {
      return LocationFix(
        lat: _gpsLat,
        lng: _gpsLng,
        source: 'gps',
        uncertaintyM: _baseUncertaintyM,
        timeMs: _lastGpsMs!,
        generatedAtMs: nowMs,
        context: _contextName,
      );
    }
    return LocationFix(
      lat: _lat!,
      lng: _lng!,
      source: 'estimated',
      uncertaintyM: _baseUncertaintyM +
          _driftM +
          _extraUncertaintyM +
          _vehicleGrowthM(nowMs),
      timeMs: _lastGpsMs!,
      generatedAtMs: nowMs,
      context: _contextName,
    );
  }
}
