import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sensors_plus/sensors_plus.dart';

import 'firebase_options.dart';
import 'navbar/navbar.dart';
import 'screens/firstscreen.dart';
import 'services/emergency_service.dart';
import 'services/voice_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  final prefs = await SharedPreferences.getInstance();
  final bool isSetupComplete = prefs.getBool('is_setup_complete') ?? false;

  // 1. Boot Flutter UI framework first
  runApp(MyApp(isSetupComplete: isSetupComplete));

  // 2. Request runtime permissions safely after UI mount
  final micPermissionGranted = await requestEmergencyPermissions();

  // 3. Configure and start service ONLY after permissions are verified
  if (micPermissionGranted) {
    await initializeBackgroundService(enableMicrophone: true);
    final service = FlutterBackgroundService();
    final alreadyRunning = await service.isRunning();
    if (!alreadyRunning) {
      await service.startService();
    }
  } else {
    debugPrint(
        "⚠️ Initializing background service without microphone monitoring...");
    await initializeBackgroundService(enableMicrophone: false);
    final service = FlutterBackgroundService();
    final alreadyRunning = await service.isRunning();
    if (!alreadyRunning) {
      await service.startService();
    }
  }
}

/// Requests SMS, Phone, Location, Microphone, Notification, and Battery Optimization permissions.
Future<bool> requestEmergencyPermissions() async {
  Map<Permission, PermissionStatus> statuses = await [
    Permission.sms,
    Permission.phone,
    Permission.locationWhenInUse,
    Permission.microphone,
    Permission.notification,
  ].request();

  if (statuses[Permission.sms]?.isGranted == true &&
      statuses[Permission.phone]?.isGranted == true) {
    debugPrint("✅ Background SMS and Telephony permissions granted!");
  } else {
    debugPrint("⚠️ Background SMS/Telephony permission missing.");
  }

  if (statuses[Permission.locationWhenInUse]?.isGranted == true) {
    PermissionStatus bgStatus = await Permission.locationAlways.request();
    if (bgStatus.isGranted) {
      debugPrint("✅ Background Location granted!");
    } else {
      debugPrint("⚠️ Background Location permission denied or restricted.");
    }
  }

  if (await Permission.ignoreBatteryOptimizations.isDenied) {
    debugPrint("⚠️ Requesting battery optimization exemption...");
    await Permission.ignoreBatteryOptimizations.request();
  } else {
    debugPrint("✅ Battery optimization exempted!");
  }

  final micGranted = statuses[Permission.microphone]?.isGranted == true;
  if (!micGranted) {
    debugPrint(
        "⚠️ Microphone permission missing — voice background trigger disabled.");
  }
  return micGranted;
}

/// Creates mandatory notification channel and configures background service dynamically.
Future<void> initializeBackgroundService(
    {required bool enableMicrophone}) async {
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'guardian_safety_channel',
    'Guardian Safety Service',
    description: 'Monitoring motion, rotation & voice keywords in background.',
    importance: Importance.low,
  );

  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();

  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  final List<AndroidForegroundType> activeForegroundTypes = [
    AndroidForegroundType.location,
    AndroidForegroundType.dataSync,
  ];

  if (enableMicrophone) {
    activeForegroundTypes.add(AndroidForegroundType.microphone);
  }

  final service = FlutterBackgroundService();

  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStartService,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'guardian_safety_channel',
      initialNotificationTitle: 'Guardian Safety Active',
      initialNotificationContent:
          'Monitoring motion, rotation & voice keywords in background.',
      foregroundServiceNotificationId: 888,
      foregroundServiceTypes: activeForegroundTypes,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStartService,
      onBackground: (service) => true,
    ),
  );
}

@pragma('vm:entry-point')
void onStartService(ServiceInstance service) async {
  WidgetsFlutterBinding.ensureInitialized();

  // 1. Initialize background voice monitoring for lock-screen trigger
  try {
    await VoiceService.startListening(
      onSosTriggeredCallback: () async {
        await EmergencyService.triggerEmergencyDispatch(
          force: 0.0,
          level: "Background Voice Shield Trigger",
        );
      },
    );
  } catch (e) {
    debugPrint("❌ Error starting voice service in background: $e");
  }

  double latestRotationRate = 0.0;

  // 2. Continuous Gyroscope Listener
  gyroscopeEventStream().listen((GyroscopeEvent event) {
    latestRotationRate =
        sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
  });

  // 3. Continuous Accelerometer Listener
  accelerometerEventStream().listen((AccelerometerEvent event) async {
    double impactForce =
        sqrt(event.x * event.x + event.y * event.y + event.z * event.z);

    if (impactForce > 25.0 && latestRotationRate > 5.0) {
      debugPrint(
          "Background Service: Sudden rotational impact detected! Dispatching emergency...");

      EmergencyService.triggerEmergencyDispatch(
        force: impactForce,
        level: "Severe Rotational Impact",
      );
    }
  });

  service.on('stop_service').listen((event) {
    service.stopSelf();
  });
}

class MyApp extends StatelessWidget {
  final bool isSetupComplete;
  const MyApp({super.key, required this.isSetupComplete});

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Guardian',
      theme: ThemeData(
        brightness: Brightness.light,
        scaffoldBackgroundColor: const Color(0xFFF9F9F9),
        primaryColor: Colors.black,
        colorScheme: const ColorScheme.light(
          primary: Colors.black,
          secondary: Color(0xFF222222),
          surface: Colors.white,
          onPrimary: Colors.white,
          onSurface: Colors.black,
        ),
      ),
      home: (isSetupComplete || user != null)
          ? const MainBottomNavBar()
          : const Firstscreen(),
    );
  }
}