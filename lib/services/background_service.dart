import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'voice_service.dart';
 
class GuardianBackgroundService {
  static const String notificationChannelId = 'guardian_foreground_service';
  static const int notificationId = 888;
 
  static Future<void> initializeService() async {
    final service = FlutterBackgroundService();
 
    // Configure Service (flutter_background_service creates the notification channel automatically)
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: onStart,
        autoStart: false, // do NOT auto-start — mic-type foreground services
                          // must not start until RECORD_AUDIO is granted.
                          // Call GuardianBackgroundService.startService()
                          // manually once all required permissions are confirmed.
        isForegroundMode: true,
        notificationChannelId: notificationChannelId,
        initialNotificationTitle: 'Guardian Active',
        initialNotificationContent: 'Voice shield and safety monitoring enabled.',
        foregroundServiceNotificationId: notificationId,
      ),
      iosConfiguration: IosConfiguration(
        autoStart: true,
        onForeground: onStart,
        onBackground: onIosBackground,
      ),
    );
  }
 
  /// Call this only after mic / location / notification permissions
  /// have been requested and confirmed granted. Safe to call multiple
  /// times — it checks if the service is already running first.
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
 
    // Start voice trigger monitoring inside background process
    try {
      await VoiceService.startListening();
    } catch (e) {
      debugPrint("❌ Error starting voice service in background: $e");
    }
 
    // Keep service persistent with periodic update
    Timer.periodic(const Duration(seconds: 15), (timer) async {
      if (service is AndroidServiceInstance) {
        if (await service.isForegroundService()) {
          service.setForegroundNotificationInfo(
            title: "Guardian Voice Shield Active",
            content: "Monitoring for emergency voice triggers...",
          );
        }
      }
    });
  }
}
 