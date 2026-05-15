import 'package:flutter/foundation.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

/// Centralized FCM glue: registers permissions, saves the device token to the
/// current user's doc, and refreshes on rotation. Safe to call multiple times.
class MessagingService {
  static final MessagingService instance = MessagingService._();
  MessagingService._();

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized || kIsWeb) return;
    _initialized = true;
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);

      // Save initial token.
      final token = await messaging.getToken();
      await _saveToken(token);

      // Save on rotation.
      messaging.onTokenRefresh.listen(_saveToken);
    } catch (e) {
      debugPrint("MessagingService init failed: $e");
    }
  }

  Future<void> _saveToken(String? token) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null || token == null) return;
    try {
      await FirebaseFirestore.instance.collection('users').doc(user.uid).set({
        'fcmTokens': FieldValue.arrayUnion([token]),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint("Failed to save FCM token: $e");
    }
  }

  Future<void> clearTokenForCurrentUser() async {
    if (kIsWeb) return;
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token == null) return;
      await FirebaseFirestore.instance.collection('users').doc(user.uid).update({
        'fcmTokens': FieldValue.arrayRemove([token]),
      });
    } catch (_) {}
  }
}
