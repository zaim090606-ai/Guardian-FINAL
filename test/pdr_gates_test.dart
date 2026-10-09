import 'dart:math';

import 'package:easy_help/logic/motion_context.dart';
import 'package:easy_help/logic/pdr_config.dart';
import 'package:easy_help/logic/pdr_engine.dart';
import 'package:flutter_test/flutter_test.dart';

const mPerDegLng = 111111.0 * 0.8829; // cos(28 deg)

/// Feeds [fixes] GPS fixes [dtS] apart, moving [stepM] metres east per fix,
/// with [stepsPerFix] steps in between.
void drive(
  PdrEngine e, {
  required int fixes,
  required double stepM,
  required int stepsPerFix,
  int dtS = 2,
  double? speed,
  double? course,
  double? courseAcc,
  double? speedAcc,
  bool mocked = false,
  double heading = 90,
}) {
  var t = 1000000;
  var lng = 77.0;
  e.onGpsFix(28.0, lng, 5, t);
  for (var i = 0; i < fixes; i++) {
    for (var s = 0; s < stepsPerFix; s++) {
      e.onHeading(heading);
      e.onStep();
    }
    t += dtS * 1000;
    lng += stepM / mPerDegLng;
    e.onGpsFix(28.0, lng, 5, t,
        speedMps: speed,
        courseDeg: course,
        courseAccuracyDeg: courseAcc,
        speedAccuracyMps: speedAcc,
        mocked: mocked);
  }
}

void main() {
  test('bumpy vehicle motion without YAMNet does not calibrate', () {
    final e = PdrEngine();
    e.onGravity(0, 0, 9.8);
    // 10 m/s, 4 road bumps counted as steps per fix, GPS speed reported.
    drive(e, fixes: 20, stepM: 20, stepsPerFix: 4, speed: 10, course: 90);
    expect(e.headingOffsetCalibrated, isFalse);
    expect(e.strideCalibrated, isFalse);
    expect(e.currentStrideM, 0.75);
    expect(e.driftFraction, 0.15);
  });

  test('vehicle speed without a reported GPS speed is rejected by the walking checks',
      () {
    final e = PdrEngine();
    drive(e, fixes: 20, stepM: 20, stepsPerFix: 4); // 10 m/s derived
    expect(e.headingOffsetCalibrated, isFalse);
    expect(e.strideCalibrated, isFalse);
  });

  test('a vehicle context heard in the window blocks learning', () {
    final e = PdrEngine();
    var t = 1000000;
    var lng = 77.0;
    e.onGpsFix(28.0, lng, 5, t);
    e.onContext(MotionContext.vehicle, t);
    e.onContext(MotionContext.walking, t + 1000);
    for (var i = 0; i < 12; i++) {
      for (var s = 0; s < 4; s++) {
        e.onHeading(90);
        e.onStep();
      }
      t += 2000;
      lng += 2.8 / mPerDegLng;
      e.onGpsFix(28.0, lng, 5, t, speedMps: 1.4, courseDeg: 90);
    }
    // The first window was tainted; later ones are clean, so after enough
    // clean windows it may calibrate, but not from the tainted one.
    expect(e.rejectedWindows, greaterThan(0));
  });

  test('normal walking calibrates after 3 accepted windows each', () {
    final e = PdrEngine();
    drive(e, fixes: 5, stepM: 2.8, stepsPerFix: 4, speed: 1.4, course: 90);
    expect(e.strideCalibrated, isFalse); // fewer than 3 stride windows
    final e2 = PdrEngine();
    drive(e2, fixes: 45, stepM: 2.8, stepsPerFix: 4, speed: 1.4, course: 90);
    expect(e2.headingOffsetCalibrated, isTrue);
    expect(e2.strideCalibrated, isTrue);
    expect(e2.driftFraction, 0.10);
    expect(e2.currentStrideM, closeTo(0.7, 0.05));
  });

  test('implausible stride windows are rejected, not clamped', () {
    final e = PdrEngine();
    // 2.8 m in 8 steps = 0.35 m per step: below 0.45.
    drive(e, fixes: 40, stepM: 2.8, stepsPerFix: 8, speed: 1.4, course: 90);
    expect(e.currentStrideM, 0.75);
    expect(e.strideCalibrated, isFalse);
    expect(e.rejectedWindows, greaterThan(0));
  });

  test('too few steps in a window are not learned', () {
    final e = PdrEngine();
    drive(e, fixes: 40, stepM: 2.8, stepsPerFix: 1, speed: 1.4, course: 90);
    expect(e.strideCalibrated, isFalse);
    expect(e.headingOffsetCalibrated, isFalse);
  });

  test('cadence outside 0.8-2.5 Hz is not learned', () {
    final e = PdrEngine();
    // 4 steps in 8 s = 0.5 Hz.
    drive(e, fixes: 30, stepM: 5.6, stepsPerFix: 4, dtS: 8, speed: 0.7, course: 90);
    expect(e.strideCalibrated, isFalse);
  });

  test('GPS speed above 2.5 m/s is never learned from', () {
    final e = PdrEngine();
    drive(e, fixes: 40, stepM: 6.0, stepsPerFix: 6, speed: 3.0, course: 90);
    expect(e.headingOffsetCalibrated, isFalse);
    expect(e.strideCalibrated, isFalse);
  });

  test('poor speed accuracy is ignored', () {
    final e = PdrEngine();
    // speed 4 with accuracy 3 m/s: speed ignored, derived speed 1.4 is used.
    drive(e, fixes: 45, stepM: 2.8, stepsPerFix: 4, speed: 4.0, speedAcc: 3.0, course: 90);
    expect(e.strideCalibrated, isTrue);
  });

  test('course exactly 0.0 at low speed is ignored (bearing is used instead)',
      () {
    final e = PdrEngine();
    e.onGravity(0, 0, 9.8);
    // Walking east; the receiver reports course 0.0 and speed 0.0 (no data).
    drive(e, fixes: 45, stepM: 2.8, stepsPerFix: 4, speed: 0.0, course: 0.0);
    expect(e.headingOffsetCalibrated, isTrue);
    expect(e.headingOffsetDeg!, closeTo(0, 3)); // compass already points east
  });

  test('a GPS course that disagrees with the displacement is not trusted', () {
    final e = PdrEngine();
    drive(e, fixes: 45, stepM: 2.8, stepsPerFix: 4, speed: 1.4, course: 200);
    expect(e.headingOffsetCalibrated, isFalse);
  });

  test('poor course accuracy falls back to the displacement bearing', () {
    final e = PdrEngine();
    drive(e, fixes: 45, stepM: 2.8, stepsPerFix: 4,
        speed: 1.4, course: 200, courseAcc: 60);
    expect(e.headingOffsetCalibrated, isTrue);
    expect(e.headingOffsetDeg!, closeTo(0, 3));
  });

  test('a mocked position is never learned from', () {
    final e = PdrEngine();
    drive(e, fixes: 45, stepM: 2.8, stepsPerFix: 4,
        speed: 1.4, course: 90, mocked: true);
    expect(e.headingOffsetCalibrated, isFalse);
    expect(e.strideCalibrated, isFalse);
  });

  test('a compass that swings during the window is not learned', () {
    final e = PdrEngine();
    var t = 1000000;
    var lng = 77.0;
    e.onGpsFix(28.0, lng, 5, t);
    for (var i = 0; i < 45; i++) {
      for (var s = 0; s < 4; s++) {
        e.onHeading(s.isEven ? 0 : 180);
        e.onStep();
      }
      t += 2000;
      lng += 2.8 / mPerDegLng;
      e.onGpsFix(28.0, lng, 5, t, speedMps: 1.4, courseDeg: 90);
    }
    expect(e.headingOffsetCalibrated, isFalse);
  });

  test('banked vehicle growth is kept when the microphone flag is switched off',
      () {
    final cfg = PdrConfig();
    final e = PdrEngine(config: cfg);
    e.onGpsFix(28.0, 77.0, 5, 0);
    e.onContext(MotionContext.vehicle, 0);
    final before = e.uncertaintyAt(10000); // 10 s * 8 m/s
    expect(before, closeTo(5 + 80, 0.5));
    cfg.microphoneContext = false;
    e.onContext(MotionContext.vehicle, 10000); // service keeps feeding
    expect(e.uncertaintyAt(10000), closeTo(before, 0.5));
    expect(e.uncertaintyAt(20000), closeTo(before, 0.5)); // no live growth now
  });

  test('PdrConfig toMap / applyMap round trip', () {
    final c = PdrConfig.allOff()
      ..headingOffset = true
      ..anchors = true;
    final d = PdrConfig()..applyMap(c.toMap());
    expect(d.toMap(), c.toMap());
    expect(d.compassGating, isFalse);
    expect(d.headingOffset, isTrue);
    expect(PdrConfig().toMap().values.every((v) => v), isTrue);
    expect(pi, greaterThan(3)); // keep dart:math import used
  });
}
