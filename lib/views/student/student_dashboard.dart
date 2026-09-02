import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import '../../config/theme.dart';
import '../../widgets/glass_emergency_button.dart';
import '../../widgets/glass_nav_bar.dart';
import '../../widgets/glass_nav_scaffold.dart';
import '../../controllers/auth_controller.dart';
import '../../utils/live_tracker.dart';
import '../../utils/firestore_utils.dart';
import '../../utils/trip_queries.dart';
import '../auth/mobile_login_view.dart';
import '../shared/settings_view.dart';
import '../shared/chat_view.dart';
import '../shared/notification_panel.dart';
import 'student_documents_tab.dart';

class MarkerGenerator {
  static Future<BitmapDescriptor> createCustomMarker(String name, Color color) async {
    const int size = 50;
    final ui.PictureRecorder pictureRecorder = ui.PictureRecorder();
    final Canvas canvas = Canvas(pictureRecorder);

    final Paint shadowPaint = Paint()..color = Colors.black38;
    canvas.drawCircle(const Offset(size / 2, size / 2 + 5), size / 2.5, shadowPaint);

    final Paint borderPaint = Paint()..color = Colors.white;
    canvas.drawCircle(const Offset(size / 2, size / 2), size / 2.2, borderPaint);

    final Paint innerPaint = Paint()..color = color;
    canvas.drawCircle(const Offset(size / 2, size / 2), size / 2.5, innerPaint);

    final TextPainter textPainter = TextPainter(textDirection: TextDirection.ltr);
    textPainter.text = TextSpan(
      text: name.isNotEmpty ? name[0].toUpperCase() : '?',
      style: const TextStyle(fontSize: size / 2.5, color: Colors.white, fontWeight: FontWeight.bold),
    );
    textPainter.layout();
    textPainter.paint(canvas, Offset(size / 2 - textPainter.width / 2, size / 2 - textPainter.height / 2));

    final ui.Image image = await pictureRecorder.endRecording().toImage(size, size + 10);
    final ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return BitmapDescriptor.bytes(byteData!.buffer.asUint8List());
  }
}

class StudentDashboard extends StatefulWidget {
  const StudentDashboard({super.key});

  @override
  State<StudentDashboard> createState() => _StudentDashboardState();
}

class _StudentDashboardState extends State<StudentDashboard> {
  int _selectedIndex = 0;
  late final List<Widget> _pages;
  StreamSubscription<QuerySnapshot>? _geofenceTripSub;
  StreamSubscription<QuerySnapshot>? _geofenceAlertSub;
  StreamSubscription? _activeTripSub;
  StreamSubscription<Position>? _dashPositionStream;
  Timer? _dashHeartbeatTimer;
  Position? _dashLastPos;
  Map<String, dynamic>? _activeTripData;
  bool _dashIsOutOfBounds = false;
  String? _watchedTripId;
  BuildContext? _warningCtx;

  @override
  void initState() {
    super.initState();
    _pages = [
      const StudentTripsTab(),
      const StudentQRTab(),
      const ChatListView(),
      const StudentDocumentsTab(),
      const StudentProfileTab(),
    ];
    _requestLocationPermission();
    _listenForGeofenceAlerts();
    _startDashboardLocationUpdates();
  }

  void _listenForGeofenceAlerts() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    // Scoped to trips this student is assigned to; the in_progress check moves
    // into the loop because pairing it with the membership filter would need a
    // composite index.
    _geofenceTripSub = TripQueries.mine().listen((snap) {
      String? newTripId;
      outer:
      for (final doc in snap.docs) {
        if (doc.data()['status'] != 'in_progress') continue;
        final buses = asList(doc.data()['buses']);
        for (final b in buses) {
          if (b is Map) {
            for (final p in asList(b['passengers'])) {
              if (p is Map && p['id'] == uid) {
                newTripId = doc.id;
                break outer;
              }
            }
          }
        }
      }

      // Keep active trip data fresh for geofence distance checks.
      if (newTripId != null) {
        for (final doc in snap.docs) {
          if (doc.id == newTripId) { _activeTripData = doc.data(); break; }
        }
      } else {
        _activeTripData = null;
      }

      if (newTripId == _watchedTripId) return;
      _watchedTripId = newTripId;
      _geofenceAlertSub?.cancel();
      _activeTripSub?.cancel();

      if (newTripId == null) return;

      // Subscribe to real-time trip updates so activeStopIndex stays current.
      _activeTripSub = FirebaseFirestore.instance
          .collection('trips')
          .doc(newTripId)
          .snapshots()
          .listen((tripDoc) {
        if (tripDoc.exists) _activeTripData = tripDoc.data();
      });

      bool isFirstSnapshot = true;
      final seenIds = <String>{};
      _geofenceAlertSub = FirebaseFirestore.instance
          .collection('trips')
          .doc(newTripId)
          .collection('alerts')
          .where('studentId', isEqualTo: uid)
          .where('status', isEqualTo: 'pending')
          .snapshots()
          .listen((alertSnap) {
        if (isFirstSnapshot) {
          isFirstSnapshot = false;
          for (final d in alertSnap.docs) { seenIds.add(d.id); }
          return;
        }
        for (final change in alertSnap.docChanges) {
          if (change.type == DocumentChangeType.added &&
              !seenIds.contains(change.doc.id)) {
            seenIds.add(change.doc.id);
            if (!mounted) return;
            if (!_dashIsOutOfBounds) {
              _dashIsOutOfBounds = true;
              FlutterRingtonePlayer().play(
                fromAsset: "assets/audio/alarm.mp3",
                looping: true,
                volume: 1.0,
                asAlarm: true,
              );
              _showDashboardOutOfBoundsWarning();
            }
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Row(
                  children: [
                    Icon(Icons.location_off_rounded, color: Colors.white),
                    SizedBox(width: 10),
                    Expanded(child: Text('âš ï¸ You have left the designated area! Return to the group immediately.')),
                  ],
                ),
                backgroundColor: Colors.orange.shade700,
                duration: const Duration(seconds: 8),
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            );
          }
        }
      });
    });
  }

  void _startDashboardLocationUpdates() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      _dashLastPos = pos;
      _publishAndCheckGeofence(uid, pos);
    } catch (_) {}
    _dashPositionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
      ),
    ).listen(
      (pos) {
        _dashLastPos = pos;
        _publishAndCheckGeofence(uid, pos);
      },
      onError: (e) => debugPrint("GPS stream error (student dash): $e"),
      cancelOnError: false,
    );
    _dashHeartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      Position? pos = _dashLastPos;
      if (pos == null) {
        try { pos = await Geolocator.getLastKnownPosition(); } catch (_) {}
      }
      if (pos != null) _publishAndCheckGeofence(uid, pos);
    });
  }

  Future<void> _publishAndCheckGeofence(String uid, Position pos) async {
    // Only publish after QR scan on the active trip.  If there is no active
    // in-progress trip, or the student hasn't been scanned yet, skip entirely.
    final trip = _activeTripData;
    if (trip == null) return;
    bool scanned = false;
    outer:
    for (final b in asList(trip['buses'])) {
      if (b is Map) {
        for (final p in asList(b['passengers'])) {
          if (p is Map && p['id'] == uid) {
            final att = p['attendance'];
            if (att is Map && att.values.any((v) => v == true)) scanned = true;
            break outer;
          }
        }
      }
    }
    if (!scanned) return;

    try {
      await FirebaseFirestore.instance.collection('locations').doc(uid).set({
        'lat': pos.latitude,
        'lng': pos.longitude,
        'lastUpdate': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (_) {}

    final activeStop = trip['activeStopIndex'];
    if (activeStop is! int || activeStop < 0) return;
    final stops = asList(trip['stops']);
    if (activeStop >= stops.length) return;
    final stop = stops[activeStop];
    if (stop is! Map || stop['lat'] is! num || stop['lng'] is! num) return;
    final centerLat = (stop['lat'] as num).toDouble();
    final centerLng = (stop['lng'] as num).toDouble();
    final radius = (stop['geofenceRadius'] is num)
        ? (stop['geofenceRadius'] as num).toDouble()
        : 200.0;
    final distance = Geolocator.distanceBetween(
      pos.latitude, pos.longitude, centerLat, centerLng,
    );
    if (distance > radius && !_dashIsOutOfBounds) {
      _dashIsOutOfBounds = true;
      FlutterRingtonePlayer().play(
        fromAsset: "assets/audio/alarm.mp3",
        looping: true,
        volume: 1.0,
        asAlarm: true,
      );
      if (mounted) _showDashboardOutOfBoundsWarning();
    } else if (distance <= radius && _dashIsOutOfBounds) {
      _dashIsOutOfBounds = false;
      FlutterRingtonePlayer().stop();
      final ctx = _warningCtx;
      if (ctx != null && ctx.mounted) {
        Navigator.pop(ctx);
        _warningCtx = null;
      }
    }
  }

  void _showDashboardOutOfBoundsWarning() {
    if (_warningCtx != null) return; // already showing
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        _warningCtx = ctx;
        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: Colors.red, size: 28),
              SizedBox(width: 8),
              Text("GEOFENCE WARNING",
                  style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 18)),
            ],
          ),
          content: const Text(
            "You left the designated area. Return immediately.",
            style: TextStyle(fontSize: 15),
          ),
        );
      },
    ).then((_) => _warningCtx = null);
  }

  @override
  void dispose() {
    _geofenceTripSub?.cancel();
    _geofenceAlertSub?.cancel();
    _activeTripSub?.cancel();
    _dashPositionStream?.cancel();
    _dashHeartbeatTimer?.cancel();
    super.dispose();
  }

  void _showEmergencyButton() {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => const EmergencyButtonDialog(),
    );
  }

  Future<void> _requestLocationPermission() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      await Geolocator.requestPermission();
    }
  }

  Widget _buildEmergencyBanner() {
    final String myUid = FirebaseAuth.instance.currentUser!.uid;
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('emergencies')
          .where('studentId', isEqualTo: myUid)
          .where('status', whereIn: ['pending', 'accepted'])
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return const SizedBox.shrink();
        }
        final doc = snapshot.data!.docs.first;
        final data = doc.data() as Map<String, dynamic>;
        final isAccepted = data['status'] == 'accepted';

        return SafeArea(
          bottom: false,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: isAccepted ? Colors.green : Colors.orange,
            child: Row(
              children: [
                Icon(isAccepted ? Icons.check_circle : Icons.warning_amber_rounded, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    isAccepted
                        ? "Rescue is on the way! Your teacher is notified."
                        : "Emergency alert sent. Waiting for teacher...",
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
                if (isAccepted)
                  TextButton(
                    onPressed: () => doc.reference.update({'status': 'resolved'}),
                    child: const Text("Resolve", style: TextStyle(color: Colors.white, decoration: TextDecoration.underline)),
                  )
              ],
            ),
          )
        );
      },
    );
  }


  static const _navItems = <GlassNavItem>[
    GlassNavItem(icon: Icons.route_outlined, activeIcon: Icons.route_rounded, label: "Trips"),
    GlassNavItem(icon: Icons.qr_code_outlined, activeIcon: Icons.qr_code_rounded, label: "My QR"),
    GlassNavItem(
        icon: Icons.chat_bubble_outline_rounded,
        activeIcon: Icons.chat_bubble_rounded,
        label: "Chats"),
    GlassNavItem(
        icon: Icons.assignment_outlined, activeIcon: Icons.assignment_rounded, label: "Forms"),
    GlassNavItem(icon: Icons.person_outline, activeIcon: Icons.person_rounded, label: "Profile"),
  ];

  @override
  Widget build(BuildContext context) {
    return GlassNavScaffold(
      pages: _pages,
      items: _navItems,
      currentIndex: _selectedIndex,
      onTap: (i) => setState(() => _selectedIndex = i),
      banner: _buildEmergencyBanner(),
      floatingAction: GlassEmergencyButton(onPressed: _showEmergencyButton),
    );
  }
}

class StudentTripsTab extends StatelessWidget {
  const StudentTripsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final String myUid = FirebaseAuth.instance.currentUser!.uid;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        titleSpacing: 24,
        title: const Text(
          "My Trips",
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22, color: AppTheme.secondaryColor),
        ),
        actions: const [NotificationBell(), SizedBox(width: 8)],
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: TripQueries.mine(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary));
          }

          final myTrips = snapshot.data!.docs.where((doc) {
            final data = doc.data();
            // Completed trips are filtered here rather than in the query — a
            // second filter beside the membership one would need an index.
            if (data['status'] == 'completed') return false;
            final buses = asList(data['buses']);
            for (var bus in buses) {
              final List passengers = asList(bus['passengers']);
              for (var p in passengers) {
                if (p['id'] == myUid) return true;
              }
            }
            return false;
          }).toList();

          if (myTrips.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.route_outlined, size: 64, color: Colors.grey.shade300),
                  const SizedBox(height: 16),
                  Text("No trips assigned",
                      style: TextStyle(fontSize: 16, color: Colors.grey.shade500, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  Text("Your teacher will assign you to a trip.",
                      style: TextStyle(fontSize: 13, color: Colors.grey.shade400)),
                ],
              ),
            );
          }

          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, GlassNavScaffold.bottomInset),
            itemCount: myTrips.length,
            itemBuilder: (context, index) {
              final doc = myTrips[index];
              final data = doc.data();
              final status = data['status'] ?? 'pending';

              return GestureDetector(
                onTap: () => Navigator.push(context, MaterialPageRoute(
                  builder: (_) => StudentTripDetails(tripId: doc.id, tripData: data, myUid: myUid),
                )),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 14),
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 4))],
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(Icons.directions_bus_rounded, color: AppTheme.effectivePrimary, size: 24),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              data['title'] ?? 'Untitled Trip',
                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: AppTheme.secondaryColor),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(Icons.calendar_today_outlined, size: 12, color: Colors.grey.shade500),
                                const SizedBox(width: 4),
                                Text(data['date'] ?? '', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                              ],
                            ),
                          ],
                        ),
                      ),
                      _StatusChip(status: status),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final Color bg;
    final Color fg;
    final String label;

    switch (status) {
      case 'in_progress':
        bg = Colors.green.shade50;
        fg = Colors.green.shade700;
        label = 'Active';
        break;
      default:
        bg = AppTheme.effectivePrimary.withValues(alpha: 0.1);
        fg = AppTheme.effectivePrimary;
        label = 'Upcoming';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(20)),
      child: Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: fg)),
    );
  }
}

class StudentTripDetails extends StatefulWidget {
  final String tripId;
  final Map<String, dynamic> tripData;
  final String myUid;

  const StudentTripDetails({super.key, required this.tripId, required this.tripData, required this.myUid});

  @override
  State<StudentTripDetails> createState() => _StudentTripDetailsState();
}

class _StudentTripDetailsState extends State<StudentTripDetails>
    with TickerProviderStateMixin {
  GoogleMapController? _mapController;
  final Map<String, BitmapDescriptor> _customMarkers = {};
  final Map<String, Map<String, dynamic>> _peopleInfo = {};
  StreamSubscription<Position>? _positionStream;
  StreamSubscription? _connectivityStream;
  Timer? _heartbeatTimer;
  Position? _lastKnownPos;
  final Battery _battery = Battery();
  late final LiveTracker _tracker = LiveTracker(vsync: this);


  @override
  void initState() {
    super.initState();
    _startLocationUpdates();
    _startNetworkUpdates();
  }

  void _startNetworkUpdates() {
    _connectivityStream = Connectivity().onConnectivityChanged.listen((result) async {
      int batteryLevel = await _battery.batteryLevel;
      String netStatus = "Offline";
      String resStr = result.toString().toLowerCase();
      if (resStr.contains('mobile') || resStr.contains('cellular')) {
        netStatus = "Mobile Data";
      } else if (resStr.contains('wifi')) {
        netStatus = "WiFi Active";
      }
      FirebaseFirestore.instance.collection('locations').doc(widget.myUid).set({
        'battery': batteryLevel,
        'lastActivity': netStatus,
        'lastUpdate': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    });
  }

  Future<void> _zoomToMe() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      _mapController?.animateCamera(
        CameraUpdate.newLatLngZoom(LatLng(pos.latitude, pos.longitude), 17),
      );
    } catch (_) {}
  }

  void _startLocationUpdates() async {
    try {
      Position initialPos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      );
      _lastKnownPos = initialPos;
      await _sendDataToDatabase(initialPos);
    } catch (e) {
      debugPrint("Initial location error: $e");
    }
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
      ),
    ).listen(
      (Position pos) {
        _lastKnownPos = pos;
        _sendDataToDatabase(pos);
      },
      onError: (e) => debugPrint("GPS stream error (student trip): $e"),
      cancelOnError: false,
    );
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      Position? pos = _lastKnownPos;
      if (pos == null) {
        try { pos = await Geolocator.getLastKnownPosition(); } catch (_) {}
      }
      if (pos != null) _sendDataToDatabase(pos);
    });
  }

  Future<void> _sendDataToDatabase(Position pos) async {
    int batteryLevel = 0;
    try { batteryLevel = await _battery.batteryLevel; } catch (_) {}
    String netStatus = "Offline";
    try {
      var connectivityResult = await Connectivity().checkConnectivity();
      String resStr = connectivityResult.toString().toLowerCase();
      if (resStr.contains('mobile') || resStr.contains('cellular')) {
        netStatus = "Mobile Data";
      } else if (resStr.contains('wifi')) {
        netStatus = "WiFi Active";
      }
    } catch (_) {}
    try {
      await FirebaseFirestore.instance.collection('locations').doc(widget.myUid).set({
        'lat': pos.latitude,
        'lng': pos.longitude,
        'battery': batteryLevel,
        'lastActivity': netStatus,
        'lastUpdate': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint("Firestore write error (student trip): $e");
    }
  }


  void _loadMarker(String id, String name, Color color) async {
    if (!_customMarkers.containsKey(id)) {
      BitmapDescriptor icon = await MarkerGenerator.createCustomMarker(name, color);
      if (mounted) setState(() => _customMarkers[id] = icon);
    }
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    _positionStream?.cancel();
    _connectivityStream?.cancel();
    _tracker.dispose();
    super.dispose();
  }

  void _showPeopleSheet(BuildContext context, List<Map<String, dynamic>> people) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.6,
        minChildSize: 0.3,
        maxChildSize: 0.9,
        expand: false,
        builder: (ctx, scrollController) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              Container(
                margin: const EdgeInsets.symmetric(vertical: 12),
                width: 40, height: 4,
                decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(10)),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text("People on the bus",
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.secondaryColor)),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text("${people.length} tracked",
                          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.effectivePrimary)),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView.separated(
                  controller: scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: people.length,
                  separatorBuilder: (_, __) => Divider(color: Colors.grey.shade100, height: 1),
                  itemBuilder: (c, index) {
                    final person = people[index];
                    final bool isMe = person['uid'] == widget.myUid ||
                        person['id'] == widget.myUid;
                    final bool isTeacher = person['role'] == 'teacher';
                    final Color avatarColor = isMe
                        ? Colors.green
                        : (isTeacher ? Colors.red : AppTheme.effectivePrimary);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        children: [
                          CircleAvatar(
                            radius: 22,
                            backgroundColor: avatarColor.withValues(alpha: 0.12),
                            child: Text(
                              (person['name']?.toString() ?? '?')[0].toUpperCase(),
                              style: TextStyle(color: avatarColor, fontWeight: FontWeight.bold, fontSize: 16),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isMe ? "${person['name']} (You)" : (person['name']?.toString() ?? ''),
                                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: AppTheme.secondaryColor),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  (person['role']?.toString() ?? '').toUpperCase(),
                                  style: TextStyle(fontSize: 10, color: Colors.grey.shade500, letterSpacing: 0.5),
                                ),
                              ],
                            ),
                          ),
                          if (isTeacher)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: Colors.red.shade50,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Text("Teacher",
                                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.red.shade600)),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance.collection('trips').doc(widget.tripId).snapshots(),
      builder: (context, tripSnap) {
        if (!tripSnap.hasData) {
          return Scaffold(body: Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary)));
        }

        final currentTripData = tripSnap.data!.data() as Map<String, dynamic>;

        final List buses = asList(currentTripData['buses']);
        final List<String> visibleUserIds = [widget.myUid];

        // Locate the student's own bus + seat number.
        Map<String, dynamic>? myBus;
        int? mySeat;
        bool myQrScanned = false;
        for (final bus in buses) {
          final List passengers = asList(bus['passengers']);
          for (var p in passengers) {
            if (p['id'] == widget.myUid) {
              myBus = Map<String, dynamic>.from(bus as Map);
              final dynamic seat = p['seatNumber'];
              mySeat = seat is int
                  ? seat
                  : (seat is String ? int.tryParse(seat) : null);
              final att = p['attendance'];
              if (att is Map && att.values.any((v) => v == true)) myQrScanned = true;
              break;
            }
          }
          if (myBus != null) {
            // Teachers only visible after the student themselves has been scanned.
            if (myQrScanned) {
              if (bus['mainTeacher'] != null) visibleUserIds.add(bus['mainTeacher']['id']);
              if (bus['coTeacher'] != null) visibleUserIds.add(bus['coTeacher']['id']);
            }
            // Other students only visible once THEY have been scanned.
            for (var p in passengers) {
              if (p is! Map) continue;
              if (p['id'] == widget.myUid) continue; // already added above
              final att = p['attendance'];
              if (att is Map && att.values.any((v) => v == true)) {
                visibleUserIds.add(p['id'].toString());
              }
            }
            break;
          }
        }

        final String busLabel = myBus?['busLabel']?.toString() ??
            myBus?['busNo']?.toString() ??
            '--';

        return Scaffold(
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            backgroundColor: Colors.white.withValues(alpha: 0.95),
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: AppTheme.secondaryColor),
              onPressed: () => Navigator.pop(context),
            ),
            title: Text(
              currentTripData['title'] ?? 'Live Map',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: AppTheme.secondaryColor),
            ),
          ),
          body: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance
                .collection('locations')
                .where(FieldPath.documentId, whereIn: visibleUserIds)
                .snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary));
              }

              // Build name/role cache from trip data — avoids streaming users.
              final Map<String, Map<String, String>> nameCache = {};
              for (final bus in asList(currentTripData['buses'])) {
                if (bus is! Map) continue;
                for (final key in ['mainTeacher', 'coTeacher']) {
                  final t = bus[key];
                  if (t is Map && t['id'] != null) {
                    nameCache[t['id'].toString()] = {'name': t['name']?.toString() ?? '', 'role': 'teacher'};
                  }
                }
                for (final p in asList(bus['passengers'])) {
                  if (p is Map && p['id'] != null) {
                    nameCache[p['id'].toString()] = {'name': p['name']?.toString() ?? '', 'role': 'student'};
                  }
                }
              }

              List<Map<String, dynamic>> peopleList = [];
              final Map<String, LatLng> targets = {};

              for (var doc in snapshot.data!.docs) {
                final locData = doc.data() as Map<String, dynamic>;
                final profile = nameCache[doc.id] ?? _peopleInfo[doc.id] ?? {};
                final data = {...profile, ...locData};
                peopleList.add(data);
                _peopleInfo[doc.id] = data;
                if (locData['lat'] is num && locData['lng'] is num) {
                  final bool isMe = doc.id == widget.myUid;
                  final String role = profile['role'] ?? '';
                  final Color markerColor = isMe
                      ? Colors.green
                      : (role == 'teacher' ? Colors.red : AppTheme.effectivePrimary);
                  _loadMarker(doc.id, profile['name'] ?? '', markerColor);
                  targets[doc.id] = LatLng(
                    (locData['lat'] as num).toDouble(),
                    (locData['lng'] as num).toDouble(),
                  );
                }
              }
              // Hand the latest target positions to the tracker. It will tween
              // each marker smoothly from its current displayed position to the
              // new target over ~1.5s instead of teleporting.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _tracker.setTargets(targets);
              });

              Set<Circle> circles = {};
              int activeStop = currentTripData['activeStopIndex'] ?? -1;
              String activeStopName = "Waiting for teacher to start...";
              if (activeStop != -1) {
                var stopsList = currentTripData['stops'] as List?;
                if (stopsList != null && activeStop < stopsList.length) {
                  var stop = stopsList[activeStop];
                  activeStopName = stop['name'] ?? 'Destination ${activeStop + 1}';
                  circles.add(Circle(
                    circleId: const CircleId("geofence"),
                    center: LatLng(stop['lat'], stop['lng']),
                    radius: (stop['geofenceRadius'] as num).toDouble(),
                    fillColor: AppTheme.effectivePrimary.withValues(alpha: 0.15),
                    strokeColor: AppTheme.effectivePrimary,
                    strokeWidth: 2,
                  ));
                }
              }

              return Stack(
                children: [
                  AnimatedBuilder(
                    animation: _tracker,
                    builder: (ctx, _) {
                      // Build a *fresh* Set<Marker> every frame using the
                      // tracker's interpolated positions. Always passing a new
                      // Set instance is what lets the GoogleMap diff and update
                      // marker positions reliably.
                      final Set<Marker> markers = {};
                      for (final entry in _peopleInfo.entries) {
                        final uid = entry.key;
                        final data = entry.value;
                        // Own marker: use local GPS directly — no Firestore round-trip, zero lag.
                        final LatLng? pos = (uid == widget.myUid && _lastKnownPos != null)
                            ? LatLng(_lastKnownPos!.latitude, _lastKnownPos!.longitude)
                            : _tracker.current(uid);
                        if (pos == null) continue;
                        final bool isMe = uid == widget.myUid;
                        markers.add(Marker(
                          markerId: MarkerId(uid),
                          position: pos,
                          infoWindow: InfoWindow(
                              title: isMe ? "Me" : (data['name']?.toString() ?? '')),
                          icon: _customMarkers[uid] ?? BitmapDescriptor.defaultMarker,
                          flat: true,
                          anchor: const Offset(0.5, 0.5),
                        ));
                      }
                      return GoogleMap(
                        initialCameraPosition: const CameraPosition(
                            target: LatLng(14.9543, 120.9008), zoom: 15),
                        markers: markers,
                        circles: circles,
                        myLocationEnabled: true,
                        myLocationButtonEnabled: false,
                        onMapCreated: (c) {
                          _mapController = c;
                          // Auto-zoom to the student on open (parity with the
                          // teacher live map).
                          _zoomToMe();
                        },
                      );
                    },
                  ),
                  DraggableScrollableSheet(
                    initialChildSize: 0.4,
                    minChildSize: 0.18,
                    maxChildSize: 0.9,
                    builder: (context, scrollController) {
                      final List stops = (currentTripData['stops'] as List?) ?? const [];
                      return Container(
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                          boxShadow: [BoxShadow(blurRadius: 20, color: Colors.black26)],
                        ),
                        child: ListView(
                          controller: scrollController,
                          padding: EdgeInsets.zero,
                          children: [
                            Center(
                              child: Container(
                                margin: const EdgeInsets.symmetric(vertical: 12),
                                width: 40, height: 4,
                                decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(10)),
                              ),
                            ),

                            // Current destination
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  color: AppTheme.effectivePrimary.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: AppTheme.effectivePrimary.withValues(alpha: 0.2)),
                                ),
                                child: Row(
                                  children: [
                                    Icon(Icons.place, color: AppTheme.effectivePrimary, size: 24),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text("Current Destination",
                                              style: TextStyle(fontSize: 11, color: AppTheme.effectivePrimary, fontWeight: FontWeight.w600)),
                                          Text(activeStopName,
                                              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.secondaryColor)),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            // Bus + Seat info
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: _StudentInfoTile(
                                      icon: Icons.directions_bus_rounded,
                                      label: "Bus",
                                      value: busLabel,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: _StudentInfoTile(
                                      icon: Icons.event_seat_outlined,
                                      label: "Seat",
                                      value: mySeat?.toString() ?? "Any",
                                    ),
                                  ),
                                ],
                              ),
                            ),

                            // People action button
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 18),
                              child: SizedBox(
                                width: double.infinity,
                                child: OutlinedButton.icon(
                                  icon: Icon(Icons.people_alt_outlined, size: 18),
                                  label: Text("People (${peopleList.length})"),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: AppTheme.effectivePrimary,
                                    side: BorderSide(color: AppTheme.effectivePrimary.withValues(alpha: 0.4)),
                                    padding: const EdgeInsets.symmetric(vertical: 12),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                  ),
                                  onPressed: () => _showPeopleSheet(context, peopleList),
                                ),
                              ),
                            ),

                            // Itinerary
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text("Itinerary",
                                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.secondaryColor)),
                                  if ((currentTripData['totalDuration'] ?? '').toString().isNotEmpty)
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                        "Total ${currentTripData['totalDuration']}",
                                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.effectivePrimary),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            ...List.generate(stops.length, (i) {
                              final stop = stops[i] as Map;
                              final bool isOrigin = i == 0;
                              final bool isReturn = i == stops.length - 1 &&
                                  (stop['name']?.toString() ?? '').contains("Return");
                              final bool isActive = i == activeStop;
                              return Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 32, height: 32,
                                      decoration: BoxDecoration(
                                        color: isActive
                                            ? AppTheme.effectivePrimary
                                            : (isOrigin || isReturn ? Colors.green.shade100 : Colors.grey.shade100),
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(
                                        isOrigin
                                            ? Icons.school
                                            : (isReturn ? Icons.home_work : Icons.location_on),
                                        size: 16,
                                        color: isActive
                                            ? Colors.white
                                            : (isOrigin || isReturn ? Colors.green.shade700 : Colors.grey.shade600),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            stop['name']?.toString() ?? 'Stop ${i + 1}',
                                            style: TextStyle(
                                              fontWeight: isActive ? FontWeight.bold : FontWeight.w600,
                                              color: isActive ? AppTheme.effectivePrimary : AppTheme.secondaryColor,
                                            ),
                                          ),
                                          Row(
                                            children: [
                                              Text(stop['time']?.toString() ?? '',
                                                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                                              if ((stop['etaFromPrev'] ?? '').toString().isNotEmpty) ...[
                                                const SizedBox(width: 8),
                                                Container(
                                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                                                  decoration: BoxDecoration(
                                                    color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                                                    borderRadius: BorderRadius.circular(6),
                                                  ),
                                                  child: Text(
                                                    "ETA ${stop['etaFromPrev']}",
                                                    style: TextStyle(
                                                      fontSize: 10,
                                                      fontWeight: FontWeight.w600,
                                                      color: AppTheme.effectivePrimary,
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (isActive)
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                        decoration: BoxDecoration(
                                          color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: Text("Current",
                                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: AppTheme.effectivePrimary)),
                                      ),
                                  ],
                                ),
                              );
                            }),
                            const SizedBox(height: 24),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }
}

// â"€â"€ Static identity QR â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€
String _computeStudentCode(String name, String lrn) {
  final initials = name
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .map((w) => w[0].toUpperCase())
      .join();
  final suffix = lrn.length >= 6 ? lrn.substring(lrn.length - 6) : lrn;
  return '$initials-$suffix';
}

class StudentQRTab extends StatelessWidget {
  const StudentQRTab({super.key});

  @override
  Widget build(BuildContext context) {
    final String myUid = FirebaseAuth.instance.currentUser!.uid;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        titleSpacing: 24,
        title: Text(
          "My QR Code",
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22, color: AppTheme.secondaryColor),
        ),
      ),
      body: FutureBuilder<DocumentSnapshot>(
        future: FirebaseFirestore.instance.collection('users').doc(myUid).get(),
        builder: (context, snap) {
          if (!snap.hasData) {
            return Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary));
          }
          final data = snap.data!.data() as Map<String, dynamic>? ?? {};
          final String name = (data['name'] ?? '').toString();
          final String lrn  = (data['lrn']  ?? '').toString();
          final String code = _computeStudentCode(name, lrn);
          // Persist computed code so parents can look up by it.
          if ((data['code'] ?? '') != code && code.isNotEmpty) {
            FirebaseFirestore.instance.collection('users').doc(myUid).update({'code': code});
          }
          final String qrJson = jsonEncode({
            'studentId': myUid,
            'name': name,
            'lrn': lrn,
            'code': code,
          });

          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    name.isEmpty ? 'Student' : name,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.secondaryColor),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    "LRN: ${lrn.isEmpty ? '--' : lrn}",
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade500),
                  ),
                  const SizedBox(height: 28),
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 24, offset: const Offset(0, 8))],
                    ),
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            border: Border.all(color: AppTheme.effectivePrimary.withValues(alpha: 0.2), width: 2),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: QrImageView(
                            data: qrJson,
                            version: QrVersions.auto,
                            size: 220,
                            backgroundColor: Colors.white,
                            eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black),
                            dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Colors.black),
                          ),
                        ),
                        const SizedBox(height: 20),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                          decoration: BoxDecoration(
                            color: AppTheme.effectivePrimary.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            "Code: $code",
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.effectivePrimary,
                              letterSpacing: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.orange.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: Colors.orange.withValues(alpha: 0.2)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.info_outline_rounded, size: 14, color: Colors.orange.shade700),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            "Show this code to your parent if camera is unavailable",
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 12, color: Colors.orange.shade700, fontWeight: FontWeight.w500),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class EmergencyButtonDialog extends StatefulWidget {
  const EmergencyButtonDialog({super.key});

  @override
  State<EmergencyButtonDialog> createState() => _EmergencyButtonDialogState();
}

class _EmergencyButtonDialogState extends State<EmergencyButtonDialog> {
  bool _isHolding = false;
  double _progress = 0.0;
  Timer? _holdTimer;
  bool _isSending = false;

  void _startHold() {
    setState(() {
      _isHolding = true;
      _progress = 0.0;
    });

    _holdTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
      setState(() {
        _progress += 0.05 / 3.0;
        if (_progress >= 1.0) {
          _holdTimer?.cancel();
          _sendEmergency();
        }
      });
    });
  }

  void _cancelHold() {
    _holdTimer?.cancel();
    setState(() {
      _isHolding = false;
      _progress = 0.0;
    });
  }

  Future<void> _sendEmergency() async {
    setState(() => _isSending = true);
    final String myUid = FirebaseAuth.instance.currentUser!.uid;

    try {
      final userDoc = await FirebaseFirestore.instance.collection('users').doc(myUid).get();
      final userData = userDoc.data() as Map<String, dynamic>;
      final locDoc = await FirebaseFirestore.instance.collection('locations').doc(myUid).get();

      final tripsSnapshot = await TripQueries.mineOnce();
      if (tripsSnapshot == null) return;

      String? teacherId;
      String? tripId;

      for (var doc in tripsSnapshot.docs) {
        final data = doc.data();
        if (data['status'] != 'in_progress') continue;
        final buses = asList(data['buses']);
        for (var bus in buses) {
          final List passengers = asList(bus['passengers']);
          for (var p in passengers) {
            if (p['id'] == myUid) {
              teacherId = bus['mainTeacher']?['id'];
              tripId = doc.id;
              break;
            }
          }
          if (teacherId != null) break;
        }
        if (teacherId != null) break;
      }

      if (teacherId == null) {
        if (!mounted) return;
        Navigator.pop(context);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("No active trip found"), backgroundColor: Colors.orange),
        );
        return;
      }

      await FirebaseFirestore.instance.collection('emergencies').add({
        'studentId': myUid,
        'studentName': userData['name'],
        'teacherId': teacherId,
        'tripId': tripId,
        'lat': locDoc.data()?['lat'],
        'lng': locDoc.data()?['lng'],
        'status': 'pending',
        'timestamp': FieldValue.serverTimestamp(),
      });

      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Emergency alert sent to teacher!"), backgroundColor: Colors.green),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red),
      );
    }
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 64),
            const SizedBox(height: 16),
            const Text(
              "Emergency Alert",
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.red),
            ),
            const SizedBox(height: 8),
            Text(
              "Hold the button for 3 seconds\nto send emergency alert",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.grey.shade600),
            ),
            const SizedBox(height: 32),
            GestureDetector(
              onTapDown: (_) => _startHold(),
              onTapUp: (_) => _cancelHold(),
              onTapCancel: _cancelHold,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 140,
                    height: 140,
                    child: CircularProgressIndicator(
                      value: _progress,
                      strokeWidth: 8,
                      backgroundColor: Colors.red.shade100,
                      valueColor: const AlwaysStoppedAnimation<Color>(Colors.red),
                    ),
                  ),
                  Container(
                    width: 120,
                    height: 120,
                    decoration: BoxDecoration(
                      color: _isHolding ? Colors.red.shade700 : Colors.red,
                      shape: BoxShape.circle,
                    ),
                    child: _isSending
                        ? const CircularProgressIndicator(color: Colors.white)
                        : const Icon(Icons.emergency, color: Colors.white, size: 48),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text("Cancel"),
            ),
          ],
        ),
      ),
    );
  }
}

class StudentProfileTab extends StatelessWidget {
  const StudentProfileTab({super.key});

  @override
  Widget build(BuildContext context) {
    final String uid = FirebaseAuth.instance.currentUser!.uid;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        titleSpacing: 24,
        title: const Text(
          "Profile",
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22, color: AppTheme.secondaryColor),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: IconButton(
              tooltip: "Logout",
              icon: const Icon(Icons.logout_rounded, color: Colors.red, size: 22),
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    title: const Text("Log out?"),
                    content: const Text("You'll need to sign in again to view your trips."),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text("Log out", style: TextStyle(color: Colors.red)),
                      ),
                    ],
                  ),
                );
                if (confirm == true) {
                  await AuthController().logout();
                  if (!context.mounted) return;
                  Navigator.pushAndRemoveUntil(
                    context,
                    MaterialPageRoute(builder: (_) => const MobileLoginView()),
                    (r) => false,
                  );
                }
              },
            ),
          ),
        ],
      ),
      body: FutureBuilder<DocumentSnapshot>(
        future: FirebaseFirestore.instance.collection('users').doc(uid).get(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary));
          }

          final data = snapshot.data!.data() as Map<String, dynamic>;
          final String name = data['name'] ?? 'Student';
          final String lrn = data['lrn'] ?? 'N/A';

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
            child: Column(
              children: [
                CircleAvatar(
                  radius: 44,
                  backgroundColor: AppTheme.effectivePrimary.withValues(alpha: 0.12),
                  child: Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: AppTheme.effectivePrimary),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  name,
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.secondaryColor),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    "Student",
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.effectivePrimary),
                  ),
                ),

                const SizedBox(height: 28),

                _ProfileInfoCard(
                  icon: Icons.person_outline_rounded,
                  label: "Full Name",
                  value: name,
                ),
                const SizedBox(height: 12),
                _ProfileInfoCard(
                  icon: Icons.badge_outlined,
                  label: "LRN",
                  value: lrn,
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const SettingsView(allowEmergencySoundUpload: false),
                      ),
                    ),
                    icon: Icon(Icons.settings_outlined),
                    label: Text("Settings"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.effectivePrimary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _StudentInfoTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _StudentInfoTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          Container(
            width: 36, height: 36,
            decoration: BoxDecoration(
              color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: AppTheme.effectivePrimary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: TextStyle(
                        fontSize: 10,
                        color: Colors.grey.shade500,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.3)),
                const SizedBox(height: 2),
                Text(value,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.secondaryColor)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileInfoCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;

  const _ProfileInfoCard({required this.icon, required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 4))],
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 20, color: AppTheme.effectivePrimary),
          ),
          const SizedBox(width: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: TextStyle(fontSize: 11, color: Colors.grey.shade500, fontWeight: FontWeight.w500)),
              const SizedBox(height: 2),
              Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.secondaryColor)),
            ],
          ),
        ],
      ),
    );
  }
}
