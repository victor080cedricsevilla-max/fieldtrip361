import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'firebase_options.dart';
import 'config/theme.dart';
import 'utils/background_location_service.dart';

import 'views/auth/login_view.dart';
import 'views/auth/mobile_login_view.dart';
import 'views/admin/admin_dashboard.dart';
import 'views/teacher/teacher_dashboard.dart';
import 'views/student/student_dashboard.dart';

/// Top-level handler required by firebase_messaging — runs in its own isolate
/// when a push arrives while the app is killed or backgrounded.
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  // OS will display the notification automatically when the payload includes
  // a `notification` block. Nothing to do here besides keep the handler
  // registered.
}

final FlutterLocalNotificationsPlugin _localNotifs =
    FlutterLocalNotificationsPlugin();

Future<void> _showLocalChatNotification(RemoteMessage msg) async {
  final n = msg.notification;
  if (n == null) return;
  await _localNotifs.show(
    msg.hashCode,
    n.title ?? 'FieldTrip360',
    n.body ?? '',
    const NotificationDetails(
      android: AndroidNotificationDetails(
        'fieldtrip_high_importance',
        'FieldTrip360 alerts',
        channelDescription: 'Trip status, geofence warnings and chat messages',
        importance: Importance.high,
        priority: Priority.high,
      ),
      iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
    ),
  );
}

void main() async {
  // Run everything inside a guarded zone so a failure in one of the new
  // services doesn't kill the entire app at startup — we still want the UI
  // to come up even if notifications or the background service can't init.
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e, st) {
    debugPrint("Firebase init failed: $e\n$st");
  }

  // FCM: background handler must be registered before runApp.
  try {
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);
    await FirebaseMessaging.instance.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );
  } catch (e) {
    debugPrint("FCM init failed: $e");
  }

  // Local notifications init (used for foreground FCM display).
  try {
    await _localNotifs.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      ),
    ));
    FirebaseMessaging.onMessage.listen(_showLocalChatNotification);
  } catch (e) {
    debugPrint("local notifs init failed: $e");
  }

  // Configure (but don't start) the background location/geofence service.
  // flutter_background_service is mobile-only; skip entirely on web.
  if (!kIsWeb) {
    try {
      await BackgroundLocationService.configure();
    } catch (e, st) {
      debugPrint("BackgroundLocationService.configure failed: $e\n$st");
    }
  }

  // Cold-start case: if the user is still signed in from a previous run,
  // resume tracking right away without waiting for them to log in again.
  try {
    final restoredUser = FirebaseAuth.instance.currentUser;
    if (restoredUser != null) {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(restoredUser.uid)
          .get();
      final role = (snap.data()?['role'] ?? '').toString();
      if (!kIsWeb && (role == 'teacher' || role == 'student' || role == 'parent')) {
        await BackgroundLocationService.start(restoredUser.uid);
      }
    }
  } catch (e, st) {
    debugPrint("Background service auto-resume failed: $e\n$st");
  }

  runApp(const FieldTrip360App());
}

class FieldTrip360App extends StatelessWidget {
  const FieldTrip360App({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FieldTrip360',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      home: kIsWeb ? const LoginView() : const MobileLoginView(),
      routes: {
        '/admin-login': (context) => const LoginView(),
        '/mobile-login': (context) => const MobileLoginView(),
        '/admin/dashboard': (context) => const AdminDashboard(),
        '/teacher/dashboard': (context) => const TeacherDashboard(),
        '/student/dashboard': (context) => const StudentDashboard(),
      },
    );
  }
}