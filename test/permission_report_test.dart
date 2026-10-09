import 'package:easy_help/logic/permission_report.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('nothing granted: every feature is reported off, none claimed active', () {
    final lines = describeDenied(const {});
    expect(lines.length, permissionFeatures.length);
    expect(lines.any((l) => l.startsWith('Microphone denied')), isTrue);
    expect(lines.any((l) => l.contains('SMS') && l.contains('OFF')), isTrue);
  });

  test('only the denied permissions are listed', () {
    final all = {for (final f in permissionFeatures) f.permission: true};
    expect(describeDenied(all), isEmpty);
    all['bluetoothAdvertise'] = false;
    final lines = describeDenied(all);
    expect(lines.length, 1);
    expect(lines.single, contains('mesh relay'));
  });
}
