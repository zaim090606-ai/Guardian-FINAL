import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

import '../logic/anchor_beacon.dart';
import '../logic/pdr_config.dart';
import '../logic/pdr_engine.dart' show formatAge;
import '../logic/sos_dispatcher.dart';
import '../services/diagnostics_hub.dart';
import '../services/emergency_service.dart';
import '../services/pdr_services.dart';

/// Shows what the offline features are doing right now so they can be checked
/// on a single phone. Anything triggered from here is labelled SIMULATED.
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
    PdrService().simulateGpsLoss = on;
    try {
      FlutterBackgroundService().invoke('sim_gps_loss', {'enabled': on});
    } catch (_) {}
    setState(() {});
  }

  void _setFlag(String name, bool on) {
    final cfg = PdrService().config;
    final map = cfg.toMap()..[name] = on;
    cfg.applyMap(map);
    try {
      FlutterBackgroundService().invoke('pdr_config', map);
    } catch (_) {}
    setState(() {});
  }

  void _setAllFlags(bool on) {
    final cfg = PdrService().config..setAll(on);
    try {
      FlutterBackgroundService().invoke('pdr_config', cfg.toMap());
    } catch (_) {}
    setState(() {});
  }

  String? _anchorMessage;

  /// SIMULATED: pretends a nearby phone with good GPS is standing at the real
  /// GPS position (ground truth read while GPS loss is simulated).
  void _sendTestAnchor() {
    final pdr = PdrService();
    final m = pdr.errorMeter;
    if (!pdr.simulateGpsLoss || !m.hasTruth) {
      setState(() => _anchorMessage =
          'SIMULATED anchor needs "Simulate GPS loss" ON and a real GPS reading.');
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final b = AnchorBeacon(
        lat: m.truthLat!, lng: m.truthLng!, accuracyM: 10, timestampMs: now);
    final e = pdr.onAnchor(b, simulated: true);
    try {
      FlutterBackgroundService().invoke('test_anchor', b.toJson());
    } catch (_) {}
    setState(() => _anchorMessage = e == null
        ? 'SIMULATED anchor not used (flag off, or the estimate is still GPS-fresh).'
        : 'SIMULATED anchor used: radius ${e.radiusBeforeM.round()} -> ${e.radiusAfterM.round()} m');
  }

  Future<void> _sendTestRelay() async {
    try {
      FlutterBackgroundService().invoke('send_test_relay');
      setState(() => _testMessage =
          'SIMULATED test packet offered to nearby phones at ${_clock(DateTime.now().millisecondsSinceEpoch)}');
    } catch (e) {
      setState(() => _testMessage = 'Could not reach the background service: $e');
    }
  }

  String _clock(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  @override
  Widget build(BuildContext context) {
    final pdr = PdrService();
    final fix = pdr.currentFix();
    final simulated = pdr.simulateGpsLoss;
    final remote = DiagnosticsHub.remote.value;

    return Scaffold(
      appBar: AppBar(title: const Text('Diagnostics')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (simulated) _banner('SIMULATED: GPS is being ignored on purpose'),
          _section('Location', [
            _row('Source', fix == null ? 'none yet' : fix.source.toUpperCase()),
            _row('Uncertainty',
                fix == null ? '-' : '+/- ${fix.uncertaintyM.toStringAsFixed(1)} m'),
            if (fix != null && fix.source == 'estimated')
              _row('Age since last GPS fix', formatAge(fix.ageSinceGpsS)),
            _row('Last real GPS fix',
                pdr.lastGpsAgeMs == null ? 'never' : '${(pdr.lastGpsAgeMs! / 1000).round()} s ago'),
            _row('Steps counted', '${pdr.steps}'),
            _row('Heading',
                pdr.heading == null ? 'no compass data' : '${pdr.heading!.round()} deg'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Simulate GPS loss'),
              subtitle: const Text('Ignores the GPS stream so dead reckoning can be shown indoors. Walk with the phone in your hand.'),
              value: simulated,
              onChanged: _setSimulation,
            ),
          ]),
          _section('Dead-reckoning error vs real GPS', _groundTruth(pdr)),
          _section('PDR improvements', _flags(pdr)),
          _section('Motion context and anchors', _contextAndAnchors(pdr, remote)),
          _section('Mesh relay', [
            _row('State', '${remote['relayState'] ?? 'service not reporting'}'),
            _row('Peers found', '${remote['peersFound'] ?? 0}'),
            _row('Sent / received', '${remote['sent'] ?? 0} / ${remote['received'] ?? 0}'),
            _row('Queued / uploaded / waiting',
                '${remote['queued'] ?? 0} / ${remote['uploaded'] ?? 0} / ${remote['pending'] ?? 0}'),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _sendTestRelay,
              child: const Text('Send test SOS via relay (SIMULATED)'),
            ),
            if (_testMessage != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(_testMessage!, style: const TextStyle(fontSize: 12)),
              ),
            const SizedBox(height: 8),
            const Text('Last 10 events', style: TextStyle(fontWeight: FontWeight.bold)),
            ..._events(remote),
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

  List<Widget> _groundTruth(PdrService pdr) {
    final m = pdr.errorMeter;
    String metres(double? v) => v == null ? '-' : '${v.toStringAsFixed(1)} m';
    return [
      if (m.active)
        _banner('SIMULATED GPS loss: real GPS is read only to measure the error'),
      _row('Walked since loss (steps x stride)', '${m.walkedM.toStringAsFixed(0)} m'),
      _row('Current error vs real GPS', metres(m.errorM)),
      _row('Max error', metres(m.hasRun ? m.maxErrorM : null)),
      _row('Error / distance',
          m.percent == null ? '-' : '${m.percent!.toStringAsFixed(0)} %'),
      const SizedBox(height: 6),
      Container(
        padding: const EdgeInsets.all(10),
        color: Colors.blueGrey.shade50,
        child: SelectableText(
          'Run summary${m.active ? ' (running, SIMULATED loss)' : ''}: ${m.summary()}\n'
          'Flags: ${_flagLine(pdr.config)}',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
        ),
      ),
    ];
  }

  String _flagLine(PdrConfig c) => c
      .toMap()
      .entries
      .map((e) => '${e.key}=${e.value ? "ON" : "OFF"}')
      .join(' ');

  List<Widget> _flags(PdrService pdr) {
    final c = pdr.config;
    final eng = pdr.engine;
    Widget sw(String title, String key, bool value, String sub) =>
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text('$title: ${value ? "ON" : "OFF"}'),
          subtitle: Text(sub, style: const TextStyle(fontSize: 11)),
          value: value,
          onChanged: (v) => _setFlag(key, v),
        );
    return [
      Row(children: [
        OutlinedButton(onPressed: () => _setAllFlags(true), child: const Text('All ON')),
        const SizedBox(width: 8),
        OutlinedButton(onPressed: () => _setAllFlags(false), child: const Text('All OFF')),
      ]),
      sw('Compass gating', 'compassGating', c.compassGating,
          'Ignore magnetometer samples outside 25-65 uT'),
      sw('Heading offset', 'headingOffset', c.headingOffset,
          'Learn GPS course minus compass while GPS is good'),
      sw('Stride learning', 'strideLearning', c.strideLearning,
          'Learn stride from GPS distance / steps'),
      sw('Microphone context', 'microphoneContext', c.microphoneContext,
          'Vehicle / stationary from YAMNet sound labels'),
      sw('Anchors', 'anchors', c.anchors,
          'Use positions of nearby Guardian phones with good GPS'),
      const Divider(),
      _row(
          'Heading offset learned',
          eng.headingOffsetDeg == null
              ? (eng.headingOffsetInvalidated ? 'invalid (phone moved)' : 'not yet')
              : '${eng.headingOffsetDeg!.toStringAsFixed(1)} deg'),
      _row('Stride in use',
          '${eng.currentStrideM.toStringAsFixed(2)} m${eng.strideCalibrated ? " (learned)" : " (default)"}'),
      _row('Drift fraction (assumption)', eng.driftFraction.toStringAsFixed(2)),
      _row('Compass samples rejected', '${pdr.rejectedMagSamples}'),
    ];
  }

  List<Widget> _contextAndAnchors(PdrService pdr, Map<String, dynamic> remote) {
    final a = pdr.lastAnchor;
    final now = DateTime.now().millisecondsSinceEpoch;
    final local = pdr.motionContext.name;
    final svc = remote['motionContext'];
    return [
      _row('Motion context (app / service)', '$local / ${svc ?? "-"}'),
      _row(
          'Last anchor',
          a == null
              ? 'none'
              : '${formatAge(((now - a.atMs) / 1000).round())}${a.simulated ? " (SIMULATED)" : ""}'),
      if (a != null) ...[
        _row('Anchor age when used', '${a.anchorAgeS} s'),
        _row('Radius before -> after',
            '${a.radiusBeforeM.round()} m -> ${a.radiusAfterM.round()} m'),
        _row('Action', a.snapped ? 'snapped to anchor' : 'weighted'),
      ],
      const SizedBox(height: 6),
      OutlinedButton(
        onPressed: _sendTestAnchor,
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

  List<Widget> _events(Map<String, dynamic> remote) {
    final events = remote['events'];
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
