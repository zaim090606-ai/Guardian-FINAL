import 'package:easy_help/logic/relay_policy.dart';
import 'package:easy_help/logic/sos_packet.dart';
import 'package:flutter_test/flutter_test.dart';

const now = 1700000000000;

SosPacket pk(String id, {int ts = now - 1000}) => SosPacket(
    id: id, lat: 28.6, lng: 77.2, source: 'gps', uncertaintyM: 5, timestampMs: ts);

String json(String id, {int ts = now - 1000}) =>
    '{"id":"$id","lat":28.6,"lng":77.2,"source":"gps",'
    '"uncertaintyM":5,"timestamp":$ts,"hop":0,"message":"x"}';

void main() {
  late int clock;
  RelayHandler make({bool online = false, PacketQueue? queue}) => RelayHandler(
        upload: (p) async => online,
        forward: (p) async {},
        nowMs: () => clock,
        queue: queue,
      );
  setUp(() => clock = now);

  test('an endpoint may send 3 packets a minute, the 4th is rate limited',
      () async {
    final h = make();
    for (final id in ['a1', 'a2', 'a3']) {
      expect(await h.handleRaw(json(id), endpointId: 'E1'), RelayOutcome.queued);
    }
    expect(await h.handleRaw(json('a4'), endpointId: 'E1'),
        RelayOutcome.rateLimited);
    // another endpoint is unaffected
    expect(await h.handleRaw(json('b1'), endpointId: 'E2'), RelayOutcome.queued);
    // a minute later the first endpoint may send again
    clock += 61000;
    expect(await h.handleRaw(json('a4', ts: clock - 1000), endpointId: 'E1'),
        RelayOutcome.queued);
  });

  test('junk also counts against the endpoint', () async {
    final h = make();
    for (var i = 0; i < 3; i++) {
      expect(await h.handleRaw('junk', endpointId: 'E1'), RelayOutcome.invalid);
    }
    expect(await h.handleRaw(json('ok1'), endpointId: 'E1'),
        RelayOutcome.rateLimited);
  });

  test('total unique ids per minute are capped across endpoints', () async {
    final h = RelayHandler(
      upload: (p) async => false,
      forward: (p) async {},
      nowMs: () => clock,
      globalUnique: SlidingRateLimiter(max: 5),
      perEndpoint: SlidingRateLimiter(max: 100),
    );
    var queued = 0, limited = 0;
    for (var i = 0; i < 9; i++) {
      final o = await h.handleRaw(json('id$i'), endpointId: 'E$i');
      if (o == RelayOutcome.queued) queued++;
      if (o == RelayOutcome.rateLimited) limited++;
    }
    expect(queued, 5);
    expect(limited, 4);
    // duplicates do not use the unique-id budget
    expect(await h.handleRaw(json('id0'), endpointId: 'Z'),
        RelayOutcome.duplicate);
  });

  test('a full queue rejects new packets and keeps the waiting ones', () async {
    final q = PacketQueue(capacity: 2);
    final h = RelayHandler(
      upload: (p) async => false,
      forward: (p) async {},
      nowMs: () => clock,
      queue: q,
      perEndpoint: SlidingRateLimiter(max: 100),
    );
    expect(await h.handleRaw(json('q1'), endpointId: 'A'), RelayOutcome.queued);
    expect(await h.handleRaw(json('q2'), endpointId: 'A'), RelayOutcome.queued);
    expect(
        await h.handleRaw(json('q3'), endpointId: 'A'), RelayOutcome.queueFull);
    expect(q.items.map((e) => e.id), ['q1', 'q2']);
    // the rejected packet can be accepted later, once there is room
    q.remove('q1');
    expect(await h.handleRaw(json('q3'), endpointId: 'A'), RelayOutcome.queued);
  });

  test('when online a full queue does not matter (packet is uploaded)',
      () async {
    final q = PacketQueue(capacity: 1)..add(pk('w1'));
    final h = RelayHandler(
      upload: (p) async => true,
      forward: (p) async {},
      nowMs: () => clock,
      queue: q,
    );
    expect(
        await h.handleRaw(json('n1'), endpointId: 'A'), RelayOutcome.uploaded);
  });

  test('packets older than 2 hours are invalid', () async {
    final h = make();
    expect(await h.handleRaw(json('old1', ts: now - 3 * 3600000), endpointId: 'A'),
        RelayOutcome.invalid);
    expect(await h.handleRaw(json('new1', ts: now - 3600000), endpointId: 'B'),
        RelayOutcome.queued);
  });

  test('beacons: at most one per endpoint per 30 s', () {
    final l = BeaconLimiter();
    expect(l.allow('E1', 0), isTrue);
    expect(l.allow('E1', 10000), isFalse);
    expect(l.allow('E2', 10000), isTrue);
    expect(l.allow('E1', 29999), isFalse);
    expect(l.allow('E1', 30000), isTrue);
  });

  test('sliding limiter forgets old events', () {
    final l = SlidingRateLimiter(max: 2);
    expect(l.allow('k', 0), isTrue);
    expect(l.allow('k', 1), isTrue);
    expect(l.allow('k', 2), isFalse);
    expect(l.allow('k', 60001), isTrue);
  });
}
