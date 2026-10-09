import 'dart:async';
import 'dart:convert';
import 'pdr_engine.dart' show formatAge;

/// Outcome of one send attempt on one channel.
class SosAttempt {
  final String sosId;
  final String channel;
  final bool ok;
  final String detail;
  final int tsMs;
  final int elapsedMs;

  const SosAttempt({
    required this.sosId,
    required this.channel,
    required this.ok,
    required this.detail,
    required this.tsMs,
    required this.elapsedMs,
  });

  Map<String, dynamic> toJson() => {
        'sosId': sosId,
        'channel': channel,
        'ok': ok,
        'detail': detail,
        'ts': tsMs,
        'ms': elapsedMs,
      };

  factory SosAttempt.fromJson(Map<String, dynamic> j) => SosAttempt(
        sosId: '${j['sosId']}',
        channel: '${j['channel']}',
        ok: j['ok'] == true,
        detail: '${j['detail']}',
        tsMs: (j['ts'] as num?)?.toInt() ?? 0,
        elapsedMs: (j['ms'] as num?)?.toInt() ?? 0,
      );

  @override
  String toString() =>
      '[$sosId] $channel ${ok ? "OK" : "FAIL"} (${elapsedMs}ms) $detail';
}

/// Bounded list of attempts that can be stored as JSON.
class AttemptLog {
  final int capacity;
  final List<SosAttempt> _items = [];

  AttemptLog({this.capacity = 50});

  List<SosAttempt> get items => List.unmodifiable(_items);

  void add(SosAttempt a) {
    _items.add(a);
    if (_items.length > capacity) _items.removeAt(0);
  }

  String encode() => jsonEncode(_items.map((e) => e.toJson()).toList());

  static AttemptLog decode(String? raw, {int capacity = 50}) {
    final log = AttemptLog(capacity: capacity);
    if (raw == null || raw.isEmpty) return log;
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        for (final e in list) {
          log.add(SosAttempt.fromJson(Map<String, dynamic>.from(e as Map)));
        }
      }
    } catch (_) {}
    return log;
  }
}

/// A channel returns true on success. It may throw; that counts as failure.
typedef SosChannel = Future<bool> Function();

/// Runs the SOS channels so that no single path is a point of failure:
///  * cloud (Firestore) and SMS start together;
///  * every channel has its own timeout and exceptions are contained;
///  * the mesh relay is tried when the cloud upload did not succeed;
///  * every attempt is reported to [onAttempt].
class SosDispatcher {
  final void Function(SosAttempt) onAttempt;
  final int Function() nowMs;
  final Duration cloudTimeout;
  final Duration smsTimeout;
  final Duration meshTimeout;

  SosDispatcher({
    required this.onAttempt,
    int Function()? nowMs,
    this.cloudTimeout = const Duration(seconds: 6),
    this.smsTimeout = const Duration(seconds: 30),
    this.meshTimeout = const Duration(seconds: 10),
  }) : nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  /// SMS and the cloud write start together, so the SMS never waits for the
  /// cloud. The mesh fallback starts as soon as the cloud channel has failed
  /// or timed out (cloudTimeout, 6 s). Offline, the cloud channel fails at once.
  /// The tracking link in the SMS is built from the locally generated id, so it
  /// does not depend on the document existing yet.
  Future<List<SosAttempt>> dispatch({
    required String sosId,
    required SosChannel cloud,
    required SosChannel sms,
    required SosChannel mesh,
  }) async {
    final cloudFuture = _run(sosId, 'cloud', cloud, cloudTimeout);
    final smsFuture = _run(sosId, 'sms', sms, smsTimeout);
    final Future<SosAttempt?> meshFuture = cloudFuture.then<SosAttempt?>(
        (c) => c.ok ? null : _run(sosId, 'mesh', mesh, meshTimeout));
    final cloudResult = await cloudFuture;
    final smsResult = await smsFuture;
    final meshResult = await meshFuture;
    return [cloudResult, smsResult, if (meshResult != null) meshResult];
  }

  Future<SosAttempt> _run(
    String sosId,
    String name,
    SosChannel channel,
    Duration timeout,
  ) async {
    final start = nowMs();
    bool ok = false;
    String detail = '';
    try {
      ok = await channel().timeout(timeout);
      if (!ok) detail = 'channel reported failure';
    } on TimeoutException {
      detail = 'timeout after ${timeout.inSeconds}s';
    } catch (e) {
      detail = 'error: $e';
    }
    final attempt = SosAttempt(
      sosId: sosId,
      channel: name,
      ok: ok,
      detail: detail,
      tsMs: start,
      elapsedMs: nowMs() - start,
    );
    try {
      onAttempt(attempt);
    } catch (_) {}
    return attempt;
  }
}

/// Cleans an emergency contact number for SMS, or returns null when it cannot
/// be a valid number. Spaces, dashes, dots and brackets are removed.
///  * "+" and digits is kept (8 to 15 digits).
///  * "00" followed by digits becomes "+" and the digits.
///  * a 10-digit Indian mobile number (starts 6-9) gets "+91"; so does the
///    same number written with a leading 0 or with 91 in front.
///  * anything else (letters, too short or too long, 10 digits that are not an
///    Indian mobile) is invalid.
String? normalizeContactNumber(String input) {
  var s = input.trim().replaceAll(RegExp(r'[\s\-\.\(\)\[\]]'), '');
  if (s.isEmpty) return null;
  final plus = s.startsWith('+');
  if (plus) s = s.substring(1);
  if (!RegExp(r'^\d+$').hasMatch(s)) return null;
  bool inRange(String d) => d.length >= 8 && d.length <= 15;
  if (plus) return inRange(s) ? '+$s' : null;
  if (s.startsWith('00')) {
    final d = s.substring(2);
    return inRange(d) && !d.startsWith('0') ? '+$d' : null;
  }
  final indian = RegExp(r'^[6-9]\d{9}$');
  if (indian.hasMatch(s)) return '+91$s';
  if (s.length == 11 && s.startsWith('0') && indian.hasMatch(s.substring(1))) {
    return '+91${s.substring(1)}';
  }
  if (s.length == 12 && s.startsWith('91') && indian.hasMatch(s.substring(2))) {
    return '+$s';
  }
  return null;
}

/// [normalizeContactNumber], with '' for an invalid number.
String normalizePhone(String input) => normalizeContactNumber(input) ?? '';

/// Contacts are stored locally as "Name (phone)"; plain numbers also work.
String extractPhone(String stored) => normalizePhone(extractRaw(stored));

/// The number part of a stored contact, not yet cleaned.
String extractRaw(String stored) {
  final m = RegExp(r'\(([^)]*)\)\s*$').firstMatch(stored);
  return m != null ? m.group(1)! : stored;
}

/// Public tracker page for an alert: <base>/alert/<id> (hosting rewrites
/// /alert/** to the tracker page, which reads the id from the path).
String buildTrackingUrl(String base, String id) {
  final b = base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  return '$b/alert/${Uri.encodeComponent(id)}';
}

/// Plain Google Maps link that works without the tracker page.
String buildMapsUrl(double lat, double lng) => 'https://maps.google.com/?q=$lat,$lng';

/// Builds the SMS text. It always carries a plain maps link (when any
/// coordinates exist) next to the tracker link, so the recipient still gets a
/// location if the tracker page cannot load.
String buildSosText({
  required String trackingUrl,
  required double lat,
  required double lng,
  required String source,
  required double uncertaintyM,
  required String trigger,
  String summary = '',
  bool simulated = false,
  int? fixAgeS,
}) {
  final hasLocation = !(lat == 0 && lng == 0) && source != 'unknown';
  final String where;
  if (hasLocation) {
    final String label;
    switch (source) {
      case 'estimated':
        label = simulated ? 'ESTIMATED, SIMULATED GPS LOSS' : 'ESTIMATED';
      case 'last_known':
        label = 'LAST KNOWN';
      default:
        label = 'GPS';
    }
    final age = source == 'estimated' && fixAgeS != null
        ? ', last GPS fix ${formatAge(fixAgeS)}'
        : '';
    where = '${buildMapsUrl(lat, lng)} ($label +/-${uncertaintyM.round()}m$age)';
  } else {
    where = 'unavailable (no location fix yet)';
  }
  final buf = StringBuffer()
    ..writeln('URGENT SOS from Guardian')
    ..writeln('Tracking: $trackingUrl')
    ..writeln('Map: $where')
    ..write('Trigger: $trigger');
  final s = summary.trim();
  if (s.isNotEmpty) {
    buf
      ..writeln()
      ..write(s.length > 160 ? '${s.substring(0, 157)}...' : s);
  }
  return buf.toString();
}
