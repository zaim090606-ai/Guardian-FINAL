# Phone test plan

Build and install the debug APK, then run with your own keys if you want Gemini or the map:

```bash
flutter run --dart-define-from-file=secrets.json
```

Before every test: open the app once, accept **all** permission prompts (SMS, Phone, Location "all the time", Microphone, Notifications, Nearby devices / Bluetooth, battery optimisation), and add at least one emergency contact on the Contacts screen. Use a contact whose phone you can check.

Open **Diagnostics** from the monitor icon at the top right of the home screen. Items marked SIMULATED are labelled in the app and are not real results.

## One phone

| # | Step | Expected result | Pass/Fail |
|---|------|-----------------|-----------|
| 1 | Open Diagnostics, go outside or next to a window, wait 30 s. | Location source shows GPS, an uncertainty in metres, "Last real GPS fix" a few seconds ago. | [ ] Pass [ ] Fail |
| 2 | Hold the phone flat in your hand, top edge pointing the way you walk. Turn on **Simulate GPS loss**. | Orange "SIMULATED: GPS is being ignored" banner appears. | [ ] Pass [ ] Fail |
| 3 | Wait 10 s, then walk 50 normal steps in a straight line. | After about 8 s the source changes to ESTIMATED. Steps counted rises by about 50. Uncertainty grows (about +0.15 m per metre walked). Heading is shown. | [ ] Pass [ ] Fail |
| 4 | While in this state press the SOS button on the home screen. | Contact receives an SMS that says "ESTIMATED, SIMULATED GPS LOSS". The Firestore alert has `locationSource: estimated`, `locationSimulated: true`. | [ ] Pass [ ] Fail |
| 5 | Turn **Simulate GPS loss** off. | Banner disappears. Within a few seconds the source returns to GPS. | [ ] Pass [ ] Fail |
| 6 | Turn off Wi-Fi and mobile data but keep cellular signal (SMS works without data). Press SOS. | Diagnostics "SOS send attempts" shows `firestore FAILED`, `sms OK`, and `relay OK` (relay OK only means advertising started). The contact receives the SMS with coordinates. | [ ] Pass [ ] Fail |
| 7 | Turn Wi-Fi or mobile data back on and wait 1 minute. | The alert document appears in Firestore (it was queued locally). | [ ] Pass [ ] Fail |
| 8 | Remove SMS permission in Android settings and press SOS. | App does not crash. Attempt log shows `sms FAILED - SMS permission not granted`; firestore (and relay if offline) still run. | [ ] Pass [ ] Fail |
| 9 | Stay close to the phone in a quiet room, then say "help" clearly. | Within a few seconds a "Possible emergency detected" alert appears with a **Cancel** action and a 10 s countdown. Audio section shows both models loaded. | [ ] Pass [ ] Fail |
| 10 | Repeat step 9 and tap **CANCEL - I am safe**. | No SMS is sent, no alert is created. | [ ] Pass [ ] Fail |
| 11 | Repeat step 9 and do nothing. | After 10 s the SOS is sent (SMS to the contact, alert in Firestore). Wait 2 minutes before the next test (cooldown). | [ ] Pass [ ] Fail |
| 12 | Play a loud scream or siren sample from a second device 20 cm from the microphone for 5 s. | "Last sound class" shows Screaming/Siren or similar with a percentage, then the countdown alert appears. | [ ] Pass [ ] Fail |
| 13 | Deny the microphone permission in Android settings and restart the app. | App runs. Diagnostics shows Microphone: denied. No crash. | [ ] Pass [ ] Fail |
| 14 | Press **Send test SOS via relay (SIMULATED)** with no other phone nearby. | Event list shows "Offering test-..." and "Advertising SOS to nearby phones". Nothing is received. | [ ] Pass [ ] Fail |

## Two phones (A offline, B online)

Both phones need the app installed, permissions granted, and Bluetooth and Wi-Fi switched on. Keep them within 2 m. Make sure the foreground notification "Guardian Safety Active" is showing on both.

| # | Step | Expected result | Pass/Fail |
|---|------|-----------------|-----------|
| 15 | Phone B: online, open Diagnostics. | Relay state shows `discovering`. | [ ] Pass [ ] Fail |
| 16 | Phone A: switch off Wi-Fi and mobile data (keep Bluetooth on). | Phone A has no internet. | [ ] Pass [ ] Fail |
| 17 | Phone A: Diagnostics, press **Send test SOS via relay (SIMULATED)**. | A shows `advertising` and then "Sent test-... to a peer"; Sent counter goes up. | [ ] Pass [ ] Fail |
| 18 | Phone B: watch Diagnostics for up to 60 s. | Peers found 1 or more, Received 1, Uploaded 1. A notification "Emergency signal received" appears. | [ ] Pass [ ] Fail |
| 19 | Firebase console, collection `emergency_logs`. | A document with id `test-...`, `relayedByMesh: true`, `simulated: true`, `status: test` exists. | [ ] Pass [ ] Fail |
| 20 | Phone A: press the real SOS button while still offline. | A's attempt log shows firestore FAILED, sms (OK or FAILED), relay OK. B's Received counter increases and a document with A's alert id appears in Firestore with `relayedByMesh: true`. | [ ] Pass [ ] Fail |
| 21 | Open the same alert id on the tracking page `https://fir-b10e4.web.app/alert/<id>` | Page shows the location; ESTIMATED is flagged if the source was estimated. | [ ] Pass [ ] Fail |
| 22 | Repeat step 17 a second time with the same phones. | B counts a new packet (new id). Sending the same id again would show as `duplicate` in the event list and is not uploaded twice. | [ ] Pass [ ] Fail |
| 23 | Phone B: turn off internet, repeat step 17 from A, then turn B's internet back on. | B Queued 1, "waiting" 1; within about 60 s of connectivity returning Uploaded rises and the document appears. | [ ] Pass [ ] Fail |

Notes for the tester
- Nearby Connections needs the Nearby/Bluetooth permissions granted on Android 12+. If Relay state stays `idle`, check them in Settings > Apps > Guardian.
- Step 6 (offline SMS) needs a SIM with mobile signal. Full airplane mode also blocks SMS, so test it with data off instead.
- Record the Diagnostics attempt log and event list as evidence for each pass or fail.
