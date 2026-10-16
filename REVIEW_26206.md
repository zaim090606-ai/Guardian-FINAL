# Review 26206: finding status (local file, not committed)

FIXED = code changed and covered by unit tests where the logic is pure. Nothing here has run on a phone.

| ID | Finding | Status | Notes |
|---|---|---|---|
| H1 | Nearby plugin cannot run in the service isolate | FIXED (code) | Relay, receiver and beacons run only in the UI isolate; service SOS goes through `relay_offer` with an ack. Not run on a device. Relay works only while the app is open or alive in recents. |
| H2 | Cloud write blocked SMS; Firebase failure could abort dispatch | FIXED | SMS and cloud start together; local id and link; local-first contacts and location; Firebase only in the cloud closure. |
| H3 | Cancel stopped only the UI isolate | FIXED | `cancel_sos` stops timers, Firestore writes, relay and the guard in both isolates. |
| H4 | Duplicate SOS across isolates | FIXED | Persisted active-SOS guard (1 h stale limit). Two isolates writing in the same instant resolve by last writer (small residual race). |
| M1 | Learning from vehicle motion | FIXED | Walking-window gates; regression test with bumpy 10 m/s motion. |
| M2 | Unknown speed/course treated as real | FIXED | Course 0.0 at low speed ignored, accuracies honoured, mocked fixes not learned from. Android `geolocator` values for unknown were not checked on a device. |
| M3 | Anchors one-shot, spoofable, repeats shrink radius, clock skew | PARTLY FIXED | Dedupe, helper age, sigma, 150 m rule, 20 s hold done. Still one beacon per endpoint per 30 s (normally at SOS start) and still unauthenticated: a nearby phone can still send a plausible false beacon. |
| M4 | Any advertiser harvests helper locations | FIXED | Beacon only after a valid SOS packet, at most once per endpoint per 30 s. An attacker can still send a valid-looking packet first. |
| M5 | Advertising leak; own-id suppression | FIXED | In-flight start, honest state, stop when uncertain, own ids persisted. |
| M6 | Two PDR owners, flags not synced | FIXED | Service owns PDR; snapshot every 2 s; flags saved; simulation resets OFF on restart. |
| M7 | Rules and public data | PARTLY FIXED | Private subdocument, owner rules, sign-in retry written; rules NOT run in the emulator and NOT deployed. A relayed doc uploaded before the origin cannot be updated by the origin. |
| M8 | Packet flood | FIXED | Rate limits, full queue rejects newcomers, 2 h age. |
| M9 | Android 12-14 permissions / FGS from boot | NOT FIXED | Not in this task's scope; NEARBY_WIFI_DEVICES and location-services checks, and boot-start of a microphone service on Android 14, are still open. |
| M10 | SMS default SIM, +91 prefix | NOT FIXED | Not in this task's scope. |
| LOW | future timestamp, subscribe race, meter caveat, vehicle growth | FIXED | `heading from raw accelerometer` (noise) not changed. |

## Round 2 (independent review, c9094b9..d0ec8f1, fixes R2-1..R2-11)

| # | Sev | Verdict | Status | Commit / note |
|---|-----|---------|--------|---------------|
| 1 | high | CONFIRMED | FIXED | R2-1: null optional fields were denied by the rules; `AlertSchema.split` drops nulls |
| 2 | high | CONFIRMED | FIXED | R2-1: private subdoc `audioUrl: null` |
| 3 | high | CONFIRMED | FIXED | R2-2: cancel did not stop UI-isolate advertising for service-dispatched SOS; `relay_stop` bridge + `meshStop` |
| 4 | med | CONFIRMED | FIXED | R2-2: cancel during dispatch now stops tracking, recording and late advertising |
| 5 | med | CONFIRMED | PARTLY | R2-3: guard now 60 s heartbeat, future stamps expire. NOT done: user feedback when a trigger is ignored; re-send after an SMS-only failure stays blocked while the SOS is alive |
| 6 | med | PLAUSIBLE | MITIGATED | R2-3: 150 ms settle before re-read. SharedPreferences has no compare-and-set, so a double send in a sub-150 ms race cannot be excluded |
| 7 | med | CONFIRMED | FIXED | R2-4 (M9): `autoStartOnBoot:false`, service `exported=false`. Android 15 dataSync 6 h timeout NOT handled; `usesCleartextTraffic` left as is |
| 8 | med | CONFIRMED | FIXED | R2-5: flush drops expired/invalid entries; mesh ids need 20+ chars |
| 9 | med | CONFIRMED | PARTLY | R2-6: same-spot repeat beacons ignored for 5 min. NOT fixed: beacons are unauthenticated, so a forged far beacon can snap an estimate with sigma >= 30 m (needs signed beacons) |
| 10 | low | CONFIRMED | NOT FIXED | relayer can create the doc first / id squatting; follows from anonymous auth, accepted in rules note 4 |
| 11 | low | CONFIRMED | NOT FIXED | `trusted_contacts` readable by any signed-in user; moving it changes the collection path used by Guardian.dart |
| 12 | low | CONFIRMED | NOT FIXED | `firebase.json` + local open `firestore.rules`: do not run a plain `firebase deploy` |
| 13 | low | CONFIRMED | FIXED | R2-10: ack timeout 8 s |
| 14 | low | PLAUSIBLE | FIXED | R2-8: restore merges ids; `startDiscovery` hang delaying voice monitoring NOT changed |
| 15 | low | PLAUSIBLE | FIXED | R2-9: impact trigger once per minute |
| 16 | low | CONFIRMED | FIXED | R2-7: refined fix time clamped |
| M10 | - | - | FIXED / PARTLY | R2-11: normaliser + skipped list on Diagnostics. SIM fallback NOT implemented: the plugin's `simSlot` is a subscription id and the other SIM's id cannot be found without a new dependency |
| M9 | - | - | FIXED | R2-4: ordered requests (location, notification, mic, Bluetooth, Nearby Wi-Fi, SMS), denied features listed on Diagnostics. `hasMeshPermissions` does not check NEARBY_WIFI_DEVICES (unsure how permission_handler reports it below Android 13) |

Rules (`firestore.rules.proposed`) were still not run in the emulator. Tests: no unit test for R2-7, R2-8, R2-9 (need GPS, plugin or sensor streams).
