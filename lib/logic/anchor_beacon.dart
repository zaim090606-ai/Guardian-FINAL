import 'dart:convert';

/// A nearby Guardian phone's good GPS position, offered to an SOS sender so
/// it can correct its dead-reckoned estimate. Carries no identity: only a
/// position, its accuracy, when it was measured and its source.
class AnchorBeacon {
  static const Set<String> validSources = {'gps'};

  /// Marker so a beacon is never mistaken for an SosPacket.
  static const String typeTag = 'anchor_beacon';

  /// Helper phones only offer a beacon from a fix this good and this fresh.
  static const double maxOfferAccuracyM = 30;
  static const int maxOfferAgeMs = 20000;

  final double lat;
  final double lng;
  final double accuracyM;
  final int timestampMs;
  final String source;

  const AnchorBeacon({
    required this.lat,
    required this.lng,
    required this.accuracyM,
    required this.timestampMs,
    this.source = 'gps',
  });

  Map<String, dynamic> toJson() => {
        'type': typeTag,
        'lat': lat,
        'lng': lng,
        'accuracyM': accuracyM,
        'timestamp': timestampMs,
        'source': source,
      };

  static bool looksLikeBeacon(Object? decoded) =>
      decoded is Map && decoded['type'] == typeTag;

  /// Throws [FormatException] when a field is missing or has the wrong type.
  factory AnchorBeacon.fromJson(Map<String, dynamic> json) {
    final lat = json['lat'];
    final lng = json['lng'];
    final acc = json['accuracyM'];
    final ts = json['timestamp'];
    if (json['type'] != typeTag ||
        lat is! num ||
        lng is! num ||
        acc is! num ||
        ts is! num) {
      throw const FormatException('Beacon has missing or mistyped fields');
    }
    final source = json['source'];
    return AnchorBeacon(
      lat: lat.toDouble(),
      lng: lng.toDouble(),
      accuracyM: acc.toDouble(),
      timestampMs: ts.toInt(),
      source: source is String ? source : 'unknown',
    );
  }

  /// Returns null when the beacon is acceptable, otherwise the reason it is not.
  String? validate({
    required int nowMs,
    int maxAgeMs = 60 * 1000,
    int maxFutureSkewMs = 10 * 1000,
  }) {
    if (lat.isNaN || lng.isNaN || lat < -90 || lat > 90) return 'bad latitude';
    if (lng < -180 || lng > 180) return 'bad longitude';
    if (lat == 0 && lng == 0) return 'null island';
    if (!validSources.contains(source)) return 'bad source';
    if (accuracyM.isNaN || accuracyM < 0 || accuracyM > 1000) {
      return 'bad accuracy';
    }
    if (timestampMs > nowMs + maxFutureSkewMs) return 'timestamp in future';
    if (nowMs - timestampMs > maxAgeMs) return 'beacon too old';
    return null;
  }
}

/// Helper-side rule: offer a beacon only from a real, accurate, fresh GPS fix
/// and never while this phone itself is simulating GPS loss.
bool canOfferBeacon({
  required bool hasRealFix,
  required double accuracyM,
  required bool simulatingGpsLoss,
  required int fixAgeMs,
}) =>
    hasRealFix &&
    !simulatingGpsLoss &&
    accuracyM <= AnchorBeacon.maxOfferAccuracyM &&
    fixAgeMs >= 0 &&
    fixAgeMs < AnchorBeacon.maxOfferAgeMs;

/// Parses and validates a raw payload; null when it is not a usable beacon.
AnchorBeacon? parseBeacon(String raw, int nowMs) {
  try {
    final decoded = jsonDecode(raw);
    if (!AnchorBeacon.looksLikeBeacon(decoded)) return null;
    final b = AnchorBeacon.fromJson(Map<String, dynamic>.from(decoded as Map));
    return b.validate(nowMs: nowMs) == null ? b : null;
  } catch (_) {
    return null;
  }
}
