import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../logic/motion_context.dart';
import '../logic/pdr_config.dart';
import '../logic/pdr_engine.dart';

/// Sensor and GPS plumbing around [PdrEngine].
///
/// Runs inside the foreground-service isolate. While GPS is fresh it reports
/// GPS; once fixes stop arriving it reports a dead-reckoned estimate flagged
/// source "estimated" with a growing uncertainty radius, and goes back to GPS
/// as soon as a usable fix returns.
class PdrService {
  static final PdrService _instance = PdrService._internal();
  factory PdrService() => _instance;
  PdrService._internal();

  final PdrConfig config = PdrConfig();
  late final PdrEngine _engine = PdrEngine(config: config);
  int rejectedMagSamples = 0;

  final MotionContextClassifier _contextClassifier = MotionContextClassifier();
  int _lastLabelMs = 0;
  int _lastStepMs = 0;
  static const int _labelStaleMs = 30000;
  final StepDetector _stepDetector = StepDetector();

  StreamSubscription<UserAccelerometerEvent>? _linearSub;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  StreamSubscription<MagnetometerEvent>? _magSub;
  StreamSubscription<Position>? _gpsSub;
  Timer? _gpsRetry;

  AccelerometerEvent? _lastAccel;
  double? _heading;
  bool _running = false;

  bool get isRunning => _running;

  /// SIMULATED: when true, real GPS fixes are ignored so the dead-reckoning
  /// path can be demonstrated indoors. Anything produced while this is on is
  /// flagged as simulated by the callers.
  bool simulateGpsLoss = false;

  /// Feeds one YAMNet chunk (labels scoring >= 0.1) from the audio engine.
  /// Without a classifier nothing is fed and the context stays unknown.
  void onSoundLabels(List<LabelScore> labels) {
    _lastLabelMs = _now();
    _contextClassifier.addChunk(labels);
    _engine.onContext(motionContext, _now());
  }

  /// Current context; unknown when YAMNet gave no chunk in the last 30 s.
  MotionContext get motionContext {
    final now = _now();
    if (now - _lastLabelMs > _labelStaleMs) _contextClassifier.reset();
    return _contextClassifier.contextAt(
        now, _lastStepMs == 0 ? null : _lastStepMs);
  }

  int get steps => _engine.steps;
  PdrEngine get engine => _engine;
  double? get heading => _heading;
  int? _lastRealGpsMs;
  double? _lastGpsAccuracy;
  int? get lastGpsAgeMs =>
      _lastRealGpsMs == null ? null : _now() - _lastRealGpsMs!;
  double? get lastGpsAccuracy => _lastGpsAccuracy;

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  Future<void> start() async {
    if (_running) return;
    _running = true;

    try {
      _linearSub = userAccelerometerEventStream(
        samplingPeriod: SensorInterval.gameInterval,
      ).listen((e) {
        final mag = _norm(e.x, e.y, e.z);
        if (_stepDetector.process(mag, _now())) {
          _lastStepMs = _now();
          _engine.onStep();
        }
      }, onError: (Object e) => debugPrint('PDR linear accel error: $e'));

      _accelSub = accelerometerEventStream(
        samplingPeriod: SensorInterval.normalInterval,
      ).listen((e) {
        _lastAccel = e;
        _engine.onGravity(e.x, e.y, e.z);
      },
          onError: (Object e) => debugPrint('PDR accel error: $e'));

      _magSub = magnetometerEventStream(
        samplingPeriod: SensorInterval.normalInterval,
      ).listen(_onMagnetometer,
          onError: (Object e) => debugPrint('PDR magnetometer error: $e'));
    } catch (e) {
      debugPrint('PDR sensors unavailable, GPS only: $e');
    }

    await _subscribeGps();
    debugPrint('PDR engine started');
  }

  void _onMagnetometer(MagnetometerEvent m) {
    final a = _lastAccel;
    if (a == null) return;
    if (config.compassGating && !magneticFieldPlausible(m.x, m.y, m.z)) {
      rejectedMagSamples++;
      return;
    }
    final h = headingFromSensors(
        ax: a.x, ay: a.y, az: a.z, mx: m.x, my: m.y, mz: m.z);
    if (h == null) return;
    _heading = smoothHeading(_heading, h);
    _engine.onHeading(_heading!);
  }

  Future<void> _subscribeGps() async {
    await _gpsSub?.cancel();
    _gpsSub = null;
    try {
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        debugPrint('PDR: location permission missing, will retry');
        _scheduleGpsRetry();
        return;
      }
      _gpsSub = Geolocator.getPositionStream(
        locationSettings: AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 0,
          intervalDuration: const Duration(seconds: 2),
        ),
      ).listen(
        feedGps,
        onError: (Object e) {
          debugPrint('PDR GPS stream error: $e');
          _scheduleGpsRetry();
        },
        cancelOnError: true,
      );
    } catch (e) {
      debugPrint('PDR GPS subscribe failed: $e');
      _scheduleGpsRetry();
    }
  }

  void _scheduleGpsRetry() {
    if (!_running) return;
    _gpsRetry?.cancel();
    _gpsRetry = Timer(const Duration(seconds: 30), () {
      if (_running) _subscribeGps();
    });
  }

  /// Feeds a GPS position (from the stream or from a one-shot request).
  void feedGps(Position p) {
    if (simulateGpsLoss) return;
    _rememberLastKnown(p);
    _lastRealGpsMs = p.timestamp.millisecondsSinceEpoch;
    _lastGpsAccuracy = p.accuracy;
    _engine.onGpsFix(
      p.latitude,
      p.longitude,
      p.accuracy,
      p.timestamp.millisecondsSinceEpoch,
      speedMps: p.speed >= 0 ? p.speed : null,
      courseDeg: p.heading >= 0 ? p.heading : null,
    );
  }

  static const String _lastKnownKey = 'last_known_fix';
  int _lastSavedMs = 0;

  /// Keeps the last real fix on disk (at most every 30 s) so an SOS raised
  /// after a restart or in a dead zone can still carry coordinates.
  void _rememberLastKnown(Position p) {
    final now = _now();
    if (now - _lastSavedMs < 30000) return;
    _lastSavedMs = now;
    SharedPreferences.getInstance().then((prefs) => prefs.setString(
          _lastKnownKey,
          '${p.latitude},${p.longitude},${p.accuracy},${p.timestamp.millisecondsSinceEpoch}',
        ));
  }

  /// The stored last real fix, marked source "last_known", or null.
  static Future<LocationFix?> loadLastKnown() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final parts = (prefs.getString(_lastKnownKey) ?? '').split(',');
      if (parts.length != 4) return null;
      final lat = double.tryParse(parts[0]);
      final lng = double.tryParse(parts[1]);
      final acc = double.tryParse(parts[2]);
      final ts = int.tryParse(parts[3]);
      if (lat == null || lng == null || acc == null || ts == null) return null;
      return LocationFix(
        lat: lat,
        lng: lng,
        source: 'last_known',
        uncertaintyM: acc,
        timeMs: ts,
      );
    } catch (_) {
      return null;
    }
  }

  /// Best current location, or null when no GPS fix has ever been seen.
  LocationFix? currentFix() {
    _engine.onContext(motionContext, _now());
    return _engine.currentFix(_now());
  }

  Future<void> stop() async {
    _running = false;
    _gpsRetry?.cancel();
    await _linearSub?.cancel();
    await _accelSub?.cancel();
    await _magSub?.cancel();
    await _gpsSub?.cancel();
    _linearSub = _accelSub = _magSub = null;
    _gpsSub = null;
  }

  static double _norm(double x, double y, double z) =>
      sqrt(x * x + y * y + z * z);
}
