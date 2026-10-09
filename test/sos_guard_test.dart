import 'package:easy_help/logic/sos_guard.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('generated ids are 20 chars and unique', () {
    final ids = {for (var i = 0; i < 200; i++) generateAlertId()};
    expect(ids.length, 200);
    expect(
        ids.every(
            (i) => i.length == 20 && RegExp(r'^[A-Za-z0-9]+$').hasMatch(i)),
        isTrue);
  });

  test('second trigger reuses the active SOS and sends nothing new', () async {
    final g = SosGuard(MemoryKeyValueStore());
    final a = await g.begin('first', 1000);
    expect(a.isNew, isTrue);
    final b = await g.begin('second', 5000);
    expect(b.isNew, isFalse);
    expect(b.id, 'first');
  });

  test('two guards on the same store (two isolates) agree', () async {
    final kv = MemoryKeyValueStore();
    final ui = SosGuard(kv), svc = SosGuard(kv);
    expect((await svc.begin('voice', 1000)).isNew, isTrue);
    expect((await ui.begin('button', 2000)).id, 'voice');
  });

  test('cleared on cancel, then a new SOS can start', () async {
    final g = SosGuard(MemoryKeyValueStore());
    final s = SosSession(g);
    await g.begin('first', 1000);
    await s.cancel();
    expect(await g.active(2000), isNull);
    expect((await g.begin('next', 3000)).isNew, isTrue);
  });

  test('a stale record (over 1 hour) does not block a new SOS', () async {
    final g = SosGuard(MemoryKeyValueStore());
    await g.begin('old', 0);
    final r = await g.begin('new', 2 * 3600 * 1000);
    expect(r.isNew, isTrue);
  });

  test('garbage record is ignored', () async {
    final kv = MemoryKeyValueStore()..data[SosGuard.key] = '{nope';
    expect((await SosGuard(kv).begin('x', 1)).isNew, isTrue);
  });

  test('cancel runs every stop once, even if one throws, and clears the guard',
      () async {
    final g = SosGuard(MemoryKeyValueStore());
    final s = SosSession(g);
    await g.begin('x', 1);
    final stopped = <String>[];
    s.onCancel(() => stopped.add('timers'));
    s.onCancel(() => throw StateError('relay'));
    s.onCancel(() => stopped.add('firestore'));
    await s.cancel();
    await s.cancel();
    expect(stopped, ['timers', 'firestore']);
    expect(await g.active(2), isNull);
  });
}
