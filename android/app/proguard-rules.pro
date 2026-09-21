# Flutter & Background Execution Keep Rules
-keep class id.flutter.flutter_background_service.** { *; }
-keep class com.pravera.flutter_foreground_task.** { *; }
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }

# Firebase & Google Mobile Services
-keep class com.google.firebase.** { *; }
-keep class com.google.android.gms.** { *; }

# Sensor & Speech Recognition Native Interfaces
-keep class com.csdcorp.speech_to_text.** { *; }
-keep class dev.fluttercommunity.plus.sensors.** { *; }