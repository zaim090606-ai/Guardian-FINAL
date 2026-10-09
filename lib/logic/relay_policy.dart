import 'dart:collection';
import 'dart:convert';

import 'sos_packet.dart';

/// Bounded "have I seen this alert id" set (oldest entries are evicted first).
class SeenCache {
  final int capacity;
  final LinkedHashSet<String> _ids = LinkedHashSet<String>();

  SeenCache({this.capacity = 500});

  /// Returns true the first time [id] is seen, false for duplicates.
  bool markIfNew(String id) {
    if (_ids.contains(id)) return false;
    _ids.add(id);
    if (_ids.length > capacity) _ids.remove(_ids.first);
    return true;
  }

  bool contains(String id) => _ids.contains(id);

  /// Forgets [id] again (a packet that could not be kept must be acceptable
  /// later).
  void remove(String id) => _ids.remove(id);
}

/// At most [max] events per [window] for each key (an endpoint, or one shared
/// key for a global limit).
class SlidingRateLimiter {
  final int max;
  final Duration window;
  final Map<String, List<int>> _hits = {};
  SlidingRateLimiter({required this.max, this.window = const Duration(minutes: 1)});

  /// Records an event and returns true while the key is within its limit.
  bool allow(String key, int nowMs) {
    final list = _hits.putIfAbsent(key, () => []);
    list.removeWhere((t) => nowMs - t >= window.inMilliseconds);
    if (list.length >= max) return false;
    list.add(nowMs);
    if (_hits.length > 200) {
      _hits.removeWhere((k, v) => v.every((t) => nowMs - t >= window.inMilliseconds));
    }
    return true;
  }
}

/// Limits how often one endpoint may hand out beacons (helper side).
class BeaconLimiter {
  final Duration interval;
  final Map<String, int> _last = {};
  BeaconLimiter({this.interval = const Duration(seconds: 30)});

  /// True at most once per [interval] for each endpoint.
  bool allow(String endpointId, int nowMs) {
    final last = _last[endpointId];
    if (last != null && nowMs - last < interval.inMilliseconds) return false;
    _last[endpointId] = nowMs;
    return true;
  }

  void forget(String endpointId) => _last.remove(endpointId);
}

/// Ids of SOS packets this phone created, kept across restarts so a packet
/// that comes back through a relayer is never processed as someone else's.
class OwnPacketIds {
  final int capacity;
  final List<String> ids = [];
  OwnPacketIds({this.capacity = 100});

  void add(String id) {
    if (ids.contains(id)) return;
    ids.add(id);
    if (ids.length > capacity) ids.removeAt(0);
  }

  String encode() => jsonEncode(ids);

  static OwnPacketIds decode(String? raw, {int capacity = 100}) {
    final r = OwnPacketIds(capacity: capacity);
    if (raw == null || raw.isEmpty) return r;
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        for (final e in list) {
          if (e is String) r.add(e);
        }
      }
    } catch (_) {}
    return r;
  }
}

/// Packets waiting for an internet connection. Deduplicated by id and bounded.
class PacketQueue {
  final int capacity;
  final List<SosPacket> _items = [];

  PacketQueue({this.capacity = 100});

  List<SosPacket> get items => List.unmodifiable(_items);
  int get length => _items.length;

  bool get isFull => _items.length >= capacity;

  /// Adds [p]; false for a duplicate id or when the queue is full. A full
  /// queue never evicts packets that are already waiting.
  bool add(SosPacket p) {
    if (_items.any((e) => e.id == p.id)) return false;
    if (isFull) return false;
    _items.add(p);
    return true;
  }

  void remove(String id) => _items.removeWhere((e) => e.id == id);

  String encode() => jsonEncode(_items.map((e) => e.toJson()).toList());

  /// Restores a queue saved with [encode]; unreadable entries are skipped.
  static PacketQueue decode(String? raw, {int capacity = 100}) {
    final q = PacketQueue(capacity: capacity);
    if (raw == null || raw.isEmpty) return q;
    try {
      final list = jsonDecode(raw);
      if (list is List) {
        for (final e in list) {
          try {
            q.add(SosPacket.fromJson(Map<String, dynamic>.from(e as Map)));
          } catch (_) {}
        }
      }
    } catch (_) {}
    return q;
  }
}

enum RelayOutcome { invalid, duplicate, uploaded, queued, rateLimited, queueFull }

/// Receiver-side pipeline: validate, de-duplicate, upload; if the upload does
/// not succeed, queue and forward to further peers while the hop limit allows.
class RelayHandler {
  final int maxHops;

  /// Shortest accepted alert id. Firestore rules need 20+ characters, so a
  /// shorter id could never be uploaded and would sit in the queue forever.
  final int minIdLength;
  final SeenCache seen;
  final PacketQueue queue;
  final int Function() nowMs;

  /// 3 packets per minute from one endpoint, 30 new ids per minute overall.
  final SlidingRateLimiter perEndpoint;
  final SlidingRateLimiter globalUnique;

  /// Must return true only when the packet is stored remotely.
  final Future<bool> Function(SosPacket) upload;

  /// Re-broadcasts a packet (already hop-incremented) to nearby peers.
  final Future<void> Function(SosPacket) forward;

  RelayHandler({
    required this.upload,
    required this.forward,
    required this.nowMs,
    SeenCache? seen,
    PacketQueue? queue,
    this.maxHops = 5,
    this.minIdLength = 1,
    SlidingRateLimiter? perEndpoint,
    SlidingRateLimiter? globalUnique,
  })  : seen = seen ?? SeenCache(),
        queue = queue ?? PacketQueue(),
        perEndpoint = perEndpoint ?? SlidingRateLimiter(max: 3),
        globalUnique = globalUnique ?? SlidingRateLimiter(max: 30);

  Future<RelayOutcome> handleRaw(String json, {String endpointId = ''}) async {
    // Every packet counts against its sender, valid or not.
    if (!perEndpoint.allow(endpointId, nowMs())) return RelayOutcome.rateLimited;
    final SosPacket packet;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map) return RelayOutcome.invalid;
      packet = SosPacket.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return RelayOutcome.invalid;
    }
    return handle(packet);
  }

  Future<RelayOutcome> handle(SosPacket packet) async {
    if (packet.id.length < minIdLength ||
        packet.validate(nowMs: nowMs(), maxHops: maxHops) != null) {
      return RelayOutcome.invalid;
    }
    if (seen.contains(packet.id)) return RelayOutcome.duplicate;
    if (!globalUnique.allow('all', nowMs())) return RelayOutcome.rateLimited;
    seen.markIfNew(packet.id);

    bool uploaded = false;
    try {
      uploaded = await upload(packet);
    } catch (_) {}
    if (uploaded) return RelayOutcome.uploaded;

    // A full queue rejects the newcomer; it never drops a waiting alert.
    if (!queue.add(packet)) {
      seen.remove(packet.id);
      return queue.items.any((e) => e.id == packet.id)
          ? RelayOutcome.duplicate
          : RelayOutcome.queueFull;
    }
    if (packet.hop + 1 <= maxHops) {
      try {
        await forward(packet.nextHop());
      } catch (_) {}
    }
    return RelayOutcome.queued;
  }

  /// Retries every queued packet; returns how many were uploaded. Packets
  /// that are no longer valid (older than 2 h, bad id) are dropped first, so
  /// stale or hostile entries cannot fill the queue.
  Future<int> flush() async {
    int done = 0;
    for (final p in List<SosPacket>.from(queue.items)) {
      if (p.id.length < minIdLength ||
          p.validate(nowMs: nowMs(), maxHops: maxHops) != null) {
        queue.remove(p.id);
        continue;
      }
      bool ok = false;
      try {
        ok = await upload(p);
      } catch (_) {}
      if (ok) {
        queue.remove(p.id);
        done++;
      }
    }
    return done;
  }
}
