import 'package:easy_help/logic/error_meter.dart';
import 'package:flutter_test/flutter_test.dart';

double northM(double m) => m / 111111.0;

void main() {
  test('no run yet', () {
    expect(ErrorMeter().summary(), contains('No run yet'));
  });

  test('measures error against real GPS, tracks max and percentage', () {
    final m = ErrorMeter()..start(0);
    m.onTruth(28.0, 77.0, 1000);
    m.onEstimate(28.0 + northM(20), 77.0, 100, 2000);
    expect(m.errorM, closeTo(20, 0.1));
    m.onTruth(28.0, 77.0, 3000);
    m.onEstimate(28.0 + northM(9), 77.0, 112, 4000);
    expect(m.errorM, closeTo(9, 0.1));
    expect(m.maxErrorM, closeTo(20, 0.1));
    expect(m.percent, closeTo(8.0, 0.1));
    m.stop();
    expect(m.summary(), '112 m walked, final error 9 m, 8%');
  });

  test('stale truth is not compared and nothing changes when stopped', () {
    final m = ErrorMeter()..start(0);
    m.onTruth(28.0, 77.0, 0);
    m.onEstimate(28.0 + northM(5), 77.0, 10, 60000);
    expect(m.errorM, isNull);
    expect(m.summary(), contains('no real GPS reading'));
    m.stop();
    m.onEstimate(28.0, 77.0, 999, 61000);
    expect(m.walkedM, 10);
  });
}
