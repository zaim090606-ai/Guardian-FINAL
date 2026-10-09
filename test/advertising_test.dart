import 'dart:async';

import 'package:easy_help/logic/advertising_controller.dart';
import 'package:easy_help/logic/relay_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('concurrent starts share one in-flight start', () async {
    var starts = 0;
    final gate = Completer<bool>();
    final c = AdvertisingController(
        start: () {
          starts++;
          return gate.future;
        },
        stopAll: () async {});
    final a = c.ensureStarted(), b = c.ensureStarted();
    gate.complete(true);
    expect(await a, isTrue);
    expect(await b, isTrue);
    expect(starts, 1);
    expect(c.advertising, isTrue);
  });

  test('advertising is true only when the start really succeeded', () async {
    final c = AdvertisingController(start: () async => false, stopAll: () async {});
    expect(await c.ensureStarted(), isFalse);
    expect(c.advertising, isFalse);
  });

  test('a failed start leaves the state uncertain and stop still stops', () async {
    var stops = 0;
    final c = AdvertisingController(
        start: () async => throw StateError('STATUS_ALREADY_ADVERTISING'),
        stopAll: () async => stops++);
    expect(await c.ensureStarted(), isFalse);
    expect(c.advertising, isFalse);
    await c.stop();
    expect(stops, 1);
    await c.stop();
    expect(stops, 1);
  });

  test('stop during an in-flight start waits and then stops', () async {
    final gate = Completer<bool>();
    var stops = 0;
    final c = AdvertisingController(start: () => gate.future, stopAll: () async => stops++);
    final s = c.ensureStarted();
    final st = c.stop();
    gate.complete(true);
    await s;
    await st;
    expect(stops, 1);
    expect(c.advertising, isFalse);
  });

  test('a failing stop is retried by the next stop', () async {
    var stops = 0;
    final c = AdvertisingController(
        start: () async => true,
        stopAll: () async {
          stops++;
          if (stops == 1) throw StateError('x');
        });
    await c.ensureStarted();
    await c.stop();
    await c.stop();
    expect(stops, 2);
  });

  test('idle stop does not touch the plugin', () async {
    var stops = 0;
    final c = AdvertisingController(start: () async => true, stopAll: () async => stops++);
    await c.stop();
    expect(stops, 0);
  });

  test('own packet ids survive a restart and are bounded', () {
    final ids = OwnPacketIds(capacity: 3);
    for (final i in ['a', 'b', 'c', 'd']) {
      ids.add(i);
    }
    final restored = OwnPacketIds.decode(ids.encode(), capacity: 3);
    expect(restored.ids, ['b', 'c', 'd']);
    expect(OwnPacketIds.decode('garbage').ids, isEmpty);
    expect(OwnPacketIds.decode(null).ids, isEmpty);
  });
}
