import 'dart:async';

import 'package:easy_help/logic/relay_offer.dart';
import 'package:easy_help/logic/sos_dispatcher.dart';
import 'package:easy_help/logic/sos_packet.dart';
import 'package:easy_help/services/diagnostics_hub.dart';
import 'package:flutter_test/flutter_test.dart';

SosPacket pkt(String id) => SosPacket(
    id: id, lat: 1, lng: 1, source: 'gps', uncertaintyM: 5,
    timestampMs: DateTime.now().millisecondsSinceEpoch);

void main() {
  test('offer succeeds when the UI isolate acknowledges', () async {
    final acks = StreamController<Map<String, dynamic>?>.broadcast();
    final sent = <String>[];
    final c = RelayOfferClient(
      send: (e, d) {
        sent.add(e);
        acks.add({'id': d['id'], 'ok': true});
      },
      acks: acks.stream,
    );
    expect(await c.offer(pkt('abc')), isTrue);
    expect(sent, ['relay_offer']);
  });

  test('no UI isolate: reason is "relay unavailable: app UI not running"', () async {
    final acks = StreamController<Map<String, dynamic>?>.broadcast();
    final c = RelayOfferClient(
        send: (e, d) {}, acks: acks.stream, timeout: const Duration(milliseconds: 50));
    await expectLater(
        c.offer(pkt('abc')),
        throwsA(isA<RelayUnavailable>().having((e) => e.toString(), 'msg',
            'relay unavailable: app UI not running')));
  });

  test('UI reports failure: reason passed on; other channels still run', () async {
    final acks = StreamController<Map<String, dynamic>?>.broadcast();
    final c = RelayOfferClient(
      send: (e, d) => acks.add({'id': d['id'], 'ok': false, 'reason': 'no permission'}),
      acks: acks.stream,
    );
    var smsRan = false;
    final attempts = await SosDispatcher(onAttempt: (_) {}).dispatch(
      sosId: 'abc',
      cloud: () async => throw StateError('offline'),
      sms: () async => smsRan = true,
      mesh: () => c.offer(pkt('abc')),
    );
    expect(smsRan, isTrue);
    final mesh = attempts.firstWhere((a) => a.channel == 'mesh');
    expect(mesh.ok, isFalse);
    expect(mesh.detail, contains('no permission'));
  });

  test('an ack for another packet is ignored', () async {
    final acks = StreamController<Map<String, dynamic>?>.broadcast();
    final c = RelayOfferClient(
      send: (e, d) => acks.add({'id': 'other', 'ok': true}),
      acks: acks.stream,
      timeout: const Duration(milliseconds: 50),
    );
    await expectLater(c.offer(pkt('abc')), throwsA(isA<RelayUnavailable>()));
  });

  test('relay state is never "connected" without a counted peer', () {
    final h = DiagnosticsHub.instance;
    h.advertising = false;
    h.discovering = false;
    h.connectedPeers = 0;
    h.relayUnavailableReason = 'permission missing';
    expect(h.relayState, 'unavailable');
    h.relayUnavailableReason = null;
    expect(h.relayState, 'idle');
    h.discovering = true;
    expect(h.relayState, 'discovering');
    h.connectedPeers = 1;
    expect(h.relayState, 'connected');
    h.connectedPeers = 0;
    h.discovering = false;
  });
}
