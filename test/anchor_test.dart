import 'dart:convert';
import 'dart:math';

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
  double age = 2,
  int? received,
}) =>
    AnchorBeacon(
        lat: lat,
        lng: lng,
        accuracyM: acc,
        timestampMs: ts,
        source: source,
        ageS: age,
        receivedAtMs: received ?? now);

double sigmaFor(double acc, [double ageS = 0]) =>
    sqrt(acc * acc + 25 * 25 + (1.5 * ageS) * (1.5 * ageS));

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
          {'type', 'lat', 'lng', 'accuracyM', 'timestamp', 'ageS', 'source'});
      final r = AnchorBeacon.fromJson(
          jsonDecode(jsonEncode(j)) as Map<String, dynamic>);
      expect(r.lat, 28.0);
      expect(r.accuracyM, 10);
      expect(r.ageS, 2);
      expect(r.validate(nowMs: now), isNull);
    });

    test('validation rejects bad beacons', () {
      expect(beacon(lat: 91).validate(nowMs: now), 'bad latitude');
      expect(beacon(lng: 181).validate(nowMs: now), 'bad longitude');
      expect(beacon(lat: 0, lng: 0).validate(nowMs: now), 'null island');
      expect(beacon(source: 'estimated').validate(nowMs: now), 'bad source');
      expect(beacon(acc: -1).validate(nowMs: now), 'bad accuracy');
      expect(beacon(acc: double.nan).validate(nowMs: now), 'bad accuracy');
      // the helper's age is what counts; absolute clocks are never compared
      expect(beacon(ts: now + 6000000, age: 2).validate(nowMs: now), isNull);
      expect(beacon(ts: 5, age: 2).validate(nowMs: now), isNull);
      expect(beacon(age: 61).validate(nowMs: now), 'beacon too old');
      expect(beacon(age: 60).validate(nowMs: now), isNull);
      expect(beacon(age: -1).validate(nowMs: now), 'bad age');
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
                'timestamp': 4,
                'ageS': 0
              }),
          throwsFormatException);
      // a beacon without the helper's age is not usable
      expect(
          () => AnchorBeacon.fromJson({
                'type': 'anchor_beacon',
                'lat': 1,
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
      final ok = parseBeacon(jsonEncode(beacon().toJson()), now);
      expect(ok, isNotNull);
      expect(ok!.receivedAtMs, now);
    });

    test('age grows with the time since it was received, and can be passed on',
        () {
      final b = beacon(age: 5, received: now);
      expect(b.ageMsAt(now), 5000);
      expect(b.ageMsAt(now + 3000), 8000);
      final fwd = b.agedTo(now + 3000);
      expect(fwd.ageS, closeTo(8, 1e-9));
      expect(fwd.ageMsAt(now + 3000), 8000);
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
      expect(r.sigmaM, closeTo(sigmaFor(8), 1e-9)); // sqrt(8^2 + 25^2)
    });

    test('inverse-variance weighting when the anchor is inside the radius',
        () {
      final sa = sigmaFor(5);
      final r = fuseAnchor(
          estLat: 28.0,
          estLng: 77.0,
          estSigmaM: sa, // equal sigmas: midpoint
          anchorLat: 28.0 + northM(10),
          anchorLng: 77.0,
          anchorAccuracyM: 5);
      expect(r.snapped, isFalse);
      expect(distanceM(28.0, 77.0, r.lat, r.lng), closeTo(5, 0.01));
      expect(r.sigmaM, closeTo(sa / sqrt(2), 0.01));
    });

    test('a much more certain estimate barely moves', () {
      final r = fuseAnchor(
          estLat: 28.0,
          estLng: 77.0,
          estSigmaM: 40,
          anchorLat: 28.0 + northM(30),
          anchorLng: 77.0,
          anchorAccuracyM: 5);
      final sa = sigmaFor(5);
      final w = (1 / (sa * sa)) / (1 / (40 * 40) + 1 / (sa * sa));
      expect(distanceM(28.0, 77.0, r.lat, r.lng), closeTo(30 * w, 0.05));
      expect(r.sigmaM, lessThan(sa));
    });

    test('an older peer fix gets a wider sigma', () {
      expect(anchorSigmaM(5, ageS: 40), greaterThan(anchorSigmaM(5, ageS: 0)));
      expect(anchorSigmaM(5), closeTo(sigmaFor(5), 1e-9));
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
      expect(e.onAnchor(beacon(age: 61), now), isNull);
      expect(e.onAnchor(beacon(lat: 99), now), isNull);
      expect(e.onAnchor(beacon(age: 59, ts: 1), now), isNotNull);
    });

    test('age = helper age + time since received (no clock comparison)', () {
      final e = staleEngine();
      // absolute timestamp is nonsense (helper clock is hours off) but the
      // helper said "2 s old" and it arrived just now
      expect(e.onAnchor(beacon(ts: now + 99999999, age: 2), now), isNotNull);
      final e2 = staleEngine();
      // 30 s old when sent, received 40 s ago: 70 s old now
      expect(e2.onAnchor(beacon(age: 30, received: now - 40000), now), isNull);
    });

    test('the same measurement is applied once; the radius cannot shrink twice',
        () {
      final e = staleEngine(steps: 400);
      final b = beacon(lat: 28.0 + northM(310), acc: 5, ts: now - 3000);
      final first = e.onAnchor(b, now);
      expect(first, isNotNull);
      final r1 = e.currentFix(now)!.uncertaintyM;
      expect(e.onAnchor(b, now + 1), isNull);
      expect(e.onAnchor(b, now + 2), isNull);
      expect(e.currentFix(now)!.uncertaintyM, closeTo(r1, 1e-9));
      // a new measurement (new timestamp) is accepted
      expect(
          e.onAnchor(
              beacon(lat: 28.0 + northM(310), acc: 5, ts: now - 1000), now + 3),
          isNotNull);
    });

    test('an anchor 150 m+ from a confident estimate is rejected', () {
      final e = staleEngine(steps: 20); // radius about 5 + 2 m
      expect(e.uncertaintyAt(now), lessThan(30));
      final far = beacon(lat: 28.0 + northM(300), acc: 5);
      expect(e.onAnchor(far, now), isNull);
      expect(e.rejectedAnchors, 1);
      expect(e.currentFix(now)!.anchorUsed, isFalse);
      // inside 150 m it is accepted
      expect(e.onAnchor(beacon(lat: 28.0 + northM(120), ts: now - 500), now),
          isNotNull);
    });

    test('a large jump is allowed when the estimate is not confident', () {
      final e = staleEngine(steps: 600); // radius over 30 m
      expect(e.uncertaintyAt(now), greaterThan(30));
      expect(
          e.onAnchor(beacon(lat: 28.0 + northM(700), acc: 5), now), isNotNull);
    });

    test('snap resets distance and reports anchor age and radius', () {
      final e = staleEngine(steps: 400);
      final before = e.currentFix(now)!;
      expect(before.uncertaintyM, greaterThan(30));
      expect(e.distanceSinceFixM, greaterThan(0));
      final far = beacon(lat: 28.0 + northM(450), acc: 10, age: 3);
      final ev = e.onAnchor(far, now)!;
      expect(ev.snapped, isTrue);
      expect(ev.radiusBeforeM, closeTo(before.uncertaintyM, 1e-6));
      expect(ev.radiusAfterM, closeTo(anchorSigmaM(10, ageS: 3), 1e-9));
      expect(ev.anchorAgeS, 3);
      expect(e.distanceSinceFixM, 0);
      final f = e.currentFix(now)!;
      expect(f.source, 'estimated');
      expect(f.anchorUsed, isTrue);
      expect(f.anchorAgeS, 3);
      expect(f.uncertaintyM, closeTo(ev.radiusAfterM, 1e-9));
      expect(f.lat, closeTo(far.lat, 1e-9));
      expect(f.timeMs, now - 120000); // still the last GPS fix
    });

    test('weighting when the anchor is within the radius shrinks it', () {
      final e = staleEngine(steps: 600);
      final before = e.uncertaintyAt(now);
      expect(before, greaterThan(50));
      // estimate is ~450 m north of the start; anchor 10 m from it
      final ev = e.onAnchor(beacon(lat: 28.0 + northM(460), acc: 5), now)!;
      expect(ev.snapped, isFalse);
      expect(ev.radiusAfterM, lessThan(before));
      expect(ev.radiusAfterM, lessThan(sigmaFor(5, 2)));
    });

    test('a new GPS fix clears the anchor flag', () {
      final e = staleEngine(steps: 100);
      e.onAnchor(beacon(lat: 28.0 + northM(100), age: 1), now);
      e.onGpsFix(28.1, 77.1, 5, now + 1000);
      expect(e.currentFix(now + 1000)!.anchorUsed, isFalse);
    });
  });
}
