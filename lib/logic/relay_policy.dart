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

  bool add(SosPacket p) {
    if (_items.any((e) => e.id == p.id)) return false;
    _items.add(p);
    if (_items.length > capacity) _items.removeAt(0);
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

enum RelayOutcome { invalid, duplicate, uploaded, queued }

/// Receiver-side pipeline: validate, de-duplicate, upload; if the upload does
/// not succeed, queue and forward to further peers while the hop limit allows.
class RelayHandler {
  final int maxHops;
  final SeenCache seen;
  final PacketQueue queue;
  final int Function() nowMs;

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
  })  : seen = seen ?? SeenCache(),
        queue = queue ?? PacketQueue();

  Future<RelayOutcome> handleRaw(String json) async {
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
    if (packet.validate(nowMs: nowMs(), maxHops: maxHops) != null) {
      return RelayOutcome.invalid;
    }
    if (!seen.markIfNew(packet.id)) return RelayOutcome.duplicate;

    bool uploaded = false;
    try {
      uploaded = await upload(packet);
    } catch (_) {}
    if (uploaded) return RelayOutcome.uploaded;

    queue.add(packet);
    if (packet.hop + 1 <= maxHops) {
      try {
        await forward(packet.nextHop());
      } catch (_) {}
    }
    return RelayOutcome.queued;
  }

  /// Retries every queued packet; returns how many were uploaded.
  Future<int> flush() async {
    int done = 0;
    for (final p in List<SosPacket>.from(queue.items)) {
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
