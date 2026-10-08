import 'dart:io';

import 'package:easy_help/logic/motion_context.dart';
import 'package:easy_help/logic/pdr_config.dart';
import 'package:easy_help/logic/pdr_engine.dart';
import 'package:flutter_test/flutter_test.dart';

List<LabelScore> engine(double s) => [LabelScore('Engine', s)];
List<LabelScore> speech() => [const LabelScore('Speech', 0.9)];

void main() {
  test('every vehicle label exists in the YAMNet label file', () {
    final names = File('assets/models/yamnet_labels.txt')
        .readAsLinesSync()
        .map((e) => e.trim())
        .toSet();
    for (final l in vehicleLabels) {
      expect(names.contains(l), isTrue, reason: l);
    }
  });

  group('MotionContextClassifier', () {
    test('unknown without audio labels', () {
      final c = MotionContextClassifier();
      expect(c.update(labels: null, nowMs: 0), MotionContext.unknown);
    });

    test('enters vehicle after 3 consecutive chunks >= 0.4', () {
      final c = MotionContextClassifier();
      expect(c.update(labels: engine(0.6), nowMs: 0), isNot(MotionContext.vehicle));
      expect(c.update(labels: engine(0.6), nowMs: 1000), isNot(MotionContext.vehicle));
      expect(c.update(labels: engine(0.6), nowMs: 2000), MotionContext.vehicle);
    });

    test('a weak or interrupted run does not enter vehicle', () {
      final c = MotionContextClassifier();
      c.addChunk(engine(0.6));
      c.addChunk(engine(0.39));
      c.addChunk(engine(0.6));
      c.addChunk(engine(0.6));
      expect(c.inVehicle, isFalse);
    });

    test('leaving vehicle needs 3 consecutive non-vehicle chunks', () {
      final c = MotionContextClassifier();
      for (int i = 0; i < 3; i++) {
        c.addChunk(engine(0.7));
      }
      expect(c.inVehicle, isTrue);
      c.addChunk(speech());
      c.addChunk(speech());
      expect(c.inVehicle, isTrue);
      c.addChunk(engine(0.7)); // run broken
      c.addChunk(speech());
      c.addChunk(speech());
      expect(c.inVehicle, isTrue);
      c.addChunk(speech());
      expect(c.inVehicle, isFalse);
    });

    test('walking while steps are recent, stationary after 10 s without', () {
      final c = MotionContextClassifier();
      c.addChunk(speech());
      expect(c.contextAt(5000, 1000), MotionContext.walking);
      expect(c.contextAt(11001, 1000), MotionContext.stationary);
      expect(c.contextAt(11001, null), MotionContext.stationary);
    });
  });

  group('PdrEngine with vehicle context', () {
    PdrEngine anchored() {
      final e = PdrEngine();
      e.onGpsFix(28, 77, 5, 0);
      e.onHeading(90);
      return e;
    }

    test('suppresses steps and grows uncertainty 8 m/s, capped at 2000 m', () {
      final e = anchored();
      e.onContext(MotionContext.vehicle, 10000);
      for (int i = 0; i < 50; i++) {
        e.onStep();
      }
      expect(e.steps, 0);
      var f = e.currentFix(20000)!; // 10 s in vehicle, GPS stale
      expect(f.source, 'estimated');
      expect(f.context, 'vehicle');
      expect(f.uncertaintyM, closeTo(5 + 80, 1e-6));
      f = e.currentFix(10000 + 1000000)!;
      expect(f.uncertaintyM, closeTo(5 + 2000, 1e-6));
      // position is not moved: direction is unknown
      expect(f.lat, 28);
      expect(f.lng, 77);
    });

    test('leaving vehicle keeps the grown radius and steps count again', () {
      final e = anchored();
      e.onContext(MotionContext.vehicle, 10000);
      e.onContext(MotionContext.walking, 20000);
      e.onStep();
      expect(e.steps, 1);
      final f = e.currentFix(60000)!;
      expect(f.uncertaintyM, closeTo(5 + 80 + 0.15 * 0.75, 1e-6));
    });

    test('stationary does not grow uncertainty', () {
      final e = anchored();
      e.onContext(MotionContext.stationary, 10000);
      expect(e.currentFix(20000)!.uncertaintyM, 5);
      expect(e.currentFix(500000)!.uncertaintyM, 5);
    });

    test('unknown context or flag off behaves as before', () {
      final e = PdrEngine(config: PdrConfig()..microphoneContext = false);
      e.onGpsFix(28, 77, 5, 0);
      e.onHeading(90);
      e.onContext(MotionContext.vehicle, 10000);
      e.onStep();
      expect(e.steps, 1);
      expect(e.currentFix(60000)!.uncertaintyM, closeTo(5 + 0.15 * 0.75, 1e-9));
      expect(e.currentFix(60000)!.context, '');
    });

    test('a GPS fix resets the vehicle growth', () {
      final e = anchored();
      e.onContext(MotionContext.vehicle, 10000);
      e.onGpsFix(28, 77, 6, 30000);
      expect(e.currentFix(30000 + 20000)!.uncertaintyM, closeTo(6 + 8 * 20, 1e-6));
    });
  });
}
