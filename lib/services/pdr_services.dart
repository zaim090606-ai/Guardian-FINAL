import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sensors_plus/sensors_plus.dart';

import '../logic/anchor_beacon.dart';
import '../logic/error_meter.dart';
import '../logic/motion_context.dart';
import '../logic/pdr_config.dart';
import '../logic/pdr_engine.dart';
import '../logic/pdr_snapshot.dart';
import 'prefs_kv.dart';

/// A fix time later than [nowMs] is clamped to [nowMs].
int clampFixTime(int fixMs, int nowMs) => fixMs > nowMs ? nowMs : fixMs;

/// Sensor and GPS plumbing around [PdrEngine].
///
/// The foreground-service isolate is the single owner: only it calls [start]
/// (sensors, GPS stream, flags). The UI isolate never starts it and reads the
/// published [PdrSnapshot] instead. While GPS is fresh it reports
/// GPS; once fixes stop arriving it reports a dead-reckoned estimate flagged
/// source "estimated" with a growing uncertainty radius, and goes back to GPS
/// as soon as a usable fix returns.
class PdrService {
  static final PdrService _instance = PdrService._internal();
  factory PdrService() => _instance;
  PdrService._internal();

  final PdrConfig config = PdrConfig();
  final PdrSettings _settings = PdrSettings(PrefsKeyValueStore());

  /// Applies and persists flag changes sent by the UI isolate.
  void setConfig(Map<dynamic, dynamic> map) {
    config.applyMap(map);
    unawaited(_settings.saveConfig(config));
  }

  /// What the UI isolate shows (published by the service every 2 s).
  PdrSnapshot snapshot() {
    final now = _now();
    _engine.onContext(motionContext, now);
    _updateErrorMeter();
    final f = _engine.currentFix(now);
    final m = errorMeter;
    final a = _engine.lastAnchor;
    return PdrSnapshot(
      generatedAtMs: now,
      simulate: _simulateGpsLoss,
      config: config.toMap(),
      fix: PdrSnapshot.fixToJson(f),
      steps: _engine.steps,
      heading: _heading,
      lastGpsLat: _lastRealLat,
      lastGpsLng: _lastRealLng,
      lastGpsAccuracy: _lastGpsAccuracy,
      lastGpsMs: _lastRealGpsMs,
      rejectedMagSamples: rejectedMagSamples,
      rejectedWindows: _engine.rejectedWindows,
      offsetDeg: _engine.headingOffsetDeg,
      offsetInvalidated: _engine.headingOffsetInvalidated,
      strideM: _engine.currentStrideM,
      strideCalibrated: _engine.strideCalibrated,
      driftFraction: _engine.driftFraction,
      motionContext: motionContext.name,
      meter: {
        'active': m.active,
        'hasRun': m.hasRun,
        'walkedM': m.walkedM,
        'errorM': m.errorM,
        'maxErrorM': m.maxErrorM,
        'percent': m.percent,
        'summary': m.summary(),
        'hasTruth': m.hasTruth,
        'truthLat': m.truthLat,
        'truthLng': m.truthLng,
      },
      lastAnchor: a == null
          ? null
          : {
              'atMs': a.atMs,
              'ageS': a.anchorAgeS,
              'before': a.radiusBeforeM,
              'after': a.radiusAfterM,
              'snapped': a.snapped,
              'simulated': a.simulated,
            },
    );
  }
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
  bool _simulateGpsLoss = false;
  bool get simulateGpsLoss => _simulateGpsLoss;
  set simulateGpsLoss(bool on) {
    if (on == _simulateGpsLoss) return;
    _simulateGpsLoss = on;
    unawaited(_settings.saveSimulate(on));
    if (on) {
      _stepsAtLoss = _engine.steps;
      errorMeter.start(_now());
    } else {
      _updateErrorMeter();
      errorMeter.stop();
    }
  }

  /// Ground-truth error meter (real GPS compared with the estimate while GPS
  /// loss is simulated). The real GPS never feeds the estimate.
  final ErrorMeter errorMeter = ErrorMeter();
  int _stepsAtLoss = 0;

  void _updateErrorMeter() {
    if (!errorMeter.active) return;
    final f = _engine.currentFix(_now());
    final walked = (_engine.steps - _stepsAtLoss) * _engine.currentStrideM;
    if (f == null) return;
    errorMeter.onEstimate(f.lat, f.lng, walked, _now());
  }

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

  /// Helper side: a beacon for a nearby SOS sender, or null unless this phone
  /// has a real GPS fix (accuracy <= 30 m, under 20 s old) and is not
  /// simulating GPS loss. Carries no identity.
  AnchorBeacon? beaconForSharing() {
    final age = lastGpsAgeMs;
    final acc = _lastGpsAccuracy;
    if (age == null || acc == null || _lastRealLat == null) return null;
    if (!canOfferBeacon(
        hasRealFix: true,
        accuracyM: acc,
        simulatingGpsLoss: simulateGpsLoss,
        fixAgeMs: age)) {
      return null;
    }
    return AnchorBeacon(
      lat: _lastRealLat!,
      lng: _lastRealLng!,
      accuracyM: acc,
      timestampMs: _lastRealGpsMs!,
    );
  }

  /// Sender side: a beacon from a nearby phone. [simulated] marks test
  /// beacons created from the Diagnostics screen.
  AnchorEvent? onAnchor(AnchorBeacon b, {bool simulated = false}) =>
      _engine.onAnchor(b, _now(), simulated: simulated);

  AnchorEvent? get lastAnchor => _engine.lastAnchor;

  int get steps => _engine.steps;
  PdrEngine get engine => _engine;
  double? get heading => _heading;
  int? _lastRealGpsMs;
  double? _lastRealLat, _lastRealLng;
  double? _lastGpsAccuracy;
  int? get lastGpsAgeMs =>
      _lastRealGpsMs == null ? null : _now() - _lastRealGpsMs!;
  double? get lastGpsAccuracy => _lastGpsAccuracy;

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  Future<void> start() async {
    if (_running) return;
    _running = true;

    // A restart never keeps GPS loss simulated; the flags come back as saved.
    try {
      await _settings.loadInto(config);
      await _settings.resetSimulateOnStart();
    } catch (e) {
      debugPrint('PDR settings unreadable, using defaults: $e');
    }

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
    if (!_running) return;
    await _gpsSub?.cancel();
    _gpsSub = null;
    try {
      final perm = await Geolocator.checkPermission();
      if (!_running) return; // stop() ran while we were waiting
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
        onDone: () {
          // The stream ended without an error: resubscribe.
          debugPrint('PDR GPS stream ended, will retry');
          _scheduleGpsRetry();
        },
        cancelOnError: true,
      );
      if (!_running) {
        await _gpsSub?.cancel();
        _gpsSub = null;
      }
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
    // A timestamp in the future (clock skew) would keep the fix "fresh"
    // forever, so it is clamped to now.
    final tMs = clampFixTime(p.timestamp.millisecondsSinceEpoch, _now());
    if (simulateGpsLoss) {
      // Silent ground truth: used only to measure the error.
      errorMeter.onTruth(p.latitude, p.longitude, tMs);
      return;
    }
    _rememberLastKnown(p);
    _lastRealGpsMs = tMs;
    _lastGpsAccuracy = p.accuracy;
    _lastRealLat = p.latitude;
    _lastRealLng = p.longitude;
    _engine.onGpsFix(
      p.latitude,
      p.longitude,
      p.accuracy,
      tMs,
      speedMps: p.speed > 0 ? p.speed : null,
      courseDeg: p.heading >= 0 ? p.heading : null,
      speedAccuracyMps: p.speedAccuracy > 0 ? p.speedAccuracy : null,
      courseAccuracyDeg: p.headingAccuracy > 0 ? p.headingAccuracy : null,
      mocked: p.isMocked,
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
          '${p.latitude},${p.longitude},${p.accuracy},${clampFixTime(p.timestamp.millisecondsSinceEpoch, now)}',
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
    _updateErrorMeter();
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
