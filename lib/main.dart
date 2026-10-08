import 'dart:async';
import 'dart:math';
import 'dart:ui';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_options.dart';
import 'navbar/navbar.dart';
import 'screens/firstscreen.dart';
import 'services/diagnostics_hub.dart';
import 'services/emergency_service.dart';
import 'services/mesh_receiver_service.dart';
import 'services/pdr_services.dart';
import 'services/relay_service.dart';
import 'services/sos_countdown_service.dart';
import 'services/voice_service.dart';

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    FirebaseFirestore.instance.settings = const Settings(
      persistenceEnabled: true,
      cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
    );
    await FirebaseAuth.instance.signInAnonymously();
  } catch (e) {
    // The app still works offline (SMS, mesh, local detection) without Firebase.
    debugPrint('Firebase setup incomplete: $e');
  }

  final prefs = await SharedPreferences.getInstance();
  final bool isSetupComplete = prefs.getBool('is_setup_complete') ?? false;

  runApp(
    ProviderScope(
      child: MyApp(isSetupComplete: isSetupComplete),
    ),
  );

  unawaited(_startGuardian());
}

/// Runs after the first frame: permissions, background service, and the
/// UI-side listeners.
Future<void> _startGuardian() async {
  try {
    final granted = await requestEmergencyPermissions();
    await _initNotifications();

    await initializeBackgroundService(
      enableMicrophone: granted.microphone,
      enableLocation: granted.location,
    );
    final service = FlutterBackgroundService();
    if (!await service.isRunning()) await service.startService();

    // UI side: mirror the service state, allow cancelling a countdown, and
    // run PDR here too so an SOS from the button also has dead reckoning.
    DiagnosticsHub.listen();
    SosCountdownService.attachUi(navigatorKey);
    await VoiceService.startListening();
    await PdrService().start();
  } catch (e) {
    debugPrint('Guardian start-up error: $e');
  }
}

Future<void> _initNotifications() async {
  final plugin = FlutterLocalNotificationsPlugin();
  await plugin.initialize(
    settings: const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    ),
    onDidReceiveNotificationResponse: (NotificationResponse r) {
      if (r.actionId == SosCountdownService.cancelAction) {
        FlutterBackgroundService().invoke(SosCountdownService.cancelAction);
      }
    },
  );
}

class GrantedPermissions {
  final bool microphone;
  final bool location;
  const GrantedPermissions({required this.microphone, required this.location});
}

/// Requests every runtime permission the app can use. Missing ones switch the
/// matching feature off; nothing here is required for the app to start.
Future<GrantedPermissions> requestEmergencyPermissions() async {
  final statuses = await [
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

  final location = statuses[Permission.locationWhenInUse]?.isGranted == true;
  if (location) {
    final bg = await Permission.locationAlways.request();
    if (!bg.isGranted) debugPrint('Background location not granted.');
  }

  if (await Permission.ignoreBatteryOptimizations.isDenied) {
    await Permission.ignoreBatteryOptimizations.request();
  }

  final mic = statuses[Permission.microphone]?.isGranted == true;
  if (!mic) debugPrint('Microphone permission missing: audio triggers off.');
  if (statuses[Permission.sms]?.isGranted != true) {
    debugPrint('SMS permission missing: SMS channel will be skipped.');
  }
  return GrantedPermissions(microphone: mic, location: location);
}

/// Creates the notification channel and configures the foreground service.
/// Foreground-service types are limited to what was actually granted, since
/// Android 14 rejects a service that declares a type without its permission.
Future<void> initializeBackgroundService({
  required bool enableMicrophone,
  required bool enableLocation,
}) async {
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'guardian_safety_channel',
    'Guardian Safety Service',
    description: 'Monitoring motion, voice, sounds and mesh relay in the background.',
    importance: Importance.low,
  );

  await FlutterLocalNotificationsPlugin()
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);

  final types = <AndroidForegroundType>[
    AndroidForegroundType.dataSync,
    if (enableLocation) AndroidForegroundType.location,
    if (enableMicrophone) AndroidForegroundType.microphone,
  ];

  await FlutterBackgroundService().configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStartService,
      autoStart: false,
      isForegroundMode: true,
      notificationChannelId: 'guardian_safety_channel',
      initialNotificationTitle: 'Guardian Safety Active',
      initialNotificationContent: 'Monitoring for emergencies.',
      foregroundServiceNotificationId: 888,
      foregroundServiceTypes: types,
    ),
    iosConfiguration: IosConfiguration(
      autoStart: true,
      onForeground: onStartService,
      onBackground: (service) => true,
    ),
  );
}

/// Entry point of the foreground-service isolate. Everything that must keep
/// working with the screen off is started here.
@pragma('vm:entry-point')
void onStartService(ServiceInstance service) async {
  DartPluginRegistrant.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
    await FirebaseAuth.instance.signInAnonymously();
  } catch (e) {
    debugPrint('Service: Firebase unavailable, offline paths only: $e');
  }

  // Commands from the UI isolate.
  DiagnosticsHub.instance.startPublishing(service);
  SosCountdownService.attachService(service);
  service.on('voice_enabled').listen((event) {
    VoiceService.toggleVoiceMonitoring(event?['enabled'] == true, fromService: true);
  });
  service.on('sim_gps_loss').listen((event) {
    PdrService().simulateGpsLoss = event?['enabled'] == true;
  });
  service.on('send_test_relay').listen((event) async {
    final fix = PdrService().currentFix();
    await RelayService().sendTestPacket(lat: fix?.lat ?? 0, lng: fix?.lng ?? 0);
  });
  service.on('stop_service').listen((event) => service.stopSelf());

  // B. Dead reckoning (keeps running while this service is alive).
  await PdrService().start();

  // D. Audio triggers (keywords + sound classes), with cancel countdown.
  VoiceService.onTranscript = (t) => service.invoke('transcript', {'text': t});
  try {
    await VoiceService.startListening(background: true);
  } catch (e) {
    debugPrint('Service: audio monitor failed to start: $e');
  }

  // C. Listen for SOS packets from nearby phones.
  try {
    await MeshReceiverService().startEmergencyListener();
  } catch (e) {
    debugPrint('Service: mesh receiver failed to start: $e');
  }

  // Impact trigger: hard knock while rotating.
  double rotation = 0.0;
  try {
    gyroscopeEventStream().listen((GyroscopeEvent e) {
      rotation = sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
    });
    accelerometerEventStream().listen((AccelerometerEvent e) {
      final force = sqrt(e.x * e.x + e.y * e.y + e.z * e.z);
      if (force > 25.0 && rotation > 5.0) {
        EmergencyService.triggerEmergencyDispatch(
          force: force,
          level: 'Severe Rotational Impact',
        );
      }
    });
  } catch (e) {
    debugPrint('Service: motion sensors unavailable: $e');
  }
}

class MyApp extends StatelessWidget {
  final bool isSetupComplete;
  const MyApp({super.key, required this.isSetupComplete});

  @override
  Widget build(BuildContext context) {
    User? user;
    try {
      user = FirebaseAuth.instance.currentUser;
    } catch (_) {}

    return MaterialApp(
      navigatorKey: navigatorKey,
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
