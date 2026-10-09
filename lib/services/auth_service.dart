import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logic/alert_schema.dart';

/// Anonymous sign-in with retry, and a one-slot store for an alert that could
/// not be written because the phone was never signed in. The alert document
/// always carries the real uid; 'anonymous' is never written as a userId.
class AuthService {
  static const String _pendingKey = 'pending_alert_doc';
  static Timer? _retry;

  /// The signed-in uid, signing in anonymously first if needed; null when that
  /// is not possible (offline, Firebase unavailable).
  static Future<String?> ensureUid() async {
    try {
      var user = FirebaseAuth.instance.currentUser;
      user ??= (await FirebaseAuth.instance
              .signInAnonymously()
              .timeout(const Duration(seconds: 8)))
          .user;
      return user?.uid;
    } catch (e) {
      debugPrint('Sign-in not available: $e');
      return null;
    }
  }

  /// Keeps trying to sign in every 60 s until it works, then sends any alert
  /// that was waiting. Safe to call repeatedly.
  static void startRetryLoop() {
    if (_retry != null) return;
    _retry = Timer.periodic(const Duration(seconds: 60), (t) async {
      final uid = await ensureUid();
      if (uid != null) {
        t.cancel();
        _retry = null;
        await flushPending();
      }
    });
    unawaited(ensureUid().then((uid) async {
      if (uid != null) {
        _retry?.cancel();
        _retry = null;
        await flushPending();
      }
    }));
  }

  /// Remembers an alert (public and private parts, JSON-safe values only) to
  /// send once the phone is signed in.
  static Future<void> savePending(
      String id, Map<String, dynamic> data) async {
    try {
      final safe = <String, dynamic>{};
      data.forEach((k, v) {
        if (v is num || v is String || v is bool || v == null) safe[k] = v;
      });
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_pendingKey, jsonEncode({'id': id, 'data': safe}));
    } catch (_) {}
  }

  static Future<void> flushPending() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      final raw = prefs.getString(_pendingKey);
      if (raw == null || raw.isEmpty) return;
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      final m = jsonDecode(raw) as Map;
      final id = m['id'] as String;
      final parts =
          AlertSchema.split(Map<String, dynamic>.from(m['data'] as Map), uid);
      final ref = FirebaseFirestore.instance.collection('emergency_logs').doc(id);
      await ref.set({
        ...parts.public,
        'timestamp': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      await ref
          .collection('private')
          .doc('details')
          .set(parts.private, SetOptions(merge: true));
      await prefs.remove(_pendingKey);
    } catch (e) {
      debugPrint('Pending alert not sent yet: $e');
    }
  }
}
