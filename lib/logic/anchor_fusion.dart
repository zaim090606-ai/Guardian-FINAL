import 'dart:math';

import 'pdr_engine.dart' show distanceM;

/// Outcome of combining a dead-reckoned estimate with a peer position.
class AnchorFusion {
  final double lat;
  final double lng;

  /// Radius (1 sigma, metres) of the combined position.
  final double sigmaM;

  /// True when the estimate was replaced by the anchor.
  final bool snapped;
  const AnchorFusion(this.lat, this.lng, this.sigmaM, this.snapped);
}

/// A peer fix older than this is not used (moving landmarks go stale fast).
const int anchorMaxAgeMs = 30 * 1000;

/// Minimum sigma for a peer fix: its GPS error plus the unknown distance
/// between the two phones.
const double anchorMinSigmaM = 20;

/// Fuses the estimate with a peer position treated as a measurement with
/// sigma = max(peer accuracy, 20 m). If the estimate is further from the
/// anchor than its own uncertainty, the estimate is judged wrong and snaps to
/// the anchor; otherwise both are combined by inverse-variance weighting.
AnchorFusion fuseAnchor({
  required double estLat,
  required double estLng,
  required double estSigmaM,
  required double anchorLat,
  required double anchorLng,
  required double anchorAccuracyM,
}) {
  final sa = max(anchorAccuracyM, anchorMinSigmaM);
  final se = max(estSigmaM, 1.0);
  final d = distanceM(estLat, estLng, anchorLat, anchorLng);
  if (d > se) return AnchorFusion(anchorLat, anchorLng, sa, true);
  final we = 1 / (se * se), wa = 1 / (sa * sa);
  final w = wa / (we + wa);
  return AnchorFusion(
    estLat + (anchorLat - estLat) * w,
    estLng + (anchorLng - estLng) * w,
    sqrt(1 / (we + wa)),
    false,
  );
}
