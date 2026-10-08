import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';

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
