import 'dart:math';

import 'anchor_beacon.dart';
import 'anchor_fusion.dart';
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

  /// True when a nearby phone's position corrected this estimate.
  final bool anchorUsed;
  final int? anchorAgeS;

  /// Radius right after the anchor was applied.
  final double? anchorRadiusM;

  const LocationFix({
    required this.lat,
    required this.lng,
    required this.source,
    required this.uncertaintyM,
    required this.timeMs,
    int? generatedAtMs,
    this.context = '',
    this.anchorUsed = false,
    this.anchorAgeS,
    this.anchorRadiusM,
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

/// What the last anchor did, for diagnostics.
class AnchorEvent {
  final int atMs;
  final int anchorAgeS;
  final double radiusBeforeM;
  final double radiusAfterM;
  final bool snapped;
  final bool simulated;
  const AnchorEvent({
    required this.atMs,
    required this.anchorAgeS,
    required this.radiusBeforeM,
    required this.radiusAfterM,
    required this.snapped,
    this.simulated = false,
  });
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

  /// Walking only: faster ground speed is a vehicle (or running), never used
  /// for learning.
  static const double maxLearnSpeedMps = 2.5;
  static const double minCadenceHz = 0.8, maxCadenceHz = 2.5;
  static const int minWindowSteps = 8;
  static const double minCourseBaselineM = 5;
  static const double strideWindowM = 20;
  static const double minStrideM = 0.45, maxStrideM = 1.0;
  static const double gravityChangeLimitDeg = 40;

  /// Accepted windows needed before the offset / the stride count as learned.
  static const int minOffsetSamples = 3;
  static const int minStrideSamples = 3;

  /// Largest GPS speed / course uncertainty that is still trusted.
  static const double maxSpeedAccuracyMps = 1.0;
  static const double maxCourseAccuracyDeg = 30;

  /// A learning window older than this is dropped (it spans a GPS gap).
  static const int maxWindowMs = 60000;

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

  AnchorEvent? _lastAnchor;
  AnchorBeacon? _anchorBeacon;

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
  double _winSin = 0, _winCos = 0;
  int _winN = 0;
  bool _courseTainted = false;
  double? _strideRefLat, _strideRefLng;
  int _strideRefMs = 0;
  int _stepsSinceStrideRef = 0;
  bool _strideTainted = false;

  /// Windows rejected by the learning gates (diagnostics).
  int rejectedWindows = 0;

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
  AnchorEvent? get lastAnchor => _lastAnchor;

  /// Current radius if the estimate were reported at [nowMs].
  double uncertaintyAt(int nowMs) =>
      _baseUncertaintyM + _driftM + _extraUncertaintyM + _vehicleGrowthM(nowMs);

  /// Corrects a stale estimate with a nearby phone's GPS position. Returns the
  /// event, or null when the beacon was not used (flag off, invalid, expired,
  /// no estimate yet, or our own GPS is fresh).
  AnchorEvent? onAnchor(AnchorBeacon b, int nowMs, {bool simulated = false}) {
    if (!config.anchors || _lat == null || _lastGpsMs == null) return null;
    if (b.validate(nowMs: nowMs) != null) return null;
    final ageMs = max(0, nowMs - b.timestampMs);
    if (ageMs > anchorMaxAgeMs) return null;
    if (nowMs - _lastGpsMs! <= staleAfterMs) return null;
    final before = uncertaintyAt(nowMs);
    final r = fuseAnchor(
      estLat: _lat!,
      estLng: _lng!,
      estSigmaM: before,
      anchorLat: b.lat,
      anchorLng: b.lng,
      anchorAccuracyM: b.accuracyM,
    );
    _lat = r.lat;
    _lng = r.lng;
    _baseUncertaintyM = r.sigmaM;
    _distanceSinceFix = 0;
    _driftM = 0;
    _extraUncertaintyM = 0;
    _vehicleBankedM = 0;
    _vehicleSinceMs = nowMs;
    _anchorBeacon = b;
    return _lastAnchor = AnchorEvent(
      atMs: nowMs,
      anchorAgeS: (ageMs / 1000).round(),
      radiusBeforeM: before,
      radiusAfterM: r.sigmaM,
      snapped: r.snapped,
      simulated: simulated,
    );
  }

  bool get inVehicle => context == MotionContext.vehicle;

  /// Feeds the microphone-derived context. While vehicle, steps are ignored
  /// and the uncertainty grows with time (we do not guess a direction).
  void onContext(MotionContext requested, int nowMs) {
    // With the flag off the context is unknown; switching it off mid-vehicle
    // banks the growth so far instead of dropping it.
    final c = config.microphoneContext ? requested : MotionContext.unknown;
    if (c == _context) return;
    final wasVehicle = _context == MotionContext.vehicle;
    if (wasVehicle) _vehicleBankedM = _vehicleGrowthM(nowMs);
    if (c == MotionContext.vehicle) {
      _vehicleSinceMs = nowMs;
      _courseTainted = _strideTainted = true;
    }
    _context = c;
  }

  double _vehicleGrowthM(int nowMs) {
    final live = _context == MotionContext.vehicle
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

  /// [speedMps] / [courseDeg] are GPS ground speed and course when the
  /// receiver reported them; [speedAccuracyMps] / [courseAccuracyDeg] their
  /// uncertainty; [mocked] marks a fix from a mock-location provider (used for
  /// positioning but never for learning).
  void onGpsFix(double lat, double lng, double accuracyM, int tMs,
      {double? speedMps,
      double? courseDeg,
      double? speedAccuracyMps,
      double? courseAccuracyDeg,
      bool mocked = false}) {
    if (accuracyM > maxUsableAccuracyM || (lat == 0 && lng == 0)) return;
    if (!_offsetValid) {
      // GPS is back: the old offset belonged to another phone orientation.
      _offSin = _offCos = 0;
      _offsetSamples = 0;
      _offsetValid = true;
      _calGravity = _gravity;
    }
    _learn(lat, lng, accuracyM, tMs, speedMps, courseDeg, speedAccuracyMps,
        courseAccuracyDeg, mocked);
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
    _anchorBeacon = null;
  }

  void _resetCourseWindow(double lat, double lng, int tMs) {
    _courseRefLat = lat;
    _courseRefLng = lng;
    _courseRefMs = tMs;
    _stepsSinceCourseRef = 0;
    _winSin = _winCos = 0;
    _winN = 0;
    _courseTainted = false;
  }

  void _resetStrideWindow(double lat, double lng, int tMs) {
    _strideRefLat = lat;
    _strideRefLng = lng;
    _strideRefMs = tMs;
    _stepsSinceStrideRef = 0;
    _strideTainted = false;
  }

  void _dropWindows() {
    _courseRefLat = _strideRefLat = null;
  }

  /// A GPS course is trusted only when it is in range, accurate enough, and
  /// not Android's "no bearing" 0.0 (reported while barely moving).
  static bool courseValid(double? course, double? speed, double? courseAcc) {
    if (course == null || course < 0 || course >= 360) return false;
    if (course == 0.0 && (speed == null || speed < 0.5)) return false;
    if (courseAcc != null && courseAcc > maxCourseAccuracyDeg) return false;
    return true;
  }

  void _learn(double lat, double lng, double acc, int tMs, double? speed,
      double? course, double? speedAcc, double? courseAcc, bool mocked) {
    if (acc > goodGpsAccuracyM || mocked) {
      _dropWindows();
      return;
    }
    // Windows must not span a GPS gap.
    if (_courseRefLat != null && tMs - _courseRefMs > maxWindowMs) {
      _courseRefLat = null;
    }
    if (_strideRefLat != null && tMs - _strideRefMs > maxWindowMs) {
      _strideRefLat = null;
    }
    final spd = (speed != null &&
            speed > 0 &&
            (speedAcc == null || speedAcc <= maxSpeedAccuracyMps))
        ? speed
        : null;
    // Moving faster than a walk (or a vehicle is heard): nothing is learned
    // and the windows start over.
    if ((spd != null && spd > maxLearnSpeedMps) || inVehicle) {
      _dropWindows();
      _resetCourseWindow(lat, lng, tMs);
      _resetStrideWindow(lat, lng, tMs);
      return;
    }
    if (_courseRefLat == null) _resetCourseWindow(lat, lng, tMs);
    if (_strideRefLat == null) _resetStrideWindow(lat, lng, tMs);

    // Heading offset: GPS course vs mean compass heading over a walking window.
    final disp = distanceM(_courseRefLat!, _courseRefLng!, lat, lng);
    if (_stepsSinceCourseRef >= minWindowSteps && disp >= minCourseBaselineM) {
      final dt = (tMs - _courseRefMs) / 1000.0;
      final ok = _walkingWindowOk(disp, dt, _stepsSinceCourseRef,
              minV: minLearnSpeedMps) &&
          !_courseTainted;
      double? meanHeading;
      var spread = 0.0;
      if (_winN > 0) {
        meanHeading = atan2(_winSin, _winCos) * 180 / pi;
        spread = sqrt(_winSin * _winSin + _winCos * _winCos) / _winN;
      }
      if (ok && config.headingOffset && meanHeading != null && spread >= 0.9) {
        final bearing = bearingDeg(_courseRefLat!, _courseRefLng!, lat, lng);
        double? c = bearing;
        if (courseValid(course, spd, courseAcc)) {
          // A reported course that disagrees with the displacement is noise.
          c = angleDiff(course!, bearing).abs() <= 45 ? course : null;
        }
        if (c != null) {
          final d = angleDiff(c, meanHeading) * pi / 180;
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
        } else {
          rejectedWindows++;
        }
      } else if (config.headingOffset) {
        rejectedWindows++;
      }
      _resetCourseWindow(lat, lng, tMs);
    } else if (_stepsSinceCourseRef >= minWindowSteps && disp < minCourseBaselineM) {
      // Steps without displacement (fidgeting): start over.
      _resetCourseWindow(lat, lng, tMs);
    }

    // Stride: GPS distance / steps over windows of at least 20 m.
    final sd = distanceM(_strideRefLat!, _strideRefLng!, lat, lng);
    if (sd >= strideWindowM) {
      if (config.strideLearning) {
        final dt = (tMs - _strideRefMs) / 1000.0;
        final steps = _stepsSinceStrideRef;
        final implied = steps > 0 ? sd / steps : 0.0;
        if (!_strideTainted &&
            steps >= minWindowSteps &&
            _walkingWindowOk(sd, dt, steps, minV: 0.5) &&
            implied >= minStrideM &&
            implied <= maxStrideM) {
          _stride = (_stride * 0.6 + implied * 0.4).clamp(minStrideM, maxStrideM);
          _strideSamples++;
        } else {
          rejectedWindows++;
        }
      }
      _resetStrideWindow(lat, lng, tMs);
    }
  }

  /// Speed, cadence and stride of a window all look like a person walking.
  bool _walkingWindowOk(double distM, double dtS, int steps, {required double minV}) {
    if (dtS <= 0 || steps <= 0) return false;
    final v = distM / dtS;
    final cadence = steps / dtS;
    final stride = distM / steps;
    return v >= minV &&
        v <= maxLearnSpeedMps &&
        cadence >= minCadenceHz &&
        cadence <= maxCadenceHz &&
        stride >= minStrideM &&
        stride <= maxStrideM;
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
    _winSin += sin(raw * pi / 180);
    _winCos += cos(raw * pi / 180);
    _winN++;
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
      uncertaintyM: uncertaintyAt(nowMs),
      timeMs: _lastGpsMs!,
      generatedAtMs: nowMs,
      context: _contextName,
      anchorUsed: _anchorBeacon != null,
      anchorAgeS: _anchorBeacon == null
          ? null
          : (max(0, nowMs - _anchorBeacon!.timestampMs) / 1000).round(),
      anchorRadiusM: _anchorBeacon == null ? null : _lastAnchor?.radiusAfterM,
    );
  }
}
