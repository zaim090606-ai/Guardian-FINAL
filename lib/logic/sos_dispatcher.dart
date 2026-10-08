import 'dart:async';
import 'dart:convert';

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
    this.cloudTimeout = const Duration(seconds: 8),
    this.smsTimeout = const Duration(seconds: 30),
    this.meshTimeout = const Duration(seconds: 10),
  }) : nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  Future<List<SosAttempt>> dispatch({
    required String sosId,
    required SosChannel cloud,
    required SosChannel sms,
    required SosChannel mesh,
  }) async {
    final smsFuture = _run(sosId, 'sms', sms, smsTimeout);
    final cloudResult = await _run(sosId, 'cloud', cloud, cloudTimeout);
    Future<SosAttempt>? meshFuture;
    if (!cloudResult.ok) {
      meshFuture = _run(sosId, 'mesh', mesh, meshTimeout);
    }
    final smsResult = await smsFuture;
    return [
      cloudResult,
      smsResult,
      if (meshFuture != null) await meshFuture,
    ];
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

/// E.164-style clean-up: keeps digits and a leading plus; 10-digit numbers get
/// the +91 prefix (this app targets India).
String normalizePhone(String input) {
  final cleaned = input.replaceAll(RegExp(r'[^\d+]'), '');
  if (cleaned.length == 10 && !cleaned.startsWith('+')) return '+91$cleaned';
  return cleaned;
}

/// Contacts are stored locally as "Name (phone)"; plain numbers also work.
String extractPhone(String stored) {
  final m = RegExp(r'\(([^)]*)\)\s*$').firstMatch(stored);
  return normalizePhone(m != null ? m.group(1)! : stored);
}

/// Builds the SMS text. Always carries coordinates so it is useful even when
/// the tracking page cannot be reached.
String buildSosText({
  required String trackingUrl,
  required double lat,
  required double lng,
  required String source,
  required double uncertaintyM,
  required String trigger,
  String summary = '',
}) {
  final hasLocation = !(lat == 0 && lng == 0) && source != 'unknown';
  final String where;
  if (hasLocation) {
    final label = source == 'estimated' ? 'ESTIMATED' : 'GPS';
    where = 'https://maps.google.com/?q=$lat,$lng ($label +/-${uncertaintyM.round()}m)';
  } else {
    where = 'unavailable';
  }
  final buf = StringBuffer('URGENT SOS from Guardian\n')
    ..writeln('Tracking: $trackingUrl')
    ..writeln('Location: $where')
    ..write('Trigger: $trigger');
  final s = summary.trim();
  if (s.isNotEmpty) {
    buf.write('\n${s.length > 160 ? '${s.substring(0, 157)}...' : s}');
  }
  return buf.toString();
}
