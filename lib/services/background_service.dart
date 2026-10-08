import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'voice_service.dart';
// TODO: Uncomment these imports once we stabilize these files
// import 'sensor_service.dart';
// import 'emergency_service.dart'; 

class GuardianBackgroundService {
  static const String notificationChannelId = 'guardian_foreground_service';
  static const int notificationId = 888;

  static Future<void> initializeService() async {
    final service = FlutterBackgroundService();

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false, // Wait for explicit permission grants
        isForegroundMode: true,
        notificationChannelId: notificationChannelId,
        initialNotificationTitle: 'Guardian Active',
        initialNotificationContent: 'Shield and monitoring enabled.',
        foregroundServiceNotificationId: notificationId,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: true,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );
  }

  /// Call only after permissions (Mic, Location, Sensors, Notifications) are granted.
  static Future<void> startService() async {
    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    if (!isRunning) {
      await service.startService();
    }
  }

  static Future<void> stopService() async {
    final service = FlutterBackgroundService();
    final isRunning = await service.isRunning();
    if (isRunning) {
      service.invoke('stopService');
    }
  }

  @pragma('vm:entry-point')
  static Future<bool> onIosBackground(ServiceInstance service) async {
    WidgetsFlutterBinding.ensureInitialized();
    DartPluginRegistrant.ensureInitialized();
    return true;
  }

  @pragma('vm:entry-point')
  static void onStart(ServiceInstance service) async {
    DartPluginRegistrant.ensureInitialized();
    WidgetsFlutterBinding.ensureInitialized();

    if (service is AndroidServiceInstance) {
      service.on('setAsForeground').listen((event) {
        service.setAsForegroundService();
      });

      service.on('setAsBackground').listen((event) {
        service.setAsBackgroundService();
      });
    }

    service.on('stopService').listen((event) {
      service.stopSelf();
    });

    // 1. Check for unresolved Persistent Emergency State upon background boot
    try {
      // TODO: EmergencyService.resumePersistedEmergencyIfExists();
      debugPrint("🔄 Background Service: Checking for unresolved emergencies...");
    } catch (e) {
      debugPrint("❌ Background Service: Error checking persistent state: $e");
    }

    // 2. Start Voice Shield
    try {
      await VoiceService.startListening();
      debugPrint("✅ Background Service: Voice monitoring started.");
    } catch (e) {
      debugPrint("❌ Background Service: Error starting voice service: $e");
    }

    // 3. Start Hardware Sensors (Accelerometer/Gyroscope for Fall Detection)
    try {
      // TODO: await SensorService.startMonitoring();
      debugPrint("✅ Background Service: Sensor monitoring initialized.");
    } catch (e) {
      debugPrint("❌ Background Service: Error starting sensor service: $e");
    }

    // Keep service persistent with periodic update
    Timer.periodic(const Duration(seconds: 15), (timer) async {
      if (service is AndroidServiceInstance) {
        if (await service.isForegroundService()) {
          service.setForegroundNotificationInfo(
            title: "Guardian Shield Active",
            content: "Monitoring environment for emergencies...",
          );
        }
      }
    });
  }
}