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

/// A peer fix older than this is not used.
const int anchorMaxAgeMs = 60 * 1000;

/// Allowance for the unknown distance between the two phones (ASSUMPTION).
const double anchorSeparationM = 25;

/// Walking speed used to widen the sigma of an older peer fix.
const double anchorAgeSpeedMps = 1.5;

/// An anchor this far from a confident estimate is treated as wrong.
const double anchorMaxJumpM = 150;
const double anchorConfidentSigmaM = 30;

/// Sigma of a peer fix: sqrt(accuracy^2 + 25^2 + (1.5 m/s * age)^2).
double anchorSigmaM(double accuracyM, {double ageS = 0}) {
  final drift = anchorAgeSpeedMps * ageS;
  return sqrt(accuracyM * accuracyM +
      anchorSeparationM * anchorSeparationM +
      drift * drift);
}

/// Fuses the estimate with a peer position treated as a measurement with
/// sigma = sqrt(peer accuracy^2 + 25^2) (plus age drift). If the estimate is further from the
/// anchor than its own uncertainty, the estimate is judged wrong and snaps to
/// the anchor; otherwise both are combined by inverse-variance weighting.
AnchorFusion fuseAnchor({
  required double estLat,
  required double estLng,
  required double estSigmaM,
  required double anchorLat,
  required double anchorLng,
  required double anchorAccuracyM,
  double anchorAgeS = 0,
}) {
  final sa = anchorSigmaM(anchorAccuracyM, ageS: anchorAgeS);
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
