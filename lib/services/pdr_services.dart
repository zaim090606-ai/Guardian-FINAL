import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';

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

  final PdrEngine _engine = PdrEngine();
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

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  Future<void> start() async {
    if (_running) return;
    _running = true;

    try {
      _linearSub = userAccelerometerEventStream(
        samplingPeriod: SensorInterval.gameInterval,
      ).listen((e) {
        final mag = _norm(e.x, e.y, e.z);
        if (_stepDetector.process(mag, _now())) _engine.onStep();
      }, onError: (Object e) => debugPrint('PDR linear accel error: $e'));

      _accelSub = accelerometerEventStream(
        samplingPeriod: SensorInterval.normalInterval,
      ).listen((e) => _lastAccel = e,
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
    _engine.onGpsFix(
      p.latitude,
      p.longitude,
      p.accuracy,
      p.timestamp.millisecondsSinceEpoch,
    );
  }

  /// Best current location, or null when no GPS fix has ever been seen.
  LocationFix? currentFix() => _engine.currentFix(_now());

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
