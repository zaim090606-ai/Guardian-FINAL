import '../services/emergency_service.dart';
import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:permission_handler/permission_handler.dart';

// Model for Impact Log History
class ImpactEvent {
  final double force;
  final String level;
  final DateTime timestamp;

  ImpactEvent({
    required this.force,
    required this.level,
    required this.timestamp,
  });
}

class SensorScreen extends StatefulWidget {
  const SensorScreen({super.key});

  @override
  State<SensorScreen> createState() => _SensorScreenState();
}

class _SensorScreenState extends State<SensorScreen>
    with SingleTickerProviderStateMixin {
  double _x = 0.0, _y = 0.0, _z = 0.0;
  double _totalForce = 0.0;
  bool _isMonitoring = true;
  bool _alertTriggered = false;

  StreamSubscription<UserAccelerometerEvent>? _sensorSubscription;
  Timer? _countdownTimer;
  int _secondsRemaining = 5;
  StateSetter? _dialogSetState; // NEW: lets the Timer force the countdown dialog to redraw

  // UI Throttling: Rebuild UI at max 10 FPS (100ms interval)
  DateTime _lastUiUpdate = DateTime.now();
  static const Duration _uiInterval = Duration(milliseconds: 100);

  // Impact Logs Array
  final List<ImpactEvent> _impactLogs = [];

  // Custom Impact Thresholds (in m/s²)
  final double _lowLimit = 22.0;
  final double _mediumLimit = 35.0;
  final double _highLimit = 50.0;

  // Pulse Animation Controller
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _initPulseAnimation();
    _startListening();

    // Automatically trigger professional permission prompt on app load
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ensureEmergencyPermissions();
    });
  }

  /// Professional permission flow handling permanent denials & settings redirection
  Future<void> _ensureEmergencyPermissions() async {
    Map<Permission, PermissionStatus> statuses = await [
      Permission.location,
      Permission.sms,
    ].request();

    bool permanentlyDenied =
        statuses.values.any((status) => status.isPermanentlyDenied);

    if (permanentlyDenied && mounted) {
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.settings_suggest_rounded, color: Colors.red, size: 28),
              SizedBox(width: 8),
              Text("Permissions Required",
                  style: TextStyle(fontWeight: FontWeight.bold)),
            ],
          ),
          content: const Text(
            "Guardian needs Location and SMS permissions to automatically broadcast emergency alerts and GPS coordinates during an impact. Please enable them in settings.",
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child:
                  const Text("Cancel", style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () {
                Navigator.pop(context);
                openAppSettings(); // Direct link to phone system settings
              },
              child: const Text("Open Settings",
                  style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
    }
  }

  void _initPulseAnimation() {
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat(reverse: true);

    _pulseAnimation = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );
  }

  void _startListening() {
    _sensorSubscription = userAccelerometerEvents.listen(
      (UserAccelerometerEvent event) {
        if (!_isMonitoring) return;

        // 1. UNTHROTTLED: Calculate exact force on every tick (~50-100Hz)
        final double force =
            sqrt(event.x * event.x + event.y * event.y + event.z * event.z);

        // 2. UNTHROTTLED: Threshold checks so brief G-force peaks are never missed
        if (force > _lowLimit && force <= _mediumLimit) {
          _logImpact(force, "MEDIUM");
        }

        if (force > _mediumLimit && !_alertTriggered) {
          if (force > _highLimit) {
            _handleExtremeImpact(force);
          } else {
            _handleHighImpactWithCountdown(force);
          }
        }

        // 3. THROTTLED: Update UI state at max 10 FPS (100ms) to conserve CPU
        final now = DateTime.now();
        if (now.difference(_lastUiUpdate) >= _uiInterval) {
          _lastUiUpdate = now;
          if (mounted) {
            setState(() {
              _x = event.x;
              _y = event.y;
              _z = event.z;
              _totalForce = force;
            });
          }
        }
      },
      onError: (error) {
        debugPrint("Sensor error: $error");
      },
    );
  }

  void _logImpact(double force, String level) {
    // Prevent spamming logs rapidly (min 2 seconds separation)
    if (_impactLogs.isNotEmpty &&
        DateTime.now().difference(_impactLogs.first.timestamp).inSeconds < 2) {
      return;
    }
    if (mounted) {
      setState(() {
        _impactLogs.insert(
          0,
          ImpactEvent(force: force, level: level, timestamp: DateTime.now()),
        );
      });
    }
  }

  String get _emergencyLevel {
    if (_totalForce > _highLimit) return "EXTREME EMERGENCY";
    if (_totalForce > _mediumLimit) return "HIGH EMERGENCY";
    if (_totalForce > _lowLimit) return "MEDIUM IMPACT";
    return "LOW / NORMAL";
  }

  Color get _emergencyColor {
    if (_totalForce > _highLimit) return Colors.purple.shade900;
    if (_totalForce > _mediumLimit) return Colors.red.shade700;
    if (_totalForce > _lowLimit) return Colors.orange.shade700;
    return Colors.green.shade700;
  }

  // Instant Dispatch for EXTREME IMPACT (> 50 m/s²)
  void _handleExtremeImpact(double impactForce) {
   
    HapticFeedback.heavyImpact();
    if (mounted) {
      setState(() {
        _alertTriggered = true;
      });
    }

    _logImpact(impactForce, "EXTREME");
    _dispatchEmergencySOS(force: impactForce, isExtreme: true);

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Colors.purple.shade900,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.dangerous_rounded, color: Colors.white, size: 30),
            SizedBox(width: 8),
            Text(
              "EXTREME IMPACT!",
              style:
                  TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: Text(
          "Critical force of ${impactForce.toStringAsFixed(1)} m/s² detected!\n\nAutomated emergency SOS broadcast & continuous location tracking started.",
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.white,
              foregroundColor: Colors.purple.shade900,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: () async {
              HapticFeedback.selectionClick();
              // Pop dialog first
              Navigator.pop(dialogContext);

              // Stop live GPS stream if user cancels
              await EmergencyService.stopLiveTracking();

              if (mounted) {
                setState(() {
                  _alertTriggered = false;
                });
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text("Emergency SOS & live location tracking cancelled."),
                    backgroundColor: Colors.grey,
                  ),
                );
              }
            },
            child: const Text("CANCEL ALARM",
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );
  }

  // 5-Second Countdown Gauge for HIGH EMERGENCY (35 - 50 m/s²)
  void _handleHighImpactWithCountdown(double impactForce) {
    HapticFeedback.vibrate();
    if (mounted) {
      setState(() {
        _alertTriggered = true;
        _secondsRemaining = 5;
      });
    }

    _logImpact(impactForce, "HIGH");

    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_secondsRemaining > 1) {
        if (mounted) {
          setState(() {
            _secondsRemaining--;
          });
          _dialogSetState?.call(() {}); // NEW: forces the dialog's countdown number to redraw
        }
      } else {
        timer.cancel();
        _dialogSetState = null; // NEW: clear reference before the dialog closes
        if (mounted && Navigator.canPop(context)) {
          Navigator.pop(context);
        }
        if (mounted) {
          setState(() {
            _alertTriggered = false;
          });
        }
        _dispatchEmergencySOS(force: impactForce, isExtreme: false);
      }
    });

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            _dialogSetState = setDialogState; // NEW: capture so the Timer above can trigger a redraw
            return AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      color: Colors.red, size: 28),
                  SizedBox(width: 8),
                  Text("HIGH EMERGENCY!",
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    "High-impact force of ${impactForce.toStringAsFixed(1)} m/s² detected.\nAuto-sending SOS & live location in:",
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 20),
                  // Animated Radial Progress Gauge
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 90,
                        height: 90,
                        child: CircularProgressIndicator(
                          value: _secondsRemaining / 5,
                          strokeWidth: 7,
                          color: Colors.red.shade700,
                          backgroundColor: Colors.red.shade100,
                        ),
                      ),
                      Text(
                        "$_secondsRemaining",
                        style: TextStyle(
                          fontSize: 34,
                          fontWeight: FontWeight.bold,
                          color: Colors.red.shade700,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    HapticFeedback.selectionClick();
                    _countdownTimer?.cancel();
                    _dialogSetState = null; // NEW
                    Navigator.pop(dialogContext);
                    if (mounted) {
                      setState(() {
                        _alertTriggered = false;
                      });
                    }
                  },
                  child: const Text("CANCEL",
                      style: TextStyle(
                          color: Colors.grey, fontWeight: FontWeight.bold)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.shade700,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: () {
                    HapticFeedback.mediumImpact();
                    _countdownTimer?.cancel();
                    _dialogSetState = null; // NEW
                    Navigator.pop(dialogContext);
                    if (mounted) {
                      setState(() {
                        _alertTriggered = false;
                      });
                    }
                    _dispatchEmergencySOS(force: impactForce, isExtreme: false);
                  },
                  child: const Text("SEND NOW",
                      style: TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _dispatchEmergencySOS(
      {required double force, required bool isExtreme}) async {
    String level = isExtreme ? "EXTREME" : "HIGH";

    await EmergencyService.triggerEmergencyDispatch(
      force: force,
      level: level,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          isExtreme
              ? "CRITICAL SOS DISPATCHED — LIVE LOCATION TRACKING ACTIVE!"
              : "HIGH EMERGENCY DISPATCHED — LIVE LOCATION TRACKING ACTIVE!",
        ),
        backgroundColor:
            isExtreme ? Colors.purple.shade900 : Colors.red.shade700,
        duration: const Duration(seconds: 5),
      ),
    );
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _sensorSubscription?.cancel();
    _countdownTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9F9F9),
      appBar: AppBar(
        title: const Text(
          "Motion & Impact Guard",
          style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: ListTile(
                leading: Stack(
                  alignment: Alignment.center,
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _isMonitoring
                            ? Icons.sensors_rounded
                            : Icons.sensors_off_rounded,
                        color: Colors.black,
                        size: 28,
                      ),
                    ),
                    if (_isMonitoring)
                      Positioned(
                        right: 2,
                        top: 2,
                        child: FadeTransition(
                          opacity: _pulseAnimation,
                          child: Container(
                            width: 10,
                            height: 10,
                            decoration: const BoxDecoration(
                              color: Colors.green,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
                title: Text(
                  _isMonitoring ? "Active Guard Mode" : "Guard Disarmed",
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16),
                ),
                subtitle: Text(
                  _isMonitoring
                      ? "Live accelerometer & GPS stream active"
                      : "Tap switch to re-enable",
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
                trailing: Switch(
                  value: _isMonitoring,
                  activeThumbColor: Colors.black,
                  onChanged: (val) {
                    HapticFeedback.selectionClick();
                    setState(() {
                      _isMonitoring = val;
                    });
                  },
                ),
              ),
            ),
            const SizedBox(height: 24),

            const Text(
              "REAL-TIME ACCELEROMETER (m/s²)",
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12,
                letterSpacing: 1.1,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 12),

            Row(
              children: [
                Expanded(
                    child: _buildMetricTile("X-AXIS", _x.toStringAsFixed(1))),
                const SizedBox(width: 10),
                Expanded(
                    child: _buildMetricTile("Y-AXIS", _y.toStringAsFixed(1))),
                const SizedBox(width: 10),
                Expanded(
                    child: _buildMetricTile("Z-AXIS", _z.toStringAsFixed(1))),
              ],
            ),

            const SizedBox(height: 24),

            Container(
              padding: const EdgeInsets.all(20.0),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Column(
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        "Current Impact Force",
                        style: TextStyle(fontSize: 13, color: Colors.grey),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(
                          color: _emergencyColor.withAlpha(25),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                              color: _emergencyColor.withAlpha(76)),
                        ),
                        child: Text(
                          _emergencyLevel,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: _emergencyColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    "${_totalForce.toStringAsFixed(1)} m/s²",
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.bold,
                      color: _totalForce > _mediumLimit
                          ? _emergencyColor
                          : Colors.black,
                    ),
                  ),
                  const SizedBox(height: 16),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: LinearProgressIndicator(
                      value: (_totalForce / (_highLimit * 1.2)).clamp(0.0, 1.0),
                      backgroundColor: Colors.grey.shade200,
                      color: _emergencyColor,
                      minHeight: 10,
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    "Low: ≤22  •  Med: 22-35  •  High: 35-50  •  Extreme: >50 m/s²",
                    style: TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 24),

            const Text(
              "SESSION IMPACT LOG",
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12,
                letterSpacing: 1.1,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 12),

            Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: _impactLogs.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(20.0),
                      child: Center(
                        child: Text(
                          "No high-impact events recorded this session.",
                          style: TextStyle(color: Colors.grey, fontSize: 13),
                        ),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount:
                          _impactLogs.length > 5 ? 5 : _impactLogs.length,
                      separatorBuilder: (context, index) =>
                          Divider(height: 1, color: Colors.grey.shade200),
                      itemBuilder: (context, index) {
                        final log = _impactLogs[index];
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            Icons.bolt_rounded,
                            color: log.level == "EXTREME"
                                ? Colors.purple.shade900
                                : log.level == "HIGH"
                                    ? Colors.red.shade700
                                    : Colors.orange.shade700,
                          ),
                          title: Text(
                            "${log.level} IMPACT — ${log.force.toStringAsFixed(1)} m/s²",
                            style: const TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 13),
                          ),
                          subtitle: Text(
                            "${log.timestamp.hour.toString().padLeft(2, '0')}:${log.timestamp.minute.toString().padLeft(2, '0')}:${log.timestamp.second.toString().padLeft(2, '0')}",
                            style: const TextStyle(
                                fontSize: 11, color: Colors.grey),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMetricTile(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Column(
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.grey,
              fontWeight: FontWeight.bold,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.black,
            ),
          ),
        ],
      ),
    );
  }
}