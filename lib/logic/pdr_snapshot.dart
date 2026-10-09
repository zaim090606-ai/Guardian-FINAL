import 'anchor_beacon.dart';
import 'pdr_config.dart';
import 'pdr_engine.dart';
import 'sos_guard.dart';

/// Everything the UI isolate shows about PDR. The service isolate owns the
/// sensors, the GPS stream and the engine; it publishes this map every 2 s.
class PdrSnapshot {
  /// A snapshot older than this means the service (and PDR) is not running.
  static const int maxAgeMs = 8000;

  final int generatedAtMs;
  final bool simulate;
  final Map<String, bool> config;
  final Map<String, dynamic>? fix;
  final int steps;
  final double? heading;
  final double? lastGpsLat, lastGpsLng, lastGpsAccuracy;
  final int? lastGpsMs;
  final int rejectedMagSamples;
  final int rejectedWindows;
  final double? offsetDeg;
  final bool offsetInvalidated;
  final double strideM;
  final bool strideCalibrated;
  final double driftFraction;
  final String motionContext;
  final Map<String, dynamic> meter;
  final Map<String, dynamic>? lastAnchor;

  const PdrSnapshot({
    required this.generatedAtMs,
    required this.simulate,
    required this.config,
    required this.fix,
    required this.steps,
    required this.heading,
    required this.lastGpsLat,
    required this.lastGpsLng,
    required this.lastGpsAccuracy,
    required this.lastGpsMs,
    required this.rejectedMagSamples,
    required this.rejectedWindows,
    required this.offsetDeg,
    required this.offsetInvalidated,
    required this.strideM,
    required this.strideCalibrated,
    required this.driftFraction,
    required this.motionContext,
    required this.meter,
    required this.lastAnchor,
  });

  Map<String, dynamic> toJson() => {
        'at': generatedAtMs,
        'sim': simulate,
        'config': config,
        'fix': fix,
        'steps': steps,
        'heading': heading,
        'gpsLat': lastGpsLat,
        'gpsLng': lastGpsLng,
        'gpsAcc': lastGpsAccuracy,
        'gpsMs': lastGpsMs,
        'magRejected': rejectedMagSamples,
        'winRejected': rejectedWindows,
        'offset': offsetDeg,
        'offsetInvalid': offsetInvalidated,
        'stride': strideM,
        'strideCal': strideCalibrated,
        'drift': driftFraction,
        'context': motionContext,
        'meter': meter,
        'anchor': lastAnchor,
      };

  static PdrSnapshot? fromJson(Object? raw) {
    if (raw is! Map) return null;
    try {
      double? d(Object? v) => v is num ? v.toDouble() : null;
      final cfg = <String, bool>{};
      final c = raw['config'];
      if (c is Map) {
        c.forEach((k, v) => cfg['$k'] = v == true);
      }
      return PdrSnapshot(
        generatedAtMs: (raw['at'] as num).toInt(),
        simulate: raw['sim'] == true,
        config: cfg,
        fix: raw['fix'] is Map ? Map<String, dynamic>.from(raw['fix'] as Map) : null,
        steps: (raw['steps'] as num?)?.toInt() ?? 0,
        heading: d(raw['heading']),
        lastGpsLat: d(raw['gpsLat']),
        lastGpsLng: d(raw['gpsLng']),
        lastGpsAccuracy: d(raw['gpsAcc']),
        lastGpsMs: (raw['gpsMs'] as num?)?.toInt(),
        rejectedMagSamples: (raw['magRejected'] as num?)?.toInt() ?? 0,
        rejectedWindows: (raw['winRejected'] as num?)?.toInt() ?? 0,
        offsetDeg: d(raw['offset']),
        offsetInvalidated: raw['offsetInvalid'] == true,
        strideM: d(raw['stride']) ?? 0.75,
        strideCalibrated: raw['strideCal'] == true,
        driftFraction: d(raw['drift']) ?? 0.15,
        motionContext: '${raw['context'] ?? 'unknown'}',
        meter: raw['meter'] is Map
            ? Map<String, dynamic>.from(raw['meter'] as Map)
            : const {},
        lastAnchor: raw['anchor'] is Map
            ? Map<String, dynamic>.from(raw['anchor'] as Map)
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  bool isFresh(int nowMs) => nowMs - generatedAtMs <= maxAgeMs;

  /// The service's current fix, aged to [nowMs]; null when the snapshot is
  /// stale or has no fix yet. Estimated fixes keep the time of the last GPS
  /// fix, so the age shown grows even between snapshots.
  LocationFix? locationFix(int nowMs) {
    final f = fix;
    if (f == null || !isFresh(nowMs)) return null;
    try {
      return LocationFix(
        lat: (f['lat'] as num).toDouble(),
        lng: (f['lng'] as num).toDouble(),
        source: '${f['source']}',
        uncertaintyM: (f['unc'] as num).toDouble(),
        timeMs: (f['timeMs'] as num).toInt(),
        generatedAtMs: nowMs,
        context: '${f['context'] ?? ''}',
        anchorUsed: f['anchorUsed'] == true,
        anchorAgeS: (f['anchorAgeS'] as num?)?.toInt(),
        anchorRadiusM: (f['anchorRadiusM'] as num?)?.toDouble(),
      );
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? fixToJson(LocationFix? f) => f == null
      ? null
      : {
          'lat': f.lat,
          'lng': f.lng,
          'source': f.source,
          'unc': f.uncertaintyM,
          'timeMs': f.timeMs,
          'context': f.context,
          'anchorUsed': f.anchorUsed,
          'anchorAgeS': f.anchorAgeS,
          'anchorRadiusM': f.anchorRadiusM,
        };

  /// Helper side (UI isolate, which runs the relay): a beacon from the
  /// service's last real GPS fix, or null unless it is accurate and fresh and
  /// GPS loss is not being simulated.
  AnchorBeacon? beaconForSharing(int nowMs) {
    final lat = lastGpsLat, lng = lastGpsLng, acc = lastGpsAccuracy, ms = lastGpsMs;
    if (!isFresh(nowMs) || lat == null || lng == null || acc == null || ms == null) {
      return null;
    }
    if (!canOfferBeacon(
        hasRealFix: true,
        accuracyM: acc,
        simulatingGpsLoss: simulate,
        fixAgeMs: nowMs - ms)) {
      return null;
    }
    return AnchorBeacon(
        lat: lat,
        lng: lng,
        accuracyM: acc,
        timestampMs: ms,
        ageS: (nowMs - ms) / 1000.0);
  }
}

/// PdrConfig and the GPS-loss simulation switch, persisted so the service
/// isolate (the single PDR owner) keeps them across restarts.
class PdrSettings {
  static const String configKey = 'pdr_config';
  static const String simKey = 'pdr_simulate';
  final KeyValueStore store;
  PdrSettings(this.store);

  Future<void> loadInto(PdrConfig config) async {
    try {
      final raw = await store.read(configKey);
      if (raw == null || raw.isEmpty) return;
      final m = <String, bool>{};
      for (final part in raw.split(',')) {
        final kv = part.split('=');
        if (kv.length == 2) m[kv[0]] = kv[1] == '1';
      }
      // Keys missing from an older save stay at their default (on).
      final merged = {...PdrConfig().toMap(), ...m};
      config.applyMap(merged);
    } catch (_) {}
  }

  Future<void> saveConfig(PdrConfig config) => store.write(
      configKey,
      config.toMap().entries.map((e) => '${e.key}=${e.value ? 1 : 0}').join(','));

  Future<void> saveSimulate(bool on) => store.write(simKey, on ? '1' : '0');

  Future<bool> readSimulate() async => (await store.read(simKey)) == '1';

  /// Called when the service starts: a restart never keeps GPS loss simulated.
  Future<void> resetSimulateOnStart() => saveSimulate(false);
}
