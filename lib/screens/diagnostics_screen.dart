import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import '../logic/pdr_config.dart';
import '../logic/pdr_engine.dart' show formatAge;
import '../logic/pdr_snapshot.dart';
import '../logic/sos_dispatcher.dart';
import '../services/diagnostics_hub.dart';
import '../services/emergency_service.dart';
import '../services/relay_service.dart';

/// Shows what the offline features are doing right now so they can be checked
/// on a single phone. Anything triggered from here is labelled SIMULATED.
///
/// PDR runs in the background service; everything PDR-related here comes from
/// the snapshot the service publishes every 2 s, and switches are sent to it
/// as events. Relay numbers are measured in this (UI) isolate.
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  Timer? _timer;
  List<SosAttempt> _attempts = const [];
  String? _testMessage;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    List<SosAttempt> attempts = _attempts;
    try {
      attempts = await EmergencyService.readAttemptLog();
    } catch (_) {}
    if (mounted) setState(() => _attempts = attempts);
  }

  void _setSimulation(bool on) {
    try {
      FlutterBackgroundService().invoke('sim_gps_loss', {'enabled': on});
    } catch (_) {}
    setState(() {});
  }

  void _setFlag(PdrSnapshot snap, String name, bool on) {
    final map = {...PdrConfig().toMap(), ...snap.config}..[name] = on;
    try {
      FlutterBackgroundService().invoke('pdr_config', map);
    } catch (_) {}
    setState(() {});
  }

  void _setAllFlags(bool on) {
    final cfg = PdrConfig()..setAll(on);
    try {
      FlutterBackgroundService().invoke('pdr_config', cfg.toMap());
    } catch (_) {}
    setState(() {});
  }

  String? _anchorMessage;

  /// SIMULATED: pretends a nearby phone with good GPS is standing at the real
  /// GPS position (ground truth read while GPS loss is simulated).
  void _sendTestAnchor(PdrSnapshot? snap) {
    final m = snap?.meter ?? const {};
    if (snap == null || !snap.simulate || m['hasTruth'] != true) {
      setState(() => _anchorMessage =
          'SIMULATED anchor needs "Simulate GPS loss" ON and a real GPS reading.');
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    try {
      FlutterBackgroundService().invoke('test_anchor', {
        'type': 'anchor_beacon',
        'lat': m['truthLat'],
        'lng': m['truthLng'],
        'accuracyM': 10.0,
        'timestamp': now,
        'source': 'gps',
      });
      setState(() => _anchorMessage =
          'SIMULATED anchor sent to the service; see "Last anchor" in a moment.');
    } catch (e) {
      setState(() => _anchorMessage = 'Could not reach the service: $e');
    }
  }

  Future<void> _sendTestRelay(PdrSnapshot? snap) async {
    try {
      final fix = snap?.locationFix(DateTime.now().millisecondsSinceEpoch);
      final ok = await RelayService()
          .sendTestPacket(lat: fix?.lat ?? 0, lng: fix?.lng ?? 0);
      setState(() => _testMessage = ok
          ? 'SIMULATED test packet offered to nearby phones at ${_clock(DateTime.now().millisecondsSinceEpoch)}'
          : 'Relay unavailable: ${DiagnosticsHub.instance.relayUnavailableReason ?? "advertising did not start"}');
    } catch (e) {
      setState(() => _testMessage = 'Relay unavailable: $e');
    }
  }

  String _clock(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final remote = DiagnosticsHub.remote.value;
    final hub = DiagnosticsHub.instance;
    final snap = DiagnosticsHub.pdrSnapshot();
    final running = snap != null && snap.isFresh(nowMs);
    final fix = running ? snap.locationFix(nowMs) : null;
    final simulated = running && snap.simulate;

    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (!running)
            _banner('PDR not running: the background service is not reporting'),
          if (simulated) _banner('SIMULATED: GPS is being ignored on purpose'),
          _section('Location', [
            _row('Source', fix == null ? 'none yet' : fix.source.toUpperCase()),
            _row('Uncertainty',
                fix == null ? '-' : '+/- ${fix.uncertaintyM.toStringAsFixed(1)} m'),
            if (fix != null && fix.source == 'estimated')
              _row('Age since last GPS fix', formatAge(fix.ageSinceGpsS)),
            _row(
                'Last real GPS fix',
                !running || snap.lastGpsMs == null
                    ? 'never'
                    : '${((nowMs - snap.lastGpsMs!) / 1000).round()} s ago'),
            _row('Steps counted', running ? '${snap.steps}' : '-'),
            _row(
                'Heading',
                !running || snap.heading == null
                    ? 'no compass data'
                    : '${snap.heading!.round()} deg'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Simulate GPS loss'),
              subtitle: const Text('Ignores the GPS stream so dead reckoning can be shown indoors. Walk with the phone in your hand. Switches off again when the service restarts.'),
              value: simulated,
              onChanged: running ? _setSimulation : null,
            ),
          ]),
          _section('Dead-reckoning error vs real GPS', _groundTruth(snap, running)),
          _section('PDR improvements', _flags(snap, running)),
          _section('Motion context and anchors', _contextAndAnchors(snap, running, nowMs)),
          _section('Mesh relay', [
            _row('State', hub.relayState),
            if (hub.relayUnavailableReason != null)
              Text('Reason: ${hub.relayUnavailableReason}',
                  style: TextStyle(fontSize: 12, color: Colors.red.shade800)),
            const Text('Relay works while the app is open or alive in recents.',
                style: TextStyle(fontSize: 11)),
            _row('Peers found', '${hub.peersFound}'),
            _row('Sent / received', '${hub.sent} / ${hub.received}'),
            _row('Queued / uploaded / waiting',
                '${hub.queued} / ${hub.uploaded} / ${hub.pending}'),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: () => _sendTestRelay(snap),
              child: const Text('Send test SOS via relay (SIMULATED)'),
            ),
            if (_testMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_testMessage!, style: const TextStyle(fontSize: 12)),
              ),
            const SizedBox(height: 8),
            const Text('Last 10 events', style: TextStyle(fontWeight: FontWeight.bold)),
            ..._events(hub.relayEvents.toJson()),
          ]),
          _section('SOS send attempts', [
            if (_attempts.isEmpty) const Text('No SOS has been sent yet.'),
            for (final a in _attempts.reversed.take(12))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(
                  '${_clock(a.tsMs)}  ${_channelName(a.channel)}  '
                  '${a.ok ? "OK" : "FAILED"}'
                  '${a.detail.isEmpty ? "" : " - ${a.detail}"}',
                  style: TextStyle(
                    fontSize: 12,
                    color: a.ok ? Colors.green.shade800 : Colors.red.shade800,
                  ),
                ),
              ),
          ]),
          _section('Audio', [
            _row('Microphone', '${remote['micStatus'] ?? 'service not reporting'}'),
            _row('YAMNet model', remote['yamnetLoaded'] == true ? 'loaded' : 'not loaded'),
            _row('Whisper model', remote['whisperLoaded'] == true ? 'loaded' : 'not loaded'),
            _row(
              'Last sound class',
              (remote['lastLabel'] as String?)?.isNotEmpty == true
                  ? '${remote['lastLabel']} (${(((remote['lastScore'] as num?) ?? 0) * 100).round()}%)'
                  : 'nothing heard yet',
            ),
          ]),
        ],
      ),
    );
  }

  List<Widget> _groundTruth(PdrSnapshot? snap, bool running) {
    final m = running ? snap!.meter : const <String, dynamic>{};
    String metres(num? v) => v == null ? '-' : '${v.toStringAsFixed(1)} m';
    final active = m['active'] == true;
    final hasRun = m['hasRun'] == true;
    final percent = (m['percent'] as num?);
    return [
      if (active)
        _banner('SIMULATED GPS loss: real GPS is read only to measure the error'),
      _row('Walked since loss (steps x stride)',
          '${((m['walkedM'] as num?) ?? 0).toStringAsFixed(0)} m'),
      _row('Current error vs real GPS', metres(m['errorM'] as num?)),
      _row('Max error', metres(hasRun ? m['maxErrorM'] as num? : null)),
      _row('Error / distance',
          percent == null ? '-' : '${percent.toStringAsFixed(0)} %'),
      const SizedBox(height: 6),
      Container(
        padding: const EdgeInsets.all(10),
        color: Colors.blueGrey.shade50,
        child: SelectableText(
          'Run summary${active ? ' (running, SIMULATED loss)' : ''}: '
          '${m['summary'] ?? 'PDR not running'}\n'
          'Flags: ${_flagLine(snap?.config ?? const {})}',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
      ),
      const Text(
          'The truth is a GPS reading with its own error of several metres.',
          style: TextStyle(fontSize: 11)),
    ];
  }

  String _flagLine(Map<String, bool> c) =>
      c.entries.map((e) => '${e.key}=${e.value ? "ON" : "OFF"}').join(' ');

  List<Widget> _flags(PdrSnapshot? snap, bool running) {
    final c = snap?.config ?? const <String, bool>{};
    Widget sw(String title, String key, String sub) {
      final value = c[key] ?? true;
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        title: Text('$title: ${value ? "ON" : "OFF"}'),
        subtitle: Text(sub, style: const TextStyle(fontSize: 11)),
        value: value,
        onChanged: running ? (v) => _setFlag(snap!, key, v) : null,
      );
    }

    final offset = snap?.offsetDeg;
    return [
      Row(children: [
        OutlinedButton(
            onPressed: running ? () => _setAllFlags(true) : null,
            child: const Text('All ON')),
        const SizedBox(width: 8),
        OutlinedButton(
            onPressed: running ? () => _setAllFlags(false) : null,
            child: const Text('All OFF')),
      ]),
      sw('Compass gating', 'compassGating',
          'Ignore magnetometer samples outside 25-65 uT'),
      sw('Heading offset', 'headingOffset',
          'Learn GPS course minus compass while GPS is good'),
      sw('Stride learning', 'strideLearning',
          'Learn stride from GPS distance / steps'),
      sw('Microphone context', 'microphoneContext',
          'Vehicle / stationary from YAMNet sound labels'),
      sw('Anchors', 'anchors',
          'Use positions of nearby Guardian phones with good GPS'),
      const Divider(),
      _row(
          'Heading offset learned',
          !running
              ? '-'
              : offset == null
                  ? (snap!.offsetInvalidated ? 'invalid (phone moved)' : 'not yet')
                  : '${offset.toStringAsFixed(1)} deg'),
      _row(
          'Stride in use',
          !running
              ? '-'
              : '${snap!.strideM.toStringAsFixed(2)} m${snap.strideCalibrated ? " (learned)" : " (default)"}'),
      _row('Drift fraction (assumption)',
          running ? snap!.driftFraction.toStringAsFixed(2) : '-'),
      _row('Compass samples rejected', running ? '${snap!.rejectedMagSamples}' : '-'),
      _row('Learning windows rejected', running ? '${snap!.rejectedWindows}' : '-'),
    ];
  }

  List<Widget> _contextAndAnchors(PdrSnapshot? snap, bool running, int now) {
    final a = running ? snap!.lastAnchor : null;
    num n(String k) => (a?[k] as num?) ?? 0;
    return [
      _row('Motion context (service)', running ? snap!.motionContext : '-'),
      _row(
          'Last anchor',
          a == null
              ? 'none'
              : '${formatAge(((now - n('atMs').toInt()) / 1000).round())}${a['simulated'] == true ? " (SIMULATED)" : ""}'),
      if (a != null) ...[
        _row('Anchor age when used', '${n('ageS').toInt()} s'),
        _row('Radius before -> after',
            '${n('before').round()} m -> ${n('after').round()} m'),
        _row('Action', a['snapped'] == true ? 'snapped to anchor' : 'weighted'),
      ],
      const SizedBox(height: 6),
      OutlinedButton(
        onPressed: running ? () => _sendTestAnchor(snap) : null,
        child: const Text('Send test anchor (SIMULATED beacon)'),
      ),
      if (_anchorMessage != null)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(_anchorMessage!, style: const TextStyle(fontSize: 12)),
        ),
    ];
  }

  String _channelName(String c) => switch (c) {
        'cloud' => 'firestore',
        'mesh' => 'relay',
        _ => c,
      };

  List<Widget> _events(Object? events) {
    if (events is! List || events.isEmpty) {
      return [const Text('none yet', style: TextStyle(fontSize: 12))];
    }
    return [
      for (final e in events.take(10))
        Text('${_clock((e['t'] as num).toInt())}  ${e['m']}',
            style: const TextStyle(fontSize: 12)),
    ];
  }

  Widget _banner(String text) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(10),
        color: Colors.orange.shade200,
        child: Text(text, style: const TextStyle(fontWeight: FontWeight.bold)),
      );

  Widget _section(String title, List<Widget> children) => Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              ...children,
            ],
          ),
        ),
      );

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(k),
            Flexible(child: Text(v, textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w600))),
          ],
        ),
      );
}
