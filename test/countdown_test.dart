import 'package:easy_help/logic/countdown.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CancelableCountdown', () {
    test('expires with true when not cancelled', () async {
      final c = CancelableCountdown();
      expect(await c.start(const Duration(milliseconds: 30)), isTrue);
      expect(c.isRunning, isFalse);
    });

    test('cancel completes with false before the timer fires', () async {
      final c = CancelableCountdown();
      final f = c.start(const Duration(seconds: 5));
      expect(c.isRunning, isTrue);
      c.cancel();
      expect(await f, isFalse);
    });

    test('starting again cancels the previous countdown', () async {
      final c = CancelableCountdown();
      final first = c.start(const Duration(seconds: 5));
      final second = c.start(const Duration(milliseconds: 30));
      expect(await first, isFalse);
      expect(await second, isTrue);
    });

    test('cancel with nothing running is harmless', () {
      CancelableCountdown().cancel();
    });
  });

  group('EventLog', () {
    test('keeps the newest entries, newest first', () {
      final l = EventLog(capacity: 3);
      for (int i = 1; i <= 5; i++) {
        l.add('e$i', i);
      }
      expect(l.newestFirst.map((e) => e.text), ['e5', 'e4', 'e3']);
      expect(l.toJson().first['m'], 'e5');
    });
  });
}
