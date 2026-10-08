import 'dart:math';

import 'package:easy_help/logic/pdr_config.dart';
import 'package:easy_help/logic/pdr_engine.dart';
import 'package:flutter_test/flutter_test.dart';

/// Synthetic walker: true position moves at a constant speed; the engine is
/// fed steps, a (biased) compass heading and, optionally, GPS fixes.
class Walker {
  final PdrEngine engine;
  double lat = 28.0, lng = 77.0;
  int t = 0;
  final double trueStride;
  double compassBias;
  Walker(this.engine, {this.trueStride = 0.7, this.compassBias = 0});

  double walked = 0;

  /// Walks [meters] on [headingDeg]; [gps] sends a fix every 2 s.
  void walk(double meters, double headingDeg, {bool gps = true}) {
    final steps = (meters / trueStride).round();
    for (int i = 0; i < steps; i++) {
      t += 500; // 2 steps/s
      final h = headingDeg * pi / 180;
      lat += trueStride * cos(h) / 111111.0;
      lng += trueStride * sin(h) / (111111.0 * cos(lat * pi / 180));
      walked += trueStride;
      engine.onHeading((headingDeg - compassBias + 360) % 360);
      engine.onStep();
      if (gps && t % 2000 == 0) engine.onGpsFix(lat, lng, 5, t);
    }
  }

  double errorM(PdrEngine e) {
    final f = e.currentFix(t)!;
    return distanceM(f.lat, f.lng, lat, lng);
  }
}

void main() {
  group('magnetometer gating', () {
    test('accepts 25-65 uT, rejects outside', () {
      expect(magneticFieldPlausible(30, 0, 0), isTrue);
      expect(magneticFieldPlausible(0, 45, 0), isTrue);
      expect(magneticFieldPlausible(10, 10, 5), isFalse); // too weak
      expect(magneticFieldPlausible(60, 40, 20), isFalse); // ~74 uT, too strong
      expect(magneticFieldPlausible(25, 0, 0), isTrue);
      expect(magneticFieldPlausible(65, 0, 0), isTrue);
    });
  });

  group('heading offset', () {
    test('learns a synthetic 15 degree compass bias', () {
      final e = PdrEngine();
      e.onGravity(0, 0, 9.8);
      final w = Walker(e, compassBias: 15);
      w.walk(60, 40);
      expect(e.headingOffsetCalibrated, isTrue);
      expect(e.headingOffsetDeg!, closeTo(15, 1.0));
    });

    test('is not learned when the flag is off', () {
      final e = PdrEngine(config: PdrConfig()..headingOffset = false);
      Walker(e, compassBias: 15).walk(60, 40);
      expect(e.headingOffsetDeg, isNull);
    });

    test('learning works across north (circular average)', () {
      final e = PdrEngine();
      Walker(e, compassBias: 15).walk(60, 5);
      expect(e.headingOffsetDeg!, closeTo(15, 1.0));
    });

    test('offset is applied after GPS is lost', () {
      final biased = PdrEngine();
      final plain = PdrEngine(config: PdrConfig.allOff());
      final wb = Walker(biased, compassBias: 15);
      final wp = Walker(plain, compassBias: 15);
      wb.walk(60, 90);
      wp.walk(60, 90);
      wb.walk(50, 90, gps: false);
      wp.walk(50, 90, gps: false);
      expect(wb.errorM(biased), lessThan(wp.errorM(plain)));
    });

    test('gravity turning more than 40 degrees invalidates the offset', () {
      final e = PdrEngine();
      e.onGravity(0, 0, 9.8);
      final w = Walker(e, compassBias: 15);
      w.walk(60, 40);
      expect(e.headingOffsetCalibrated, isTrue);
      for (int i = 0; i < 30; i++) {
        e.onGravity(0, 9.8, 0); // phone moved from flat to upright
      }
      expect(e.headingOffsetCalibrated, isFalse);
      expect(e.headingOffsetInvalidated, isTrue);
      final before = e.currentFix(w.t + 60000)!.uncertaintyM;
      w.walk(10, 40, gps: false);
      final after = e.currentFix(w.t + 60000)!.uncertaintyM;
      // drift 0.15*10 plus 50% extra for the invalid offset
      expect(after - before, greaterThan(0.15 * 10 + 0.4 * 10));
      // GPS returns: the stale offset is dropped.
      e.onGpsFix(w.lat, w.lng, 5, w.t + 1000);
      expect(e.headingOffsetInvalidated, isFalse);
    });

    test('small gravity change keeps the offset', () {
      final e = PdrEngine();
      e.onGravity(0, 0, 9.8);
      Walker(e, compassBias: 15).walk(60, 40);
      for (int i = 0; i < 30; i++) {
        e.onGravity(0, 2.0, 9.8); // ~11 degrees
      }
      expect(e.headingOffsetCalibrated, isTrue);
    });
  });

  group('stride learning', () {
    test('converges to the true stride and is clamped', () {
      final e = PdrEngine();
      final w = Walker(e, trueStride: 0.62);
      w.walk(150, 10);
      expect(e.strideCalibrated, isTrue);
      expect(e.currentStrideM, closeTo(0.62, 0.04));
    });

    test('moving average stays within 0.45-1.0 m', () {
      final e = PdrEngine();
      Walker(e, trueStride: 0.2).walk(120, 10); // implausibly short
      expect(e.currentStrideM, greaterThanOrEqualTo(0.45));
      final e2 = PdrEngine();
      Walker(e2, trueStride: 1.6).walk(200, 10);
      expect(e2.currentStrideM, lessThanOrEqualTo(1.0));
    });

    test('flag off keeps the default stride', () {
      final e = PdrEngine(config: PdrConfig()..strideLearning = false);
      Walker(e, trueStride: 0.62).walk(150, 10);
      expect(e.currentStrideM, 0.75);
    });
  });

  group('drift fraction', () {
    test('0.15 uncalibrated, 0.10 once offset and stride are learned', () {
      final e = PdrEngine();
      expect(e.driftFraction, 0.15);
      final w = Walker(e, compassBias: 12, trueStride: 0.65);
      w.walk(150, 30);
      expect(e.headingOffsetCalibrated, isTrue);
      expect(e.strideCalibrated, isTrue);
      expect(e.driftFraction, 0.10);
      final base = e.currentFix(w.t + 60000)!.uncertaintyM;
      w.walk(20, 30, gps: false);
      final grown = e.currentFix(w.t + 60000)!.uncertaintyM - base;
      expect(grown, closeTo(0.10 * 20, 1.0));
    });

    test('all flags off behaves like the old engine (0.15)', () {
      final e = PdrEngine(config: PdrConfig.allOff());
      Walker(e).walk(150, 30);
      expect(e.driftFraction, 0.15);
    });
  });
}
