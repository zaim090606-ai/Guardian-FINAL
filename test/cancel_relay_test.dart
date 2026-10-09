import 'package:easy_help/services/emergency_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cancelSos withdraws the relay even when this isolate did not dispatch', () async {
    SharedPreferences.setMockInitialValues({});
    final original = EmergencyService.meshStop;
    var stops = 0;
    EmergencyService.meshStop = () => stops++;
    try {
      await EmergencyService.cancelSos();
      expect(stops, greaterThanOrEqualTo(1));
    } finally {
      EmergencyService.meshStop = original;
    }
  });
}
