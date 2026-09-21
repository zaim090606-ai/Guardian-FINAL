import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

class LocationService {
  /// Request GPS permissions dynamically from the user
  static Future<bool> requestPermissions() async {
    PermissionStatus status = await Permission.location.request();
    if (status.isGranted) {
      PermissionStatus bgStatus = await Permission.locationAlways.request();
      return bgStatus.isGranted || status.isGranted;
    }
    return false;
  }

  /// Get current GPS Position and return a Google Maps link payload
  static Future<Map<String, dynamic>> getCurrentLocationPayload() async {
    try {
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return {
          'latitude': 0.0,
          'longitude': 0.0,
          'mapsUrl': 'Location Services Disabled',
        };
      }

      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          return {
            'latitude': 0.0,
            'longitude': 0.0,
            'mapsUrl': 'Location Permission Denied',
          };
        }
      }

      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      String mapsUrl =
          "https://maps.google.com/?q=${position.latitude},${position.longitude}";

      return {
        'latitude': position.latitude,
        'longitude': position.longitude,
        'mapsUrl': mapsUrl,
      };
    } catch (e) {
      return {
        'latitude': 0.0,
        'longitude': 0.0,
        'mapsUrl': 'Error getting location: $e',
      };
    }
  }
}
