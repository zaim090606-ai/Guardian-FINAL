import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/emergency_service.dart';
import '../services/voice_service.dart';

class Home extends StatefulWidget {
  const Home({super.key});

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  GoogleMapController? _mapController;
  StreamSubscription<Position>? _positionStream;

  LatLng _currentLatLng = const LatLng(28.6139, 77.2090);
  bool _isLoadingMap = true;
  bool _isBlackBoxExpanded = false;
  bool _userIsPanningMap = false;

  static const String _contactKey = "emergency_contact_number";
  String _emergencyContactNumber = "";

  @override
  void initState() {
    super.initState();
    _loadSavedContact();
    _startLiveLocationTracking();
    _initVoiceService();
  }

  void _initVoiceService() {
    VoiceService.startListening(
      onSosTriggeredCallback: () {
        if (mounted) {
          _triggerSos("Voice Keyword Trigger");
        }
      },
    );
  }

  Future<void> _loadSavedContact() async {
    final prefs = await SharedPreferences.getInstance();
    final savedNumber = prefs.getString(_contactKey);
    if (savedNumber != null && savedNumber.isNotEmpty && mounted) {
      setState(() {
        _emergencyContactNumber = savedNumber;
      });
    }
  }

  Future<void> _saveContact(String number) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_contactKey, number);
    if (mounted) {
      setState(() {
        _emergencyContactNumber = number;
      });
    }
  }

  Future<void> _startLiveLocationTracking() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if (mounted) setState(() => _isLoadingMap = false);
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        if (mounted) setState(() => _isLoadingMap = false);
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      if (mounted) setState(() => _isLoadingMap = false);
      return;
    }

    try {
      Position initialPosition = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );
      if (mounted) {
        setState(() {
          _currentLatLng = LatLng(initialPosition.latitude, initialPosition.longitude);
          _isLoadingMap = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _isLoadingMap = false);
    }

    const locationSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5,
    );

    _positionStream = Geolocator.getPositionStream(locationSettings: locationSettings)
        .listen((Position position) {
      if (!mounted) return;
      setState(() {
        _currentLatLng = LatLng(position.latitude, position.longitude);
      });

      if (!_userIsPanningMap) {
        _mapController?.animateCamera(
          CameraUpdate.newLatLng(_currentLatLng),
        );
      }
    });
  }

  Future<void> _makePhoneCall(String phoneNumber) async {
    final Uri launchUri = Uri(scheme: 'tel', path: phoneNumber);
    if (await canLaunchUrl(launchUri)) {
      await launchUrl(launchUri);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Could not launch phone dialer for $phoneNumber")),
      );
    }
  }

  void _showAddEditContactDialog() {
    final numberController = TextEditingController(text: _emergencyContactNumber);

    showDialog(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text("Emergency Contact"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text("Enter the phone number for emergency dispatch and SMS alerts:"),
              const SizedBox(height: 12),
              TextField(
                controller: numberController,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(
                  labelText: "Phone Number",
                  hintText: "e.g. 9876543210",
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.phone),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                numberController.dispose();
                Navigator.pop(dialogContext);
              },
              child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.black,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              onPressed: () async {
                final text = numberController.text.trim();
                if (text.isNotEmpty) {
                  await _saveContact(text);
                  numberController.dispose();
                  if (dialogContext.mounted) {
                    Navigator.pop(dialogContext);
                  }
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text("Emergency Contact Saved!")),
                    );
                  }
                }
              },
              child: const Text("Save Number", style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  void _showCustomKeywordsDialog() {
    final keywordController = TextEditingController();

    showDialog(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (stfContext, setDialogState) {
            return AlertDialog(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
              title: const Row(
                children: [
                  Icon(Icons.record_voice_over, color: Colors.black),
                  SizedBox(width: 8),
                  Text("Voice Trigger Keywords", style: TextStyle(fontSize: 18)),
                ],
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    "Active Trigger Words:",
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: VoiceService.activeKeywords.map((word) {
                      return Chip(
                        label: Text(word, style: const TextStyle(fontSize: 11)),
                        backgroundColor: Colors.grey.shade100,
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: keywordController,
                    decoration: const InputDecoration(
                      labelText: "Add Secret Trigger Word",
                      hintText: "e.g. pineapple, code red",
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    keywordController.dispose();
                    Navigator.pop(dialogContext);
                  },
                  child: const Text("Done", style: TextStyle(color: Colors.grey)),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onPressed: () async {
                    final text = keywordController.text.trim();
                    if (text.isNotEmpty) {
                      bool added = await VoiceService.addCustomKeyword(text);
                      if (added) {
                        keywordController.clear();
                        if (stfContext.mounted) {
                          setDialogState(() {});
                        }
                        if (mounted) setState(() {});
                      }
                    }
                  },
                  child: const Text("Add Word", style: TextStyle(color: Colors.white)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _triggerSos([String level = "Manual SOS Button"]) async {
    if (!mounted) return;

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.red, size: 28),
            SizedBox(width: 8),
            Text("SOS Activated!"),
          ],
        ),
        content: Text(
          _emergencyContactNumber.isNotEmpty
              ? "Dispatching emergency background SMS to $_emergencyContactNumber with live location..."
              : "No contact set! Please configure an emergency number.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text("OK", style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
          ),
        ],
      ),
    );

    try {
      await EmergencyService.triggerEmergencyDispatch(
        force: 0.0,
        level: level,
      );
    } catch (e) {
      debugPrint("SOS Dispatch Error: $e");
    }
  }

  @override
  void dispose() {
    _positionStream?.cancel();
    _mapController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9F9F9),
      appBar: AppBar(
        title: const Text(
          "Guardian Home",
          style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Guardian AI Black Box Capsule
              AnimatedContainer(
                duration: const Duration(milliseconds: 300),
                curve: Curves.easeInOut,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: Colors.black.withOpacity(0.12),
                    width: 1.2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.03),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    InkWell(
                      onTap: () {
                        setState(() {
                          _isBlackBoxExpanded = !_isBlackBoxExpanded;
                        });
                      },
                      child: Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.all(6),
                            decoration: BoxDecoration(
                              color: Colors.black.withOpacity(0.05),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.security_rounded,
                              color: Colors.black,
                              size: 16,
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Expanded(
                            child: Text(
                              "Guardian AI Voice Shield",
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: Colors.black,
                              ),
                            ),
                          ),
                          ValueListenableBuilder<bool>(
                            valueListenable: VoiceService.isEnabledNotifier,
                            builder: (context, isEnabled, child) {
                              return Transform.scale(
                                scale: 0.8,
                                child: Switch(
                                  value: isEnabled,
                                  activeColor: Colors.green,
                                  onChanged: (val) {
                                    VoiceService.toggleVoiceMonitoring(val);
                                  },
                                ),
                              );
                            },
                          ),
                          Icon(
                            _isBlackBoxExpanded
                                ? Icons.keyboard_arrow_up
                                : Icons.keyboard_arrow_down,
                            size: 18,
                            color: Colors.grey,
                          ),
                        ],
                      ),
                    ),
                    if (_isBlackBoxExpanded) ...[
                      const Padding(
                        padding: EdgeInsets.symmetric(vertical: 8.0),
                        child: Divider(height: 1, color: Color(0xFFEEEEEE)),
                      ),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                const Text(
                                  "Rolling Buffer Transcript:",
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.grey,
                                  ),
                                ),
                                InkWell(
                                  onTap: _showCustomKeywordsDialog,
                                  child: const Row(
                                    children: [
                                      Icon(Icons.add_circle_outline, size: 14, color: Colors.blue),
                                      SizedBox(width: 4),
                                      Text(
                                        "Keywords",
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: Colors.blue,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            ValueListenableBuilder<String>(
                              valueListenable: VoiceService.transcriptNotifier,
                              builder: (context, transcript, child) {
                                return Text(
                                  transcript.isNotEmpty
                                      ? '"$transcript"'
                                      : "Listening for keywords (${VoiceService.activeKeywords.take(3).join(', ')}...)",
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontStyle: transcript.isNotEmpty
                                        ? FontStyle.normal
                                        : FontStyle.italic,
                                    color: transcript.isNotEmpty
                                        ? Colors.black87
                                        : Colors.grey.shade500,
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // Embedded Live Google Map Card
              Container(
                height: 220,
                width: double.infinity,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.grey.shade300),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.04),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: _isLoadingMap
                      ? const Center(child: CircularProgressIndicator())
                      : GoogleMap(
                          initialCameraPosition: CameraPosition(
                            target: _currentLatLng,
                            zoom: 16.0,
                          ),
                          myLocationEnabled: true,
                          myLocationButtonEnabled: true,
                          markers: {
                            Marker(
                              markerId: const MarkerId('current_user'),
                              position: _currentLatLng,
                              infoWindow: const InfoWindow(title: 'Your Location'),
                            ),
                          },
                          onCameraMoveStarted: () {
                            _userIsPanningMap = true;
                          },
                          onMapCreated: (controller) {
                            _mapController = controller;
                          },
                        ),
                ),
              ),
              const SizedBox(height: 28),

              const Text(
                "EMERGENCY OVERRIDE",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 1.2,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                "Press & Hold SOS for 3 Seconds",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.black,
                ),
              ),
              const SizedBox(height: 20),

              Center(
                child: SosHoldButton(
                  onSosTriggered: () => _triggerSos("Manual SOS Button"),
                ),
              ),
              const SizedBox(height: 32),

              Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Icon(Icons.contact_phone_outlined, color: Colors.black),
                              InkWell(
                                onTap: _showAddEditContactDialog,
                                borderRadius: BorderRadius.circular(20),
                                child: const Padding(
                                  padding: EdgeInsets.all(4.0),
                                  child: Row(
                                    children: [
                                      Icon(Icons.edit_outlined, size: 16, color: Colors.blue),
                                      SizedBox(width: 2),
                                      Text(
                                        "Edit",
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Colors.blue,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          const Text(
                            "Emergency Contact",
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Expanded(
                                child: Text(
                                  _emergencyContactNumber.isNotEmpty
                                      ? _emergencyContactNumber
                                      : "No Contact Set",
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.black,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              InkWell(
                                onTap: () {
                                  if (_emergencyContactNumber.isNotEmpty) {
                                    _makePhoneCall(_emergencyContactNumber);
                                  } else {
                                    _showAddEditContactDialog();
                                  }
                                },
                                borderRadius: BorderRadius.circular(30),
                                child: Container(
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.green.shade50,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.phone,
                                    color: Colors.green,
                                    size: 18,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      child: const Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(Icons.location_on_outlined, color: Colors.black),
                          SizedBox(height: 18),
                          Text(
                            "GPS Tracking",
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey,
                            ),
                          ),
                          SizedBox(height: 4),
                          Text(
                            "High Accuracy",
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.bold,
                              color: Colors.black,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class SosHoldButton extends StatefulWidget {
  final VoidCallback onSosTriggered;

  const SosHoldButton({super.key, required this.onSosTriggered});

  @override
  State<SosHoldButton> createState() => _SosHoldButtonState();
}

class _SosHoldButtonState extends State<SosHoldButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  Timer? _hapticTimer;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          _stopHapticTimer();
          HapticFeedback.vibrate();
          widget.onSosTriggered();
          _controller.reset();
        }
      });
  }

  void _startHapticFeedback() {
    HapticFeedback.heavyImpact();
    _hapticTimer?.cancel();
    _hapticTimer = Timer.periodic(const Duration(milliseconds: 300), (_) {
      HapticFeedback.selectionClick();
    });
  }

  void _stopHapticTimer() {
    _hapticTimer?.cancel();
    _hapticTimer = null;
  }

  void _onTapDown(TapDownDetails details) {
    _startHapticFeedback();
    _controller.forward();
  }

  void _onTapUp(TapUpDetails details) {
    _resetHold();
  }

  void _onTapCancel() {
    _resetHold();
  }

  void _resetHold() {
    _stopHapticTimer();
    if (_controller.isAnimating) {
      _controller.reset();
    }
  }

  @override
  void dispose() {
    _stopHapticTimer();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return GestureDetector(
          onTapDown: _onTapDown,
          onTapUp: _onTapUp,
          onTapCancel: _onTapCancel,
          child: Stack(
            alignment: Alignment.center,
            children: [
              SizedBox(
                width: 170,
                height: 170,
                child: CircularProgressIndicator(
                  value: _controller.value,
                  strokeWidth: 8,
                  backgroundColor: Colors.grey.shade200,
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.black),
                ),
              ),
              Container(
                width: 140,
                height: 140,
                decoration: BoxDecoration(
                  color: Colors.black,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.15),
                      blurRadius: 10,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Center(
                  child: Text(
                    "SOS",
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}