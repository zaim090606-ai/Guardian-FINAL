/// SOS payload exchanged over the mesh and used to build the Firestore document.
class SosPacket {
  static const Set<String> validSources = {'gps', 'estimated', 'unknown'};
  static final RegExp _idPattern = RegExp(r'^[A-Za-z0-9_-]{1,128}$');

  final String id;
  final double lat;
  final double lng;
  final String source;
  final double uncertaintyM;
  final int timestampMs;
  final int hop;
  final String message;

  const SosPacket({
    required this.id,
    required this.lat,
    required this.lng,
    required this.source,
    required this.uncertaintyM,
    required this.timestampMs,
    this.hop = 0,
    this.message = '',
  });

  SosPacket nextHop() => SosPacket(
        id: id,
        lat: lat,
        lng: lng,
        source: source,
        uncertaintyM: uncertaintyM,
        timestampMs: timestampMs,
        hop: hop + 1,
        message: message,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'lat': lat,
        'lng': lng,
        'source': source,
        'uncertaintyM': uncertaintyM,
        'timestamp': timestampMs,
        'hop': hop,
        'message': message,
      };

  /// Throws [FormatException] when a field is missing or has the wrong type.
  factory SosPacket.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final lat = json['lat'];
    final lng = json['lng'];
    final ts = json['timestamp'];
    if (id is! String || lat is! num || lng is! num || ts is! num) {
      throw const FormatException('SOS packet has missing or mistyped fields');
    }
    final source = json['source'];
    final unc = json['uncertaintyM'];
    final hop = json['hop'];
    final message = json['message'];
    return SosPacket(
      id: id,
      lat: lat.toDouble(),
      lng: lng.toDouble(),
      source: source is String ? source : 'unknown',
      uncertaintyM: unc is num ? unc.toDouble() : 0.0,
      timestampMs: ts.toInt(),
      hop: hop is num ? hop.toInt() : 0,
      message: message is String ? message : '',
    );
  }

  /// Returns null when the packet is acceptable, otherwise the reason it is not.
  String? validate({
    required int nowMs,
    int maxHops = 5,
    int maxAgeMs = 24 * 3600 * 1000,
    int maxFutureSkewMs = 5 * 60 * 1000,
  }) {
    if (!_idPattern.hasMatch(id)) return 'bad id';
    if (lat.isNaN || lng.isNaN || lat < -90 || lat > 90) return 'bad latitude';
    if (lng < -180 || lng > 180) return 'bad longitude';
    if (!validSources.contains(source)) return 'bad source';
    if (uncertaintyM.isNaN || uncertaintyM < 0) return 'bad uncertainty';
    if (hop < 0 || hop > maxHops) return 'hop limit exceeded';
    if (timestampMs > nowMs + maxFutureSkewMs) return 'timestamp in future';
    if (nowMs - timestampMs > maxAgeMs) return 'packet too old';
    if (message.length > 1000) return 'message too long';
    return null;
  }
}
