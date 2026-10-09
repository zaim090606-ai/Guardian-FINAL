import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../logic/countdown.dart';
import 'emergency_service.dart';

/// False-alarm protection for automatically detected SOS events (voice,
/// scream, siren). The service isolate shows a "sending in N seconds" alert
/// with a Cancel action and, when the app is open, the UI isolate shows a
/// dialog. Cancelling from either place stops the SOS.
class SosCountdownService {
  static const int seconds = 10;
  static const int _notificationId = 7001;
  static const String cancelAction = 'cancel_sos';

  static final CancelableCountdown _countdown = CancelableCountdown();
  static final FlutterLocalNotificationsPlugin _notifications =
      FlutterLocalNotificationsPlugin();
  static bool _notificationsReady = false;
  static ServiceInstance? _service;

  // ---------------------------------------------------- service isolate side

  static void attachService(ServiceInstance service) {
    _service = service;
  }

  /// Returns true when the SOS should be sent (nobody cancelled in time).
  static Future<bool> confirm(String reason) async {
    await _showNotification(reason);
    try {
      _service?.invoke('countdown', {'reason': reason, 'seconds': seconds});
    } catch (_) {}

    final proceed = await _countdown.start(const Duration(seconds: seconds));

    try {
      _service?.invoke('countdown_end', {'sent': proceed});
    } catch (_) {}
    try {
      await _notifications.cancel(id: _notificationId);
    } catch (_) {}
    return proceed;
  }

  static void cancel() => _countdown.cancel();

  static Future<void> _showNotification(String reason) async {
    try {
      if (!_notificationsReady) {
        await _notifications.initialize(
          settings: const InitializationSettings(
            android: AndroidInitializationSettings('@mipmap/ic_launcher'),
          ),
        );
        _notificationsReady = true;
      }
      await _notifications.show(
        id: _notificationId,
        title: 'Possible emergency detected',
        body: '$reason. Sending SOS in $seconds seconds. Tap Cancel to stop.',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            'guardian_sos_countdown',
            'SOS countdown',
            importance: Importance.max,
            priority: Priority.max,
            category: AndroidNotificationCategory.alarm,
            timeoutAfter: seconds * 1000,
            actions: [
              AndroidNotificationAction(
                cancelAction,
                'Cancel SOS',
                showsUserInterface: true,
                cancelNotification: true,
              ),
            ],
          ),
        ),
      );
    } catch (e) {
      debugPrint('Countdown notification unavailable: $e');
    }
  }

  // ------------------------------------------------------------- UI side

  static bool _uiAttached = false;
  static bool _dialogOpen = false;

  /// Shows the cancel dialog while the app is open.
  static void attachUi(GlobalKey<NavigatorState> navigatorKey) {
    if (_uiAttached) return;
    _uiAttached = true;
    final bg = FlutterBackgroundService();

    bg.on('countdown').listen((event) {
      final ctx = navigatorKey.currentContext;
      if (ctx == null || _dialogOpen) return;
      _dialogOpen = true;
      final reason = '${event?['reason'] ?? 'Emergency detected'}';
      showDialog<void>(
        context: ctx,
        barrierDismissible: false,
        builder: (_) => _CountdownDialog(
          reason: reason,
          seconds: (event?['seconds'] as num?)?.toInt() ?? seconds,
          onCancel: () => unawaited(EmergencyService.cancelSos()),
        ),
      ).whenComplete(() => _dialogOpen = false);
    });

    bg.on('countdown_end').listen((_) {
      if (_dialogOpen) {
        navigatorKey.currentState?.pop();
      }
    });
  }
}

class _CountdownDialog extends StatefulWidget {
  final String reason;
  final int seconds;
  final VoidCallback onCancel;
  const _CountdownDialog({
    required this.reason,
    required this.seconds,
    required this.onCancel,
  });

  @override
  State<_CountdownDialog> createState() => _CountdownDialogState();
}

class _CountdownDialogState extends State<_CountdownDialog> {
  late int _left = widget.seconds;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _left > 0) setState(() => _left--);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Possible emergency detected'),
      content: Text('${widget.reason}\n\nSending SOS in $_left s.'),
      actions: [
        FilledButton(
          onPressed: () {
            widget.onCancel();
            Navigator.of(context).pop();
          },
          child: const Text('CANCEL - I am safe'),
        ),
      ],
    );
  }
}
