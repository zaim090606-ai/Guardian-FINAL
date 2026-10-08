import 'dart:async';

import 'package:easy_help/logic/sos_dispatcher.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<SosAttempt> logged;
  late List<String> calls;

  SosDispatcher make({
    Duration cloud = const Duration(milliseconds: 200),
    Duration sms = const Duration(milliseconds: 200),
    Duration mesh = const Duration(milliseconds: 200),
  }) =>
      SosDispatcher(
        onAttempt: logged.add,
        cloudTimeout: cloud,
        smsTimeout: sms,
        meshTimeout: mesh,
      );

  setUp(() {
    logged = [];
    calls = [];
  });

  Future<bool> ok(String n) async {
    calls.add(n);
    return true;
  }

  Future<bool> fail(String n) async {
    calls.add(n);
    return false;
  }

  test('cloud ok: sms sent, mesh not used', () async {
    final r = await make().dispatch(
        sosId: 'x',
        cloud: () => ok('cloud'),
        sms: () => ok('sms'),
        mesh: () => ok('mesh'));
    expect(r.map((e) => e.channel), ['cloud', 'sms']);
    expect(calls, isNot(contains('mesh')));
    expect(r.every((e) => e.ok), isTrue);
  });

  test('cloud offline: sms still sent and mesh fallback tried', () async {
    final r = await make().dispatch(
        sosId: 'x',
        cloud: () => fail('cloud'),
        sms: () => ok('sms'),
        mesh: () => ok('mesh'));
    expect(r.map((e) => e.channel), ['cloud', 'sms', 'mesh']);
    expect(r.map((e) => e.ok), [false, true, true]);
  });

  test('exception in cloud does not stop sms or mesh', () async {
    final r = await make().dispatch(
        sosId: 'x',
        cloud: () async => throw StateError('no network'),
        sms: () => ok('sms'),
        mesh: () => ok('mesh'));
    expect(r[0].ok, isFalse);
    expect(r[0].detail, contains('no network'));
    expect(r[1].ok, isTrue);
    expect(r[2].ok, isTrue);
  });

  test('exception in sms does not stop cloud', () async {
    final r = await make().dispatch(
        sosId: 'x',
        cloud: () => ok('cloud'),
        sms: () async => throw Exception('no permission'),
        mesh: () => ok('mesh'));
    expect(r[0].ok, isTrue);
    expect(r[1].ok, isFalse);
    expect(r.length, 2);
  });

  test('everything failing never throws', () async {
    final r = await make().dispatch(
        sosId: 'x',
        cloud: () async => throw 'a',
        sms: () async => throw 'b',
        mesh: () async => throw 'c');
    expect(r.map((e) => e.ok), [false, false, false]);
  });

  test('hanging cloud times out and mesh starts without waiting for sms',
      () async {
    final never = Completer<bool>();
    final r = await make(cloud: const Duration(milliseconds: 50)).dispatch(
        sosId: 'x',
        cloud: () => never.future,
        sms: () => ok('sms'),
        mesh: () => ok('mesh'));
    expect(r[0].ok, isFalse);
    expect(r[0].detail, contains('timeout'));
    expect(r[2].ok, isTrue);
  });

  test('sms starts before the cloud attempt finishes', () async {
    final order = <String>[];
    await make().dispatch(
        sosId: 'x',
        cloud: () async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          order.add('cloud-done');
          return true;
        },
        sms: () async {
          order.add('sms-start');
          return true;
        },
        mesh: () => ok('mesh'));
    expect(order, ['sms-start', 'cloud-done']);
  });

  test('every attempt is logged with its outcome', () async {
    await make().dispatch(
        sosId: 'id1',
        cloud: () => fail('cloud'),
        sms: () => ok('sms'),
        mesh: () => ok('mesh'));
    expect(logged.length, 3);
    expect(logged.every((e) => e.sosId == 'id1'), isTrue);
    expect(logged.map((e) => e.channel).toSet(), {'cloud', 'sms', 'mesh'});
  });

  test('a throwing log callback cannot break dispatch', () async {
    final d = SosDispatcher(onAttempt: (_) => throw Exception('disk full'));
    final r = await d.dispatch(
        sosId: 'x',
        cloud: () => ok('cloud'),
        sms: () => ok('sms'),
        mesh: () => ok('mesh'));
    expect(r.length, 2);
  });

  group('AttemptLog', () {
    test('bounded and round-trips', () {
      final log = AttemptLog(capacity: 2);
      for (int i = 0; i < 3; i++) {
        log.add(SosAttempt(
            sosId: 's$i',
            channel: 'sms',
            ok: i.isEven,
            detail: 'd',
            tsMs: i,
            elapsedMs: 1));
      }
      expect(log.items.map((e) => e.sosId), ['s1', 's2']);
      final back = AttemptLog.decode(log.encode(), capacity: 2);
      expect(back.items.map((e) => e.ok), [false, true]);
    });

    test('decode ignores garbage', () {
      expect(AttemptLog.decode('???').items, isEmpty);
    });
  });

  group('normalizePhone', () {
    test('adds +91 to 10 digit numbers and strips punctuation', () {
      expect(normalizePhone('98765 43210'), '+919876543210');
      expect(normalizePhone('+1 (555) 123-4567'), '+15551234567');
      expect(normalizePhone('abc'), '');
    });
  });

  group('extractPhone', () {
    test('reads the number from the stored Name (phone) format', () {
      expect(extractPhone('Mom 2 (98765 43210)'), '+919876543210');
      expect(extractPhone('+15551234567'), '+15551234567');
    });
  });

  group('buildSosText', () {
    test('includes tracking link, coordinates and source', () {
      final t = buildSosText(
          trackingUrl: 'https://x/alert/1',
          lat: 28.5,
          lng: 77.1,
          source: 'estimated',
          uncertaintyM: 12.4,
          trigger: 'Whisper Keyword');
      expect(t, contains('https://x/alert/1'));
      expect(t, contains('28.5,77.1'));
      expect(t, contains('ESTIMATED'));
      expect(t, contains('12m'));
    });

    test('unknown location says unavailable and long summary is cut', () {
      final t = buildSosText(
          trackingUrl: 'u',
          lat: 0,
          lng: 0,
          source: 'unknown',
          uncertaintyM: 0,
          trigger: 't',
          summary: 'x' * 500);
      expect(t, contains('unavailable'));
      expect(t.length, lessThan(400));
    });
  });
}
