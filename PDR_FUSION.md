# PDR fusion: what it does, what is proven

Dead reckoning (PDR) keeps a position estimate when GPS is lost. This note covers the improvements that make the estimate learn from GPS, from sound and from nearby phones. Every improvement is behind a flag in `PdrConfig` (`lib/logic/pdr_config.dart`), all on by default, each switchable on the Diagnostics screen.

Nothing here has been measured on a phone yet. See "What is proven" at the end.

## What each part does

### Fixes
- **Steps without a heading** still count distance and steps, so the uncertainty keeps growing. With no heading, +50% of the stride is added to the uncertainty (the direction is unknown). The position does not move.
- **Estimated fixes keep the time of the last GPS fix** (`timeMs`); `generatedAtMs` is "now". The SMS text, the Diagnostics screen, the Firestore alert (`locationFixTimeMs`, `locationAgeS`) and the tracker page show "last GPS fix N ago". (The tracker page lives in `public/` and is changed locally only; it is not committed.)
- **Relay** keeps offering an SOS packet until the SOS is cancelled (`stopRelay`) or 30 minutes pass. Packet ids created by this phone are pre-marked as seen so the sender never re-processes or re-forwards its own SOS.

### PDR learns from GPS (flags: compass gating, heading offset, stride learning)
- **Compass gating** rejects magnetometer samples whose field strength is outside 25-65 microtesla (metal, magnets, speakers). Good samples keep the existing smoothing.
- **Heading offset**: while GPS accuracy is 15 m or better, speed is at least 1.0 m/s and steps are detected, the engine takes the GPS course (`Position.heading`, or the bearing between fixes at least 5 m apart) and keeps a circular moving average of (GPS course minus compass heading). The offset is added to the compass heading, which matters when GPS is lost. If the gravity direction in the device frame turns by more than 40 degrees since the offset was last calibrated (phone moved, e.g. hand to pocket), the offset is marked invalid, the compass heading is used without it, extra uncertainty (+50% of each stride) is added, and the offset is relearned when GPS returns.
- **Stride learning**: over windows of at least 20 m of good-GPS distance, stride = GPS distance / steps. A moving average is kept, clamped to 0.45-1.0 m, starting from 0.75 m.
- **Drift fraction**: 0.15 uncalibrated, 0.10 when both the heading offset and the stride are calibrated. **Both numbers are ASSUMPTIONS to be replaced by field measurements.**

### Microphone context (flag: microphone context)
`MotionContextClassifier` (`lib/logic/motion_context.dart`) works on YAMNet labels and step activity.
- **Vehicle** = engine / vehicle / car / bus / train / truck / motorcycle / aircraft style labels (names taken from `assets/models/yamnet_labels.txt`; sirens and horns are excluded) scoring at least 0.4 on 3 consecutive chunks. Leaving vehicle needs 3 consecutive non-vehicle chunks.
- While in vehicle: steps are not counted, the position does not move, and the uncertainty grows with time (assumed up to 8 m/s, capped at 2000 m). The fix carries `context: vehicle` (also stored in Firestore as `locationContext`).
- **Stationary** (no steps for 10 s) does not grow the uncertainty (it grows with distance, and there is none).
- If YAMNet is not loaded, or gave no chunk in the last 30 s, the context is unknown and PDR behaves as before. The labels reach the engine from `voice_service.dart` inside the same isolate, through `PdrService.onSoundLabels`.

### Nearby anchors (flag: anchors)
- A helper phone running the app that connects to an SOS sender answers with a small beacon `{lat, lng, accuracyM, timestamp, source}` (`lib/logic/anchor_beacon.dart`) **only if** it has a real GPS fix with accuracy 30 m or better, is not simulating GPS loss, and the fix is under 20 s old. The beacon has no identity and is exchanged only while the sender has an SOS being offered. The sender validates it like an `SosPacket`.
- Fusion (`lib/logic/anchor_fusion.dart`): the peer fix is a position measurement with sigma = max(peer accuracy, 20 m). It is ignored while the sender's own GPS is fresh, and ignored when older than 30 s. With a stale estimate: if the distance between estimate and anchor exceeds the current uncertainty the estimate snaps to the anchor, otherwise the two are combined by inverse-variance weighting. The distance walked since the last fix is reset. The fix stays `estimated` and reports `anchorUsed`, the anchor age and the radius right after the correction.
- The 20 m sigma is a guess for GPS error plus the unknown distance between the two phones; it is an assumption.

### Proof tools
- **Ground-truth error meter**: while Simulate GPS loss is ON, the real GPS is still read, but it is only used to measure the error of the estimate (never to compute it). Diagnostics shows metres walked since the loss (steps x stride), the current error, the maximum error, error as a percentage of distance, a run summary line that can be screenshotted (for example "112 m walked, final error 9 m, 8%") and the state of every flag.
- Diagnostics also has a switch per flag, a motion-context line, the last anchor (age, radius before and after) and a **Send test anchor (SIMULATED beacon)** button. Everything simulated is labelled SIMULATED.

## Limits
- Relay and anchor beacons use Nearby Connections, which runs only in the UI isolate: **relay works while the app is open or alive in recents**. Beacons received there are passed to the PDR owner with the `anchor_beacon` event.
- The heading offset assumes the phone orientation stays as it was when calibrated. The 40-degree gravity check only catches large changes; a slow change, or a phone moved in a way that keeps gravity the same (rotated about the vertical axis), is not detected.
- Compass interference near metal, vehicles, power lines and electronics is only partly handled by the 25-65 microtesla gate; a disturbed field with a normal strength still gives a wrong heading.
- Anchors need another Guardian phone with a good GPS fix to come close during an SOS, and the radio link between the phones to work. A far or old beacon is not exact: the 20 m minimum sigma is an assumption.
- The drift fractions 0.15 and 0.10 are assumptions. The 8 m/s vehicle growth is an assumption.
- Stride learning uses the straight-line GPS distance over each window, which under-estimates when the path curves, and GPS noise matters at 20 m windows.
- The error meter's "metres walked" is steps x stride, not a surveyed distance.
- Vehicle detection is sound-based: a loud engine nearby while walking can be taken for a vehicle, a quiet electric vehicle may not be detected.
- The error meter, flag switches and test anchor run on the UI-side PDR instance; the service-side instance receives the same flags, test anchors and real anchors, but its own estimate is what a background SOS sends.

## Results table (field experiment from PHONE_TEST.md)

Outdoors in an open area: GPS good for 30 s, Simulate GPS loss ON, 100 m straight, 90-degree turn, 50 m more. Cells are intentionally empty until real runs are done. Never fill them with estimated numbers.

| Run | Flags | Walked (m) | Final error (m) | Error (%) | Date / place / notes |
|---|---|---|---|---|---|
| 1 | all OFF | | | | |
| 2 | all OFF | | | | |
| 3 | all OFF | | | | |
| 4 | all ON | | | | |
| 5 | all ON | | | | |
| 6 | all ON | | | | |
| Mean OFF | | | | | |
| Mean ON | | | | | |

## What is proven

| Item | Status |
|---|---|
| Steps without heading grow uncertainty; estimated fix keeps the last GPS time and age | UNIT-TESTED |
| SMS text and Diagnostics show the age of the last GPS fix | UNIT-TESTED (SMS text builder) / NEEDS DEVICE TEST (screens, tracker page) |
| 30-minute offer window; own packet ids never re-processed | UNIT-TESTED (constant, seen-cache behaviour) / NEEDS DEVICE TEST (cancel stops advertising) |
| Compass gating (25-65 uT) | UNIT-TESTED (the gate function) / NEEDS DEVICE TEST (real magnetometer values) |
| Heading offset learned from a synthetic 15-degree bias; invalidated by a gravity turn | UNIT-TESTED on synthetic data / NEEDS DEVICE TEST |
| Stride learning, clamp, drift fraction 0.15 / 0.10 | UNIT-TESTED on synthetic data; the fractions are assumptions |
| Motion-context enter / leave vehicle with hysteresis; vehicle suppresses steps and grows uncertainty; stationary does not | UNIT-TESTED / NEEDS DEVICE TEST (real YAMNet output on a real sound) |
| Beacon validation, offer rule, anchor fusion (snap, weighting, ignored when GPS fresh, expiry) | UNIT-TESTED |
| Beacon over Nearby Connections between two phones | NEEDS DEVICE TEST |
| SIMULATION test: 200 m walk with a 10-degree bias, learned offset and mid-walk anchor each give a smaller error than neither | SIMULATED (model check on synthetic data, not a field measurement) |
| Error meter arithmetic | UNIT-TESTED / NEEDS DEVICE TEST (real GPS truth) |
| Whether the improvements reduce the real error | NOT MEASURED (results table above is empty) |
