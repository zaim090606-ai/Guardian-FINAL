import 'package:shared_preferences/shared_preferences.dart';

import '../logic/sos_guard.dart';

/// [KeyValueStore] on SharedPreferences. Reads call reload() first so a write
/// made by the other isolate (UI or background service) is visible.
class PrefsKeyValueStore implements KeyValueStore {
  @override
  Future<String?> read(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getString(key);
  }

  @override
  Future<void> write(String key, String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(key, value);
  }

  @override
  Future<void> remove(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(key);
  }
}
