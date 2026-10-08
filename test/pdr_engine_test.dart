import 'dart:math';

import 'package:easy_help/logic/pdr_engine.dart';
import 'package:flutter_test/flutter_test.dart';

double metersBetween(double lat1, double lng1, double lat2, double lng2) {
  const k = 111111.0;
  final dy = (lat2 - lat1) * k;
  final dx = (lng2 - lng1) * k * cos(lat1 * pi / 180);
  return sqrt(dx * dx + dy * dy);
}

void main() {
  group('StepDetector', () {
    test('counts one step per peak and debounces', () {
      final d = StepDetector();
      var steps = 0;
      // 10 peaks 500 ms apart
      for (int i = 0; i < 10; i++) {
        final t = i * 500;
        if (d.process(0.2, t)) steps++;
        if (d.process(3.0, t + 100)) steps++;
        if (d.process(0.2, t + 200)) steps++;
      }
      expect(steps, 10);
    });

    test('ignores peaks closer than the minimum interval', () {
      final d = StepDetector();
      expect(d.process(3.0, 1000), isTrue);
      d.process(0.1, 1050);
      expect(d.process(3.0, 1100), isFalse);
      d.process(0.1, 1200);
      expect(d.process(3.0, 1400), isTrue);
    });

    test('ignores low-level vibration', () {
      final d = StepDetector();
      for (int i = 0; i < 100; i++) {
        expect(d.process(i.isEven ? 0.3 : 1.5, i * 100), isFalse);
      }
    });
  });

  group('headingFromSensors', () {
    // Flat phone, +Y axis pointing the given way; Earth field has a downward
    // component so z is negative.
    test('north', () {
      final h = headingFromSensors(
          ax: 0, ay: 0, az: 9.8, mx: 0, my: 30, mz: -40)!;
      expect(h, closeTo(0, 0.5));
    });
    test('east', () {
      final h = headingFromSensors(
          ax: 0, ay: 0, az: 9.8, mx: -30, my: 0, mz: -40)!;
      expect(h, closeTo(90, 0.5));
    });
    test('south', () {
      final h = headingFromSensors(
          ax: 0, ay: 0, az: 9.8, mx: 0, my: -30, mz: -40)!;
      expect(h, closeTo(180, 0.5));
    });
    test('west', () {
      final h = headingFromSensors(
          ax: 0, ay: 0, az: 9.8, mx: 30, my: 0, mz: -40)!;
      expect(h, closeTo(270, 0.5));
    });
    test('degenerate input returns null', () {
      expect(
          headingFromSensors(ax: 0, ay: 0, az: 9.8, mx: 0, my: 0, mz: 40),
          isNull);
    });
  });

  group('smoothHeading', () {
    test('first sample is taken as is', () {
      expect(smoothHeading(null, 123), 123);
    });
    test('wraps across north the short way', () {
      final r = smoothHeading(350, 10, alpha: 0.5);
      expect(r, closeTo(0, 0.001));
    });
  });

  group('PdrEngine', () {
    test('no fix before any GPS anchor', () {
      expect(PdrEngine().currentFix(0), isNull);
    });

    test('fresh GPS is reported as gps', () {
      final e = PdrEngine();
      e.onGpsFix(28.0, 77.0, 6, 1000);
      final f = e.currentFix(3000)!;
      expect(f.source, 'gps');
      expect(f.lat, 28.0);
      expect(f.uncertaintyM, 6);
    });

    test('unusable GPS accuracy is ignored', () {
      final e = PdrEngine();
      e.onGpsFix(28.0, 77.0, 500, 1000);
      expect(e.currentFix(1000), isNull);
    });

    test('50 steps north move ~37.5 m and flag estimated after GPS goes stale',
        () {
      final e = PdrEngine();
      e.onGpsFix(28.0, 77.0, 5, 0);
      e.onHeading(0);
      for (int i = 0; i < 50; i++) {
        e.onStep();
      }
      final f = e.currentFix(60000)!;
      expect(f.source, 'estimated');
      expect(metersBetween(28.0, 77.0, f.lat, f.lng), closeTo(37.5, 0.5));
      expect(f.lat, greaterThan(28.0));
      expect(f.lng, closeTo(77.0, 1e-9));
    });

    test('heading east moves longitude, not latitude', () {
      final e = PdrEngine();
      e.onGpsFix(10.0, 20.0, 5, 0);
      e.onHeading(90);
      for (int i = 0; i < 40; i++) {
        e.onStep();
      }
      final f = e.currentFix(60000)!;
      expect(f.lng, greaterThan(20.0));
      expect(f.lat, closeTo(10.0, 1e-6));
    });

    test('uncertainty grows with distance walked', () {
      final e = PdrEngine();
      e.onGpsFix(28.0, 77.0, 5, 0);
      e.onHeading(0);
      for (int i = 0; i < 10; i++) {
        e.onStep();
      }
      final u1 = e.currentFix(60000)!.uncertaintyM;
      for (int i = 0; i < 40; i++) {
        e.onStep();
      }
      final u2 = e.currentFix(60000)!.uncertaintyM;
      expect(u2, greaterThan(u1));
      expect(u2, closeTo(5 + 0.15 * 37.5, 0.01));
    });

    test('switches back to GPS and resets drift when GPS returns', () {
      final e = PdrEngine();
      e.onGpsFix(28.0, 77.0, 5, 0);
      e.onHeading(0);
      for (int i = 0; i < 20; i++) {
        e.onStep();
      }
      expect(e.currentFix(60000)!.source, 'estimated');
      e.onGpsFix(28.001, 77.001, 8, 61000);
      final f = e.currentFix(62000)!;
      expect(f.source, 'gps');
      expect(f.lat, 28.001);
      expect(e.distanceSinceFixM, 0);
    });

    test('steps without a heading do not move the estimate', () {
      final e = PdrEngine();
      e.onGpsFix(28.0, 77.0, 5, 0);
      for (int i = 0; i < 20; i++) {
        e.onStep();
      }
      final f = e.currentFix(60000)!;
      expect(f.lat, 28.0);
      expect(e.steps, 0);
    });
  });
}
