import 'dart:convert';

import 'package:easy_help/logic/pdr_config.dart';
import 'package:easy_help/logic/pdr_engine.dart';
import 'package:easy_help/logic/pdr_snapshot.dart';
import 'package:easy_help/logic/sos_guard.dart';
import 'package:flutter_test/flutter_test.dart';

PdrSnapshot snap({
  int at = 100000,
  bool sim = false,
  LocationFix? fix,
  double? acc = 8,
  int? gpsMs = 98000,
}) =>
    PdrSnapshot(
      generatedAtMs: at,
      simulate: sim,
      config: PdrConfig().toMap(),
      fix: PdrSnapshot.fixToJson(fix),
      steps: 3,
      heading: 90,
      lastGpsLat: 28.0,
      lastGpsLng: 77.0,
      lastGpsAccuracy: acc,
      lastGpsMs: gpsMs,
      rejectedMagSamples: 1,
      rejectedWindows: 2,
      offsetDeg: 12.5,
      offsetInvalidated: false,
      strideM: 0.7,
      strideCalibrated: true,
      driftFraction: 0.10,
      motionContext: 'walking',
      meter: const {'active': false},
      lastAnchor: null,
    );

void main() {
  test('snapshot survives JSON (the service-to-UI event)', () {
    final f = LocationFix(
        lat: 28.1, lng: 77.2, source: 'estimated', uncertaintyM: 22,
        timeMs: 90000, context: 'vehicle');
    final s = snap(fix: f, sim: true);
    final r = PdrSnapshot.fromJson(jsonDecode(jsonEncode(s.toJson())))!;
    expect(r.simulate, isTrue);
    expect(r.steps, 3);
    expect(r.offsetDeg, 12.5);
    final back = r.locationFix(101000)!;
    expect(back.source, 'estimated');
    expect(back.context, 'vehicle');
    expect(back.ageSinceGpsS, 11); // ages with the UI clock, not the snapshot
  });

  test('a stale snapshot means PDR is not running', () {
    final s = snap(fix: LocationFix(
        lat: 1, lng: 1, source: 'gps', uncertaintyM: 5, timeMs: 99000));
    expect(s.isFresh(105000), isTrue);
    expect(s.isFresh(120000), isFalse);
    expect(s.locationFix(120000), isNull);
    expect(s.beaconForSharing(120000), isNull);
  });

  test('garbage is not a snapshot', () {
    expect(PdrSnapshot.fromJson(null), isNull);
    expect(PdrSnapshot.fromJson('x'), isNull);
    expect(PdrSnapshot.fromJson({'at': 'no'}), isNull);
  });

  test('UI-side beacon rules: fresh, accurate, never while simulating', () {
    expect(snap().beaconForSharing(100000), isNotNull);
    expect(snap(sim: true).beaconForSharing(100000), isNull);
    expect(snap(acc: 80).beaconForSharing(100000), isNull);
    expect(snap(gpsMs: 70000).beaconForSharing(100000), isNull);
    expect(snap(gpsMs: null).beaconForSharing(100000), isNull);
  });

  test('PdrConfig is persisted and reloaded', () async {
    final kv = MemoryKeyValueStore();
    final saved = PdrConfig.allOff()..headingOffset = true;
    await PdrSettings(kv).saveConfig(saved);
    final loaded = PdrConfig();
    await PdrSettings(kv).loadInto(loaded);
    expect(loaded.toMap(), saved.toMap());
  });

  test('missing or broken saved config leaves the defaults', () async {
    final kv = MemoryKeyValueStore();
    final c = PdrConfig();
    await PdrSettings(kv).loadInto(c);
    expect(c.toMap().values.every((v) => v), isTrue);
    kv.data[PdrSettings.configKey] = '%%garbage';
    await PdrSettings(kv).loadInto(c);
    expect(c.toMap().values.every((v) => v), isTrue);
  });

  test('simulate GPS loss is OFF again after the service restarts', () async {
    final kv = MemoryKeyValueStore();
    final s = PdrSettings(kv);
    await s.saveSimulate(true);
    expect(await s.readSimulate(), isTrue);
    await s.resetSimulateOnStart();
    expect(await s.readSimulate(), isFalse);
  });
}
