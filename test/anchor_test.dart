import 'dart:convert';

import 'package:easy_help/logic/anchor_beacon.dart';
import 'package:easy_help/logic/anchor_fusion.dart';
import 'package:easy_help/logic/pdr_config.dart';
import 'package:easy_help/logic/pdr_engine.dart';
import 'package:flutter_test/flutter_test.dart';

const now = 1700000000000;

AnchorBeacon beacon({
  double lat = 28.0,
  double lng = 77.0,
  double acc = 10,
  int ts = now - 2000,
  String source = 'gps',
}) =>
    AnchorBeacon(
        lat: lat, lng: lng, accuracyM: acc, timestampMs: ts, source: source);

/// Engine with a stale estimate at (28, 77) after [steps] northward steps.
PdrEngine staleEngine({int steps = 0, PdrConfig? config}) {
  final e = PdrEngine(config: config);
  e.onGpsFix(28.0, 77.0, 5, now - 120000);
  e.onHeading(0);
  for (int i = 0; i < steps; i++) {
    e.onStep();
  }
  return e;
}

double northM(double m) => m / 111111.0;

void main() {
  group('AnchorBeacon', () {
    test('json round trip without identity fields', () {
      final b = beacon();
      final j = b.toJson();
      expect(j.keys.toSet(),
          {'type', 'lat', 'lng', 'accuracyM', 'timestamp', 'source'});
      final r = AnchorBeacon.fromJson(
          jsonDecode(jsonEncode(j)) as Map<String, dynamic>);
      expect(r.lat, 28.0);
      expect(r.accuracyM, 10);
      expect(r.validate(nowMs: now), isNull);
    });

    test('validation rejects bad beacons', () {
      expect(beacon(lat: 91).validate(nowMs: now), 'bad latitude');
      expect(beacon(lng: 181).validate(nowMs: now), 'bad longitude');
      expect(beacon(lat: 0, lng: 0).validate(nowMs: now), 'null island');
      expect(beacon(source: 'estimated').validate(nowMs: now), 'bad source');
      expect(beacon(acc: -1).validate(nowMs: now), 'bad accuracy');
      expect(beacon(acc: double.nan).validate(nowMs: now), 'bad accuracy');
      expect(beacon(ts: now + 60000).validate(nowMs: now),
          'timestamp in future');
      expect(beacon(ts: now - 120000).validate(nowMs: now), 'beacon too old');
    });

    test('fromJson rejects mistyped or untagged payloads', () {
      expect(() => AnchorBeacon.fromJson({'lat': 1, 'lng': 2}),
          throwsFormatException);
      expect(
          () => AnchorBeacon.fromJson({
                'type': 'anchor_beacon',
                'lat': '1',
                'lng': 2,
                'accuracyM': 3,
                'timestamp': 4
              }),
          throwsFormatException);
    });

    test('parseBeacon ignores SOS packets, junk and invalid beacons', () {
      expect(parseBeacon('not json', now), isNull);
      expect(parseBeacon(jsonEncode({'id': 'abc', 'lat': 1, 'lng': 2}), now),
          isNull);
      expect(parseBeacon(jsonEncode(beacon(lat: 99).toJson()), now), isNull);
      expect(parseBeacon(jsonEncode(beacon().toJson()), now), isNotNull);
    });

    test('helper offers a beacon only with a good, fresh, real fix', () {
      bool offer(
              {bool real = true,
              double acc = 10,
              bool sim = false,
              int age = 5000}) =>
          canOfferBeacon(
              hasRealFix: real,
              accuracyM: acc,
              simulatingGpsLoss: sim,
              fixAgeMs: age);
      expect(offer(), isTrue);
      expect(offer(real: false), isFalse);
      expect(offer(acc: 31), isFalse);
      expect(offer(acc: 30), isTrue);
      expect(offer(sim: true), isFalse);
      expect(offer(age: 20000), isFalse);
      expect(offer(age: 19999), isTrue);
    });
  });

  group('fuseAnchor', () {
    test('snaps when the estimate is further from the anchor than its radius',
        () {
      final r = fuseAnchor(
          estLat: 28.0,
          estLng: 77.0,
          estSigmaM: 30,
          anchorLat: 28.0 + northM(100),
          anchorLng: 77.0,
          anchorAccuracyM: 8);
      expect(r.snapped, isTrue);
      expect(r.lat, 28.0 + northM(100));
      expect(r.sigmaM, 20); // max(8, 20)
    });

    test('inverse-variance weighting when the anchor is inside the radius',
        () {
      // equal sigmas (20 and 20): midpoint, sigma 20/sqrt(2)
      final r = fuseAnchor(
          estLat: 28.0,
          estLng: 77.0,
          estSigmaM: 20,
          anchorLat: 28.0 + northM(10),
          anchorLng: 77.0,
          anchorAccuracyM: 5);
      expect(r.snapped, isFalse);
      expect(distanceM(28.0, 77.0, r.lat, r.lng), closeTo(5, 0.01));
      expect(r.sigmaM, closeTo(20 / 1.41421356, 0.01));
    });

    test('a much more certain estimate barely moves', () {
      final r = fuseAnchor(
          estLat: 28.0,
          estLng: 77.0,
          estSigmaM: 40,
          anchorLat: 28.0 + northM(30),
          anchorLng: 77.0,
          anchorAccuracyM: 5);
      // sigma_a = 20, sigma_e = 40: weight on the anchor = 0.8
      expect(distanceM(28.0, 77.0, r.lat, r.lng), closeTo(24, 0.05));
      expect(r.sigmaM, lessThan(20));
    });
  });

  group('PdrEngine.onAnchor', () {
    test('ignored while our own GPS is fresh', () {
      final e = PdrEngine();
      e.onGpsFix(28.0, 77.0, 5, now - 1000);
      expect(e.onAnchor(beacon(), now), isNull);
      expect(e.currentFix(now)!.anchorUsed, isFalse);
    });

    test('ignored when the flag is off or there is no estimate', () {
      expect(
          staleEngine(config: PdrConfig()..anchors = false)
              .onAnchor(beacon(), now),
          isNull);
      expect(PdrEngine().onAnchor(beacon(), now), isNull);
    });

    test('expired or invalid beacons are ignored', () {
      final e = staleEngine();
      expect(e.onAnchor(beacon(ts: now - 31000), now), isNull);
      expect(e.onAnchor(beacon(lat: 99), now), isNull);
      expect(e.onAnchor(beacon(ts: now - 29000), now), isNotNull);
    });

    test('snap resets distance and reports anchor age and radius', () {
      final e = staleEngine(steps: 100);
      final before = e.currentFix(now)!;
      expect(e.distanceSinceFixM, greaterThan(0));
      final far = beacon(lat: 28.0 + northM(400), acc: 10, ts: now - 3000);
      final ev = e.onAnchor(far, now)!;
      expect(ev.snapped, isTrue);
      expect(ev.radiusBeforeM, closeTo(before.uncertaintyM, 1e-6));
      expect(ev.radiusAfterM, 20);
      expect(ev.anchorAgeS, 3);
      expect(e.distanceSinceFixM, 0);
      final f = e.currentFix(now)!;
      expect(f.source, 'estimated');
      expect(f.anchorUsed, isTrue);
      expect(f.anchorAgeS, 3);
      expect(f.anchorRadiusM, 20);
      expect(f.uncertaintyM, 20);
      expect(f.lat, closeTo(far.lat, 1e-9));
      expect(f.timeMs, now - 120000); // still the last GPS fix
    });

    test('weighting when the anchor is within the radius shrinks it', () {
      final e = staleEngine(steps: 400);
      final before = e.uncertaintyAt(now);
      expect(before, greaterThan(40));
      // estimate is ~300 m north of the start; anchor 10 m from it
      final ev =
          e.onAnchor(beacon(lat: 28.0 + northM(310), acc: 5), now)!;
      expect(ev.snapped, isFalse);
      expect(ev.radiusAfterM, lessThan(before));
      expect(ev.radiusAfterM, lessThan(20));
    });

    test('a new GPS fix clears the anchor flag', () {
      final e = staleEngine(steps: 100);
      e.onAnchor(beacon(lat: 28.0 + northM(400)), now);
      e.onGpsFix(28.1, 77.1, 5, now + 1000);
      expect(e.currentFix(now + 1000)!.anchorUsed, isFalse);
    });
  });
}
