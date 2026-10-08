import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'firebase_options.dart';
import 'navbar/navbar.dart';
import 'screens/firstscreen.dart';
import 'services/emergency_service.dart';
import 'services/voice_service.dart';
import 'services/mesh_receiver_service.dart';

Future<void> testFirebaseConnection() async {
  debugPrint("🧪 Starting Firebase Connection Test...");

  try {
    // 1. Check Auth Status
    User? currentUser = FirebaseAuth.instance.currentUser;
    debugPrint("👤 Auth Status: ${currentUser != null ? 'Logged in as ${currentUser.uid}' : 'Anonymous / Not logged in'}");

    // 2. Test Firestore Write
    DocumentReference testDoc = FirebaseFirestore.instance
        .collection('test_connection')
        .doc();

    await testDoc.set({
      'test_time': FieldValue.serverTimestamp(),
      'status': 'Firebase is connected successfully!',
      'device_platform': defaultTargetPlatform.toString(),
    });

    debugPrint("✅ FIRESTORE WRITE SUCCESSFUL! Doc ID: ${testDoc.id}");

    // 3. Test Firestore Read
    DocumentSnapshot snapshot = await testDoc.get();
    if (snapshot.exists) {
      debugPrint("📖 FIRESTORE READ SUCCESSFUL! Data: ${snapshot.data()}");
    } else {
      debugPrint("❌ FIRESTORE READ FAILED: Document does not exist.");
    }

    // 4. Verify tracking link generation structure
    String testTrackingLink = "https://your-app-website.com/alert/${testDoc.id}";
    debugPrint("🔗 Generated Test Tracking Link: $testTrackingLink");

  } catch (e) {
    debugPrint("❌ FIREBASE TEST FAILED With Error: $e");
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Initialize Firebase Anonymous Auth to clear Firestore PERMISSION_DENIED
  try {
    await FirebaseAuth.instance.signInAnonymously();
    debugPrint("✅ Firebase Anonymous Auth initialized");
  } catch (e) {
    debugPrint("⚠️ Firebase Anonymous Auth failed: $e");
  }

  // Enable Firestore Offline Persistence for Mesh Relay Syncing
  FirebaseFirestore.instance.settings = const Settings(
    persistenceEnabled: true,
    cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
  );

  final prefs = await SharedPreferences.getInstance();
  final bool isSetupComplete = prefs.getBool('is_setup_complete') ?? false;

  // 1. Boot Flutter UI framework first
  runApp(
    ProviderScope(
      child: MyApp(isSetupComplete: isSetupComplete),
    ),
  );

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

  // 4. Start listening for incoming Mesh Relay emergency packets
  await MeshReceiverService().startEmergencyListener();
}

/// Requests SMS, Phone, Location, Microphone, Notification, and Battery Optimization permissions.
Future<bool> requestEmergencyPermissions() async {
  Map<Permission, PermissionStatus> statuses = await [
    Permission.sms,
    Permission.phone,
    Permission.locationWhenInUse,
    Permission.microphone,
    Permission.notification,
    Permission.bluetoothScan,
    Permission.bluetoothAdvertise,
    Permission.bluetoothConnect,
    Permission.nearbyWifiDevices,
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
    description: 'Monitoring motion, rotation, voice keywords & mesh relay in background.',
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

  debugPrint("[GUARDIAN_LOG] Background Service: Initializing Firebase...");
  // Initialize Firebase inside the background isolate
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  // Initialize Firebase Anonymous Auth in background isolate to clear Firestore PERMISSION_DENIED
  try {
    await FirebaseAuth.instance.signInAnonymously();
    debugPrint("[GUARDIAN_LOG] Background Service: Firebase Anonymous Auth initialized");
  } catch (e) {
    debugPrint("[GUARDIAN_LOG] ⚠️ Background Firebase Auth failed: $e");
  }

  debugPrint("[GUARDIAN_LOG] Background Service: Firebase initialized successfully");

  // 1. Initialize background voice monitoring for lock-screen trigger
  try {
    debugPrint("[GUARDIAN_LOG] Background Service: Starting Voice Shield...");
    await VoiceService.startListening(
      onSosTriggeredCallback: () async {
        debugPrint("[GUARDIAN_LOG] Voice Shield: SOS keyword detected! Triggering emergency dispatch...");
        await EmergencyService.triggerEmergencyDispatch(
          force: 0.0,
          level: "Background Voice Shield Trigger",
        );
      },
    );
    debugPrint("[GUARDIAN_LOG] Background Service: Voice Shield active");
  } catch (e) {
    debugPrint("[GUARDIAN_LOG] ❌ Error starting voice service in background: $e");
  }

  // 2. Start Mesh Relay Listener in the background isolate to catch peer SOS signals
  try {
    debugPrint("[GUARDIAN_LOG] Background Service: Starting Mesh Relay Listener...");
    await MeshReceiverService().startEmergencyListener();
    debugPrint("[GUARDIAN_LOG] Background Service: Mesh Relay Listener active");
  } catch (e) {
    debugPrint("[GUARDIAN_LOG] ❌ Error starting mesh receiver in background: $e");
  }

  double latestRotationRate = 0.0;

  // 3. Continuous Gyroscope Listener
  gyroscopeEventStream().listen((GyroscopeEvent event) {
    latestRotationRate =
        sqrt(event.x * event.x + event.y * event.y + event.z * event.z);
  });

  debugPrint("[GUARDIAN_LOG] Background Service: Sensor monitoring started (Accelerometer + Gyroscope)");

  // 4. Continuous Accelerometer Listener
  accelerometerEventStream().listen((AccelerometerEvent event) async {
    double impactForce =
        sqrt(event.x * event.x + event.y * event.y + event.z * event.z);

    if (impactForce > 25.0 && latestRotationRate > 5.0) {
      debugPrint(
          "[GUARDIAN_LOG] Sensor: Sudden rotational impact detected! Force=$impactForce, Rotation=$latestRotationRate");

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