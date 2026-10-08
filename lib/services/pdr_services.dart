import 'dart:async';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:sensors_plus/sensors_plus.dart';

class PdrService {
  static final PdrService _instance = PdrService._internal();
  factory PdrService() => _instance;
  PdrService._internal();

  // Anchor position
  double _currentLat = 0.0;
  double _currentLng = 0.0;
  
  // Dead reckoning telemetry
  double _currentHeading = 0.0; // In degrees (0 - 360)
  int _stepCount = 0;
  bool _isTracking = false;

  // Sensor Subscriptions
  StreamSubscription<UserAccelerometerEvent>? _accelSub;
  StreamSubscription<MagnetometerEvent>? _magSub;

  // Step detection variables
  double _lastAccelMag = 0.0;
  DateTime _lastStepTime = DateTime.now();
  static const double _stepThreshold = 2.5; // Peak threshold for step detection
  static const double _averageStrideMeters = 0.75; // Standard step length

  /// Set the initial GPS anchor position before underground transition
  void setAnchorPosition(Position position) {
    _currentLat = position.latitude;
    _currentLng = position.longitude;
    _stepCount = 0;
    debugPrint("📍 PDR Anchor set: Lat $_currentLat, Lng $_currentLng");
  }

  /// Start Dead Reckoning sensor tracking
  void startTracking() {
    if (_isTracking) return;
    _isTracking = true;

    // 1. Listen to User Accelerometer for Step Detection
    _accelSub = userAccelerometerEvents.listen((UserAccelerometerEvent event) {
      double mag = sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
      
      // Peak detection algorithm with 300ms debounce
      if (mag > _stepThreshold && _lastAccelMag <= _stepThreshold) {
        DateTime now = DateTime.now();
        if (now.difference(_lastStepTime).inMilliseconds > 300) {
          _lastStepTime = now;
          _stepCount++;
          _updateEstimatedPosition(_averageStrideMeters, _currentHeading);
        }
      }
      _lastAccelMag = mag;
    });

    // 2. Listen to Magnetometer for Compass Heading
    _magSub = magnetometerEvents.listen((MagnetometerEvent event) {
      double headingRad = atan2(event.y, event.x);
      double headingDeg = headingRad * (180 / pi);
      if (headingDeg < 0) headingDeg += 360;
      _currentHeading = headingDeg;
    });

    debugPrint("🚶 Dead Reckoning Engine started.");
  }

  /// Update estimated coordinates based on stride length and bearing angle
  void _updateEstimatedPosition(double distanceMeters, double headingDegrees) {
    if (_currentLat == 0.0 && _currentLng == 0.0) return;

    double headingRad = headingDegrees * (pi / 180.0);
    const double metersPerDegreeLat = 111111.0;

    // Displacement calculation
    double dLat = (distanceMeters * cos(headingRad)) / metersPerDegreeLat;
    double dLng = (distanceMeters * sin(headingRad)) /
        (metersPerDegreeLat * cos(_currentLat * (pi / 180.0)));

    _currentLat += dLat;
    _currentLng += dLng;

    debugPrint(
        "👣 PDR Step #$_stepCount | Estimated Location: Lat $_currentLat, Lng $_currentLng");
  }

  /// Returns estimated position if GPS is unavailable
  Map<String, double> getEstimatedPosition() {
    return {
      'latitude': _currentLat,
      'longitude': _currentLng,
      'heading': _currentHeading,
      'steps': _stepCount.toDouble(),
    };
  }

  /// Stop tracking & release sensor listeners
  void stopTracking() {
    _accelSub?.cancel();
    _magSub?.cancel();
    _isTracking = false;
    debugPrint("🛑 PDR Engine stopped.");
  }
}