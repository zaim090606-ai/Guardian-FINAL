import 'dart:convert';

import 'package:easy_help/logic/relay_policy.dart';
import 'package:easy_help/logic/sos_packet.dart';
import 'package:easy_help/services/relay_service.dart';
import 'package:flutter_test/flutter_test.dart';

const now = 1700000000000;

SosPacket packet({
  String id = 'abc123',
  int hop = 0,
  double lat = 28.6,
  double lng = 77.2,
  String source = 'gps',
  int ts = now - 1000,
}) =>
    SosPacket(
      id: id,
      lat: lat,
      lng: lng,
      source: source,
      uncertaintyM: 5,
      timestampMs: ts,
      hop: hop,
      message: 'help',
    );

void main() {
  relayPartATests();
  group('SosPacket', () {
    test('json round trip', () {
      final p = packet(hop: 2);
      final r = SosPacket.fromJson(
          jsonDecode(jsonEncode(p.toJson())) as Map<String, dynamic>);
      expect(r.id, p.id);
      expect(r.hop, 2);
      expect(r.source, 'gps');
      expect(r.uncertaintyM, 5);
    });

    test('fromJson rejects mistyped fields', () {
      expect(() => SosPacket.fromJson({'id': 1}), throwsFormatException);
    });

    test('validation rejects bad data', () {
      expect(packet().validate(nowMs: now), isNull);
      expect(packet(id: 'a/b').validate(nowMs: now), isNotNull);
      expect(packet(id: '').validate(nowMs: now), isNotNull);
      expect(packet(lat: 91).validate(nowMs: now), isNotNull);
      expect(packet(lng: -181).validate(nowMs: now), isNotNull);
      expect(packet(source: 'telepathy').validate(nowMs: now), isNotNull);
      expect(packet(hop: 6).validate(nowMs: now), isNotNull);
      expect(packet(ts: now + 3600000).validate(nowMs: now), isNotNull);
      expect(packet(ts: now - 3 * 24 * 3600000).validate(nowMs: now),
          isNotNull);
      // 2 hour limit
      expect(packet(ts: now - 119 * 60000).validate(nowMs: now), isNull);
      expect(packet(ts: now - 121 * 60000).validate(nowMs: now),
          'packet too old');
    });

    test('nextHop increments only the hop', () {
      final n = packet(hop: 1).nextHop();
      expect(n.hop, 2);
      expect(n.id, 'abc123');
    });
  });

  group('SeenCache', () {
    test('detects duplicates and evicts oldest', () {
      final c = SeenCache(capacity: 2);
      expect(c.markIfNew('a'), isTrue);
      expect(c.markIfNew('a'), isFalse);
      c.markIfNew('b');
      c.markIfNew('c');
      expect(c.contains('a'), isFalse);
      expect(c.contains('c'), isTrue);
    });
  });

  group('PacketQueue', () {
    test('dedupes, bounds and survives encode/decode', () {
      final q = PacketQueue(capacity: 2);
      expect(q.add(packet(id: 'a')), isTrue);
      expect(q.add(packet(id: 'a')), isFalse);
      q.add(packet(id: 'b'));
      // full: the newcomer is rejected, waiting alerts are never evicted
      expect(q.add(packet(id: 'c')), isFalse);
      expect(q.items.map((e) => e.id), ['a', 'b']);
      final r = PacketQueue.decode(q.encode(), capacity: 2);
      expect(r.items.map((e) => e.id), ['a', 'b']);
    });

    test('decode tolerates garbage', () {
      expect(PacketQueue.decode('not json').length, 0);
      expect(PacketQueue.decode(null).length, 0);
      expect(PacketQueue.decode('[1,2,{"id":5}]').length, 0);
    });
  });

  group('RelayHandler', () {
    late List<SosPacket> uploads;
    late List<SosPacket> forwards;
    late bool online;
    late RelayHandler h;

    setUp(() {
      uploads = [];
      forwards = [];
      online = true;
      h = RelayHandler(
        nowMs: () => now,
        upload: (p) async {
          if (!online) return false;
          uploads.add(p);
          return true;
        },
        forward: (p) async => forwards.add(p),
      );
    });

    test('valid packet online is uploaded once', () async {
      expect(await h.handle(packet()), RelayOutcome.uploaded);
      expect(uploads.length, 1);
      expect(h.queue.length, 0);
    });

    test('duplicates are dropped', () async {
      await h.handle(packet());
      expect(await h.handle(packet()), RelayOutcome.duplicate);
      expect(uploads.length, 1);
    });

    test('invalid json and invalid packets are rejected', () async {
      expect(await h.handleRaw('nope'), RelayOutcome.invalid);
      expect(await h.handleRaw('[1]'), RelayOutcome.invalid);
      expect(await h.handle(packet(lat: 500)), RelayOutcome.invalid);
      expect(uploads, isEmpty);
    });

    test('offline: queued, forwarded with hop+1', () async {
      online = false;
      expect(await h.handle(packet(hop: 1)), RelayOutcome.queued);
      expect(h.queue.length, 1);
      expect(forwards.single.hop, 2);
    });

    test('TTL: packet at the hop limit is queued but not forwarded', () async {
      online = false;
      expect(await h.handle(packet(hop: 5)), RelayOutcome.queued);
      expect(forwards, isEmpty);
    });

    test('packet over the hop limit is rejected', () async {
      expect(await h.handle(packet(hop: 6)), RelayOutcome.invalid);
    });

    test('queued packets upload on flush when internet returns', () async {
      online = false;
      await h.handle(packet(id: 'one'));
      await h.handle(packet(id: 'two'));
      expect(await h.flush(), 0);
      expect(h.queue.length, 2);
      online = true;
      expect(await h.flush(), 2);
      expect(h.queue.length, 0);
      expect(uploads.map((e) => e.id), ['one', 'two']);
    });

    test('upload that throws is treated as offline', () async {
      final bad = RelayHandler(
        nowMs: () => now,
        upload: (p) async => throw Exception('boom'),
        forward: (p) async {},
      );
      expect(await bad.handle(packet()), RelayOutcome.queued);
    });
  });
}

void relayPartATests() {
  group('Part A relay', () {
    test('packets are offered for 30 minutes', () {
      expect(RelayService.offerWindow, const Duration(minutes: 30));
    });

    test('own packet marked as seen is never re-processed or forwarded',
        () async {
      var uploads = 0, forwards = 0;
      final h = RelayHandler(
        nowMs: () => now,
        upload: (p) async {
          uploads++;
          return false;
        },
        forward: (p) async => forwards++,
      );
      h.seen.markIfNew('mine');
      expect(await h.handle(packet(id: 'mine')), RelayOutcome.duplicate);
      expect(uploads, 0);
      expect(forwards, 0);
    });
  });
}
