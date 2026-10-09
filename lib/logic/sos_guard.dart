import 'dart:convert';
import 'dart:math';

/// Minimal async key/value storage (SharedPreferences in the app, a map in
/// tests). Implementations must read fresh values (reload) so two isolates see
/// each other's writes.
abstract class KeyValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);
}

class MemoryKeyValueStore implements KeyValueStore {
  final Map<String, String> data = {};
  @override
  Future<String?> read(String key) async => data[key];
  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> remove(String key) async => data.remove(key);
}

/// Random 20-character id from Firestore's auto-id alphabet. Needs no network,
/// so the tracking link can be built before any I/O.
String generateAlertId([Random? rng]) {
  const chars =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final r = rng ?? Random.secure();
  return String.fromCharCodes(
      List.generate(20, (_) => chars.codeUnitAt(r.nextInt(chars.length))));
}

class GuardResult {
  /// The SOS id to use: a fresh one, or the one already active.
  final String id;

  /// True when this call started a new SOS; false when it reused an active one.
  final bool isNew;
  const GuardResult(this.id, this.isNew);
}

/// Persisted "an SOS is active" record shared by the UI and service isolates,
/// so a voice trigger and a button press cannot send two SOS.
class SosGuard {
  static const String key = 'active_sos';

  /// A record whose heartbeat is older than this is stale (crash, killed
  /// isolate, missed cancel). The live-tracking timer refreshes it every 5 s,
  /// so a running SOS never expires and a dead one frees the guard within a
  /// minute.
  static const Duration maxActive = Duration(seconds: 60);

  /// Pause between writing and re-reading, so two isolates that wrote at the
  /// same moment both see the same (last) writer.
  final Duration settle;

  final KeyValueStore store;
  SosGuard(this.store, {this.settle = const Duration(milliseconds: 150)});

  /// Starts [newId] unless an SOS is already active, in which case that one is
  /// returned and nothing should be sent again.
  Future<GuardResult> begin(String newId, int nowMs) async {
    final existing = await active(nowMs);
    if (existing != null) return GuardResult(existing, false);
    await store.write(
        key, jsonEncode({'id': newId, 'startMs': nowMs, 'beatMs': nowMs}));
    // Two isolates may have written at the same moment: the last writer wins.
    if (settle > Duration.zero) await Future<void>.delayed(settle);
    final after = await active(nowMs);
    if (after != null && after != newId) return GuardResult(after, false);
    return GuardResult(newId, true);
  }

  Future<String?> active(int nowMs) async {
    final raw = await store.read(key);
    if (raw == null || raw.isEmpty) return null;
    try {
      final m = jsonDecode(raw) as Map;
      final id = m['id'];
      final start = (m['startMs'] as num?)?.toInt() ?? 0;
      final beat = (m['beatMs'] as num?)?.toInt() ?? start;
      if (id is! String || id.isEmpty) return null;
      final age = nowMs - beat;
      // Too old, or stamped in the future (clock set back): never block forever.
      if (age > maxActive.inMilliseconds || age < -maxActive.inMilliseconds) {
        return null;
      }
      return id;
    } catch (_) {
      return null;
    }
  }

  /// Marks the SOS [id] as still running. Does nothing if another SOS (or none)
  /// owns the record, so a cancelled SOS cannot be revived.
  Future<void> heartbeat(String id, int nowMs) async {
    final raw = await store.read(key);
    if (raw == null || raw.isEmpty) return;
    try {
      final m = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      if (m['id'] != id) return;
      m['beatMs'] = nowMs;
      await store.write(key, jsonEncode(m));
    } catch (_) {}
  }

  Future<void> clear() => store.remove(key);
}

/// What to stop when the user cancels an SOS: live tracking timers, Firestore
/// location writes and relay advertising register themselves here. Each
/// isolate has its own session; the UI also sends `cancel_sos` to the service,
/// and the service answers with `relay_stop` for a relay the UI advertises.
class SosSession {
  final SosGuard guard;
  final List<void Function()> _onCancel = [];
  SosSession(this.guard);

  void onCancel(void Function() stop) => _onCancel.add(stop);

  /// Runs every registered stop once (a failing one cannot block the rest)
  /// and clears the persisted guard.
  Future<void> cancel() async {
    final stops = List<void Function()>.from(_onCancel);
    _onCancel.clear();
    for (final s in stops) {
      try {
        s();
      } catch (_) {}
    }
    try {
      await guard.clear();
    } catch (_) {}
  }
}
