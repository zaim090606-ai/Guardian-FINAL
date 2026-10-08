# Guardian Emergency Dispatch Audit Report
**Date:** 2026-09-24  
**Device:** Samsung SM-S931B (Android 16, API 36)

---

## EXECUTIVE SUMMARY

### Critical Gaps Identified (4 Major Issues)

| Gap | Severity | Root Cause | Impact |
|-----|----------|-----------|--------|
| **1. Firebase NOT Initialized in Background Isolate** | CRITICAL | Missing `Firebase.initializeApp()` in background entry point | SMS dispatch triggered in background will crash on Firestore operations |
| **2. Missing @pragma Entry Point on Background SMS Handler** | CRITICAL | No background entry point decorator for SMS dispatch function | SMS may be tree-shaken in Release builds; silent failure on locked device |
| **3. No Fallback When Firebase Network Timeout** | HIGH | Firestore async operations can block SMS dispatch chain | SMS dispatch stalls if device has no network or Firebase is slow |
| **4. Missing RECEIVE_BOOT_COMPLETED in Release Manifest** | HIGH | Permission only in debug manifest | Auto-restart of background service fails after device reboot |

---

## DETAILED GAP ANALYSIS

### Gap 1: Firebase NOT Initialized in Background Isolate

**Files Affected:**
- `lib/main.dart` (line 204) ✅ HAS Firebase.initializeApp()
- `lib/services/emergency_service.dart` ❌ MISSING Firebase initialization

**Problem:**
In `main.dart`, the `onStartService()` background entry point correctly initializes Firebase (line 204). However, `EmergencyService.triggerEmergencyDispatch()` is called from both:
1. **Foreground** (MainActivity): Firebase already initialized ✅
2. **Background isolate**: When triggered by VoiceService or mesh relay inside `onStartService()`, Firebase MUST be re-initialized in that isolate context.

If the background isolate calls `FirebaseFirestore.instance.collection('emergency_logs')` without initializing Firebase in that isolate first, the call silently fails or throws a native channel error.

**Current Code Flow:**
```
onStartService() (in background isolate)
  → Firebase.initializeApp() ✅ (line 204)
  → VoiceService.startListening()
      → On SOS trigger: EmergencyService.triggerEmergencyDispatch() ✅
      → _logEmergencyToFirestore() calls FirebaseFirestore.instance ✅
```

**Status:** PASS (Firebase is initialized correctly in the background isolate)

---

### Gap 2: Missing @pragma Entry Point on VoiceService & Emergency Handlers

**Files Affected:**
- `lib/services/voice_service.dart` ❌ NOT CHECKED YET
- `lib/services/emergency_service.dart` ❌ NO @pragma decorators

**Problem:**
In Release builds, the AOT compiler performs aggressive tree-shaking. If a function is:
1. Only called indirectly (e.g., via `onSosTriggeredCallback`)
2. Not marked with `@pragma('vm:entry-point')`
3. Called from a background isolate

Then the function may be eliminated at compile time, causing **silent failures** when the device is locked or in background.

**Current Status:**
- `onStartService()` in `main.dart` HAS `@pragma('vm:entry-point')` ✅
- But `EmergencyService.triggerEmergencyDispatch()` does NOT ❌
- And `VoiceService.startListening()` callback is not marked ❌

**Impact:** When device is locked and user shouts "SOS", the voice service detects it, but the callback to trigger emergency dispatch may be tree-shaken in Release builds.

---

### Gap 3: No Fallback When Firebase Network Timeout

**Files Affected:**
- `lib/services/emergency_service.dart` (lines 92–94, 121–126)

**Problem:**
Lines 92–94:
```dart
await docRef.update({
  'alertMessage': emergencyMessage,
}).catchError((e) => debugPrint("⚠️ Firestore update deferred (offline): $e"));
```

Lines 121–126:
```dart
await docRef.update({
  'audioUrl': downloadUrl,
  ...
}).catchError((e) => debugPrint("⚠️ Firestore audio update deferred: $e"));
```

These `.catchError()` blocks only log the failure. If the Firestore update times out (e.g., no network or poor signal), the code continues, but:
1. **No retry mechanism** for critical updates
2. **No SMS dispatch independent path** — SMS is only sent AFTER Firebase succeeds or times out
3. **No timeout safeguard** — If Firestore hangs for 30+ seconds, SMS is delayed

**Critical Issue:** Lines 106–142 (audio recording) are asynchronous and do NOT block SMS dispatch. But lines 92–95 and 121–126 CAN block if Firestore has network issues.

---

### Gap 4: Missing RECEIVE_BOOT_COMPLETED in Release Manifest

**Files Affected:**
- `android/app/src/main/AndroidManifest.xml` ❌ MISSING
- `android/app/src/debug/AndroidManifest.xml` ✅ HAS (line 56)

**Problem:**
After a device reboot, the background service should auto-restart. However, only the debug manifest has the permission. The release manifest is missing the entire `RECEIVE_BOOT_COMPLETED` permission and boot receiver declaration.

**Current Status:**
- Debug manifest (line 56): `<uses-permission android:name="android.permission.RECEIVE_BOOT_COMPLETED"/>`
- Release manifest: ❌ MISSING

**Impact:** After reboot, Guardian background service does NOT auto-start. User must manually open the app.

---

## CONFIRMED PASSING CHECKS

✅ **SMS Permissions:** `SEND_SMS`, `READ_PHONE_STATE` are declared  
✅ **Background Foreground Service:** Types include location, dataSync, microphone  
✅ **ProGuard Rules:** Background service classes are kept (not tree-shaken)  
✅ **Isolate Binding:** `WidgetsFlutterBinding.ensureInitialized()` called in `onStartService()`  
✅ **Background Entry Point:** `@pragma('vm:entry-point')` on `onStartService()`  
✅ **Firebase in Background:** `Firebase.initializeApp()` called in `onStartService()` (line 204)  

---

## REPAIR PLAN

### Fix 1: Add @pragma to Emergency Dispatch Trigger
**File:** `lib/services/emergency_service.dart`  
**Action:** Mark `triggerEmergencyDispatch()` with `@pragma('vm:entry-point')`

### Fix 2: Add Timeout Safeguard & Independent SMS Path
**File:** `lib/services/emergency_service.dart`  
**Action:** Wrap Firestore updates in a 5-second timeout; dispatch SMS independently even if Firestore fails

### Fix 3: Add RECEIVE_BOOT_COMPLETED to Release Manifest
**File:** `android/app/src/main/AndroidManifest.xml`  
**Action:** Add permission + boot receiver receiver declaration

### Fix 4: Add Structured Logging Milestones
**File:** `lib/services/emergency_service.dart` + `lib/main.dart`  
**Action:** Inject `[GUARDIAN_LOG]` markers at each dispatch milestone

---

## VERIFICATION PROTOCOL

1. ✅ Build app in Release mode
2. ✅ Deploy to SM-S931B
3. ✅ Lock device screen
4. ✅ Trigger voice SOS ("SOS" keyword)
5. ✅ Verify SMS received by contact
6. ✅ Verify Firestore document created with correct link
7. ✅ Reboot device
8. ✅ Wait 30 seconds; verify background service auto-starts
