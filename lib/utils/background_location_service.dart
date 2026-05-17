import 'dart:async';
import 'dart:ui';
import 'firestore_utils.dart';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show WidgetsFlutterBinding;
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../firebase_options.dart';

/// Background location + geofence service.
///
/// On Android this runs as a foreground service (so the OS doesn't kill it
/// when the app is backgrounded or recently swiped away). On iOS it runs as
/// long as the OS allows; iOS will throttle aggressively when the user is
/// stationary, but `UIBackgroundModes: location` keeps it alive for trip
/// scenarios.
///
/// What the service does on every position update:
///   1. Publishes lat/lng to `users/{uid}` so other phones see the marker move
///      whether or not this user has the app in front.
///   2. Looks at the user's active trip (a trip with status == 'in_progress'
///      where this UID is either a teacher or a passenger).
///   3. If the trip has an active stop with a geofence, checks distance and
///      shows a local notification + writes a `trips/{tripId}/alerts/...`
///      doc when the user *first* leaves the zone. (The teacher-side stream
///      then plays the alarm sound, same as before.)
class BackgroundLocationService {
  static const String _channelId = 'fieldtrip_high_importance';
  static const String _channelName = 'FieldTrip360 alerts';
  static const String _channelDesc =
      'Trip status, geofence warnings and chat messages';

  /// Configures the service once (call from `main` after Firebase init).
  /// Doesn't start it — call [start] after a successful login.
  static Future<void> configure() async {
    final service = FlutterBackgroundService();

    // Local notifications are needed in BOTH isolates: the main isolate uses
    // them for FCM/chat notifs in the foreground, and the background isolate
    // uses them for geofence warnings.
    await _initLocalNotifications();

    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: _onStart,
        autoStart: false,
        isForegroundMode: true,
        notificationChannelId: _channelId,
        initialNotificationTitle: 'FieldTrip360',
        initialNotificationContent: 'Live tracking is active',
        foregroundServiceNotificationId: 888,
        foregroundServiceTypes: [AndroidForegroundType.location],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: _onStart,
        onBackground: _onIosBackground,
      ),
    );
  }

  static Future<void> _initLocalNotifications() async {
    final notifs = FlutterLocalNotificationsPlugin();
    const androidInit = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosInit = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );
    await notifs.initialize(const InitializationSettings(
      android: androidInit,
      iOS: iosInit,
    ));
    // Create the high-importance channel up-front so notifications make sound.
    final androidImpl = notifs.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await androidImpl?.createNotificationChannel(
      const AndroidNotificationChannel(
        _channelId,
        _channelName,
        description: _channelDesc,
        importance: Importance.high,
      ),
    );
    await androidImpl?.requestNotificationsPermission();
  }

  /// Start the service. Pass the current user's UID so the background
  /// isolate doesn't have to rely on FirebaseAuth state propagation.
  static Future<void> start(String uid) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('bg.uid', uid);

    final service = FlutterBackgroundService();
    final running = await service.isRunning();
    if (!running) {
      await service.startService();
    }
    // Inform the running service of the latest UID (in case it was already up).
    service.invoke('updateUid', {'uid': uid});
  }

  /// Stop the service (call on logout).
  static Future<void> stop() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('bg.uid');
    final service = FlutterBackgroundService();
    if (await service.isRunning()) {
      service.invoke('stopService');
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Background isolate entry points
// ─────────────────────────────────────────────────────────────────────────────

@pragma('vm:entry-point')
Future<bool> _onIosBackground(ServiceInstance service) async {
  // iOS calls this periodically. We keep it short and let the foreground
  // handler do the heavy lifting.
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();
  return true;
}

@pragma('vm:entry-point')
Future<void> _onStart(ServiceInstance service) async {
  // Run inside its own isolate — every plugin needs to be re-initialized here.
  DartPluginRegistrant.ensureInitialized();

  // Firebase needs to be initialized in this isolate too.
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (_) {/* already initialized */}

  final prefs = await SharedPreferences.getInstance();
  String? uid = prefs.getString('bg.uid') ?? FirebaseAuth.instance.currentUser?.uid;

  // Allow the main isolate to push fresh UIDs in (e.g. user re-logs).
  service.on('updateUid').listen((event) async {
    uid = event?['uid'] as String?;
    if (uid == null || uid!.isEmpty) {
      service.invoke('stopService');
    }
  });

  service.on('stopService').listen((_) async {
    await _positionSub?.cancel();
    await _tripSub?.cancel();
    _heartbeat?.cancel();
    if (service is AndroidServiceInstance) {
      service.setAsBackgroundService();
    }
    service.stopSelf();
  });

  if (service is AndroidServiceInstance) {
    service.setAsForegroundService();
    service.setForegroundNotificationInfo(
      title: "FieldTrip360",
      content: "Live tracking is active",
    );
  }

  // Local notifications must be fully set up in this isolate independently
  // of the main isolate. Creating the channel again here is safe — Android
  // only registers it once and ignores duplicate create calls.
  final notifs = FlutterLocalNotificationsPlugin();
  await notifs.initialize(const InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(),
  ));
  await notifs
      .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(
        const AndroidNotificationChannel(
          BackgroundLocationService._channelId,
          BackgroundLocationService._channelName,
          description: BackgroundLocationService._channelDesc,
          importance: Importance.high,
          playSound: true,
          enableVibration: true,
        ),
      );

  // Listen to the user's active trip so we know which geofence to check.
  Map<String, dynamic>? activeTripData;
  String? activeTripId;
  String? userName;
  bool wasOutOfBounds = false;

  // Fetch the user doc once to know their display name (for alert payloads).
  try {
    if (uid != null) {
      final u = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      userName = u.data()?['name']?.toString();
    }
  } catch (_) {}

  _tripSub = FirebaseFirestore.instance
      .collection('trips')
      .where('status', isEqualTo: 'in_progress')
      .snapshots()
      .listen((snap) {
    activeTripData = null;
    activeTripId = null;
    for (final doc in snap.docs) {
      final data = doc.data();
      final buses = asList(data['buses']);
      bool inTrip = false;
      for (final b in buses) {
        if (b is Map) {
          if (b['mainTeacher']?['id'] == uid || b['coTeacher']?['id'] == uid) {
            inTrip = true;
            break;
          }
          for (final p in (b['passengers'] as List? ?? const [])) {
            if (p is Map && p['id'] == uid) {
              inTrip = true;
              break;
            }
          }
        }
        if (inTrip) break;
      }
      if (inTrip) {
        activeTripData = data;
        activeTripId = doc.id;
        break;
      }
    }
  });

  Position? lastPos;

  Future<void> publish(Position pos) async {
    if (uid == null) return;
    lastPos = pos;
    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).update({
        'lat': pos.latitude,
        'lng': pos.longitude,
        'lastUpdate': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      debugPrint('[bg] publish failed: $e');
    }

    // Geofence check (students only — teachers don't need a warning when
    // they themselves step out, since they're the ones supervising).
    final trip = activeTripData;
    if (trip == null) return;
    final activeStop = trip['activeStopIndex'];
    if (activeStop is! int || activeStop < 0) return;
    final stops = (trip['stops'] as List?) ?? const [];
    if (activeStop >= stops.length) return;
    final stop = stops[activeStop] as Map;
    if (stop['lat'] is! num || stop['lng'] is! num) return;
    final centerLat = (stop['lat'] as num).toDouble();
    final centerLng = (stop['lng'] as num).toDouble();
    final radius = (stop['geofenceRadius'] is num)
        ? (stop['geofenceRadius'] as num).toDouble()
        : 200.0;
    final distance = Geolocator.distanceBetween(
      pos.latitude,
      pos.longitude,
      centerLat,
      centerLng,
    );

    if (distance > radius && !wasOutOfBounds) {
      wasOutOfBounds = true;
      try {
        // Dedup: if the service was killed and restarted while the student was
        // already outside, there may be a pending alert doc from the previous
        // run. Only write a new one if no pending alert exists for this student
        // on this trip, so the teacher doesn't receive duplicate notifications.
        final existing = await FirebaseFirestore.instance
            .collection('trips')
            .doc(activeTripId)
            .collection('alerts')
            .where('studentId', isEqualTo: uid)
            .where('status', isEqualTo: 'pending')
            .limit(1)
            .get();
        if (existing.docs.isEmpty) {
          await FirebaseFirestore.instance
              .collection('trips')
              .doc(activeTripId)
              .collection('alerts')
              .add({
            'studentId': uid,
            'studentName': userName ?? 'Student',
            'stopIndex': activeStop,
            'distance': distance,
            'status': 'pending',
            'createdAt': FieldValue.serverTimestamp(),
          });
        }
      } catch (e) {
        debugPrint('[bg] alert write failed: $e');
      }
      // Always show the local notification — even if an alert doc already
      // exists the student should still be reminded on their screen.
      final notifId = DateTime.now().millisecondsSinceEpoch.remainder(100000);
      await notifs.show(
        notifId,
        '⚠️ Out of bounds',
        'You left the designated area. Return to the group.',
        const NotificationDetails(
          android: AndroidNotificationDetails(
            BackgroundLocationService._channelId,
            BackgroundLocationService._channelName,
            channelDescription: BackgroundLocationService._channelDesc,
            importance: Importance.max,
            priority: Priority.max,
            playSound: true,
            enableVibration: true,
            ongoing: false,
          ),
          iOS: DarwinNotificationDetails(presentAlert: true, presentSound: true),
        ),
      );
    } else if (distance <= radius && wasOutOfBounds) {
      wasOutOfBounds = false;
      // Optional: notify "back in zone" — keep it quiet for now.
    }
  }

  _positionSub = Geolocator.getPositionStream(
    locationSettings: const LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 3,
    ),
  ).listen(publish, onError: (e) => debugPrint('[bg] pos error: $e'));

  // Heartbeat so observers see updates even when standing still or when the
  // OS coalesces getPositionStream events.
  _heartbeat = Timer.periodic(const Duration(seconds: 5), (_) async {
    final pos = lastPos;
    if (pos != null) await publish(pos);
  });
}

// Top-level so the cancel() calls in the `stopService` handler can reach them.
StreamSubscription<Position>? _positionSub;
StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _tripSub;
Timer? _heartbeat;

extension _ChannelExposed on BackgroundLocationService {}
