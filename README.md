# Guardian Safety

Flutter personal-safety app: detects possible emergencies (motion, voice keywords, sounds) and sends SOS alerts with location to emergency contacts.

## Features (as implemented in `lib/`)
- **Emergency alert**: SOS trigger sends background SMS to saved contacts (`background_sms`, `fast_contacts`) and writes the alert to Cloud Firestore.
- **Location**: GPS via `geolocator`, with pedestrian dead-reckoning fallback from `sensors_plus` (`lib/services/pdr_services.dart`).
- **Maps**: `google_maps_flutter` (requires a Maps API key, see below).
- **Offline speech**: on-device Whisper (`whisper_ggml_plus`, `assets/models/ggml-tiny.bin`) in `lib/services/local_whisper_service.dart`.
- **Sound detection**: on-device YAMNet (`tflite_flutter`, `assets/models/yamnet.tflite`) in `lib/services/yamnet_service.dart`.
- **Gemini analysis**: threat summary of transcript and sound label (`lib/services/ai_service.dart`).
- **Mesh relay**: `nearby_connections` relay/receiver (`relay_service.dart`, `mesh_receiver_service.dart`). Nearby Connections needs an Activity, so it runs only in the UI isolate: **relay works while the app is open or alive in recents**. A voice or impact SOS raised in the background service is handed to the UI isolate (`relay_offer`); if the UI is not running the mesh channel reports "relay unavailable: app UI not running" and SMS / cloud carry on.
- **Auth/storage**: Firebase Auth, Cloud Firestore (persistence enabled), Firebase Storage.
- **Background service**: `flutter_background_service` keeps monitoring running.

Status of each service is in [AUDIT_26206.md](AUDIT_26206.md). Wiring is checked statically; not all paths have been tested on a device.

## Project layout
```
lib/            main.dart, firebase_options.dart, navbar/, screens/, services/
assets/models/  ggml-tiny.bin (Whisper), yamnet.tflite, yamnet_labels.txt
android/ ios/ web/ windows/ macos/ linux/   Flutter platform folders
```

## Setup
```bash
git clone https://github.com/zaim090606-ai/Guardian-FINAL.git
cd Guardian-FINAL
flutter pub get
```
Add your own Firebase config (`android/app/google-services.json`, `lib/firebase_options.dart`).

## Run with keys
Secrets are not stored in the repo.

1. **Gemini key**: copy `secrets.example.json` to `secrets.json` (git-ignored) and put your key in it, then:
   ```bash
   flutter run --dart-define-from-file=secrets.json
   ```
   Without a key the Gemini features return no result.
2. **Maps key (Android)**: append `MAPS_API_KEY=<your key>` to `android/local.properties` (do not overwrite the file Flutter generates). `local.properties.example` is a reference. The Gradle build injects the value into the manifest as `${MAPS_API_KEY}`.

## Diagnostics and phone testing
The home screen has a Diagnostics page (location source, dead reckoning, relay counters, SOS attempt log, audio status). [PHONE_TEST.md](PHONE_TEST.md) lists the one-phone and two-phone checks, and [STATUS_26206.md](STATUS_26206.md) says what is proven and what still needs a device.

## Tests
```bash
flutter test
```

## Other reports
[AUDIT_REPORT.md](AUDIT_REPORT.md), [REPAIR_COMPLETION_REPORT.md](REPAIR_COMPLETION_REPORT.md), [SMS_FIX_IMPLEMENTATION_REPORT.md](SMS_FIX_IMPLEMENTATION_REPORT.md), [ANDROID_16_SMS_FIX_REPORT.md](ANDROID_16_SMS_FIX_REPORT.md), [DEPLOYMENT_VERIFICATION_GUIDE.md](DEPLOYMENT_VERIFICATION_GUIDE.md)
