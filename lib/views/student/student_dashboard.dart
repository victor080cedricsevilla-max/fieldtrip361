import 'dart:async';
import 'dart:ui' as ui;
import 'package:cloud_functions/cloud_functions.dart';
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
import '../../controllers/auth_controller.dart';
import '../../utils/live_tracker.dart';
import '../auth/mobile_login_view.dart';
import '../shared/settings_view.dart';
import '../shared/chat_view.dart';

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
  String? _watchedTripId;

  @override
  void initState() {
    super.initState();
    _pages = [
      const StudentTripsTab(),
      const StudentQRTab(),
      const ChatListView(),
      const StudentProfileTab(),
    ];
    _requestLocationPermission();
    _listenForGeofenceAlerts();
  }

  void _listenForGeofenceAlerts() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    _geofenceTripSub = FirebaseFirestore.instance
        .collection('trips')
        .where('status', isEqualTo: 'in_progress')
        .snapshots()
        .listen((snap) {
      String? newTripId;
      outer:
      for (final doc in snap.docs) {
        final buses = (doc.data()['buses'] as List?) ?? [];
        for (final b in buses) {
          if (b is Map) {
            for (final p in (b['passengers'] as List? ?? const [])) {
              if (p is Map && p['id'] == uid) {
                newTripId = doc.id;
                break outer;
              }
            }
          }
        }
      }

      if (newTripId == _watchedTripId) return;
      _watchedTripId = newTripId;
      _geofenceAlertSub?.cancel();

      if (newTripId == null) return;
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
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Row(
                  children: [
                    Icon(Icons.location_off_rounded, color: Colors.white),
                    SizedBox(width: 10),
                    Expanded(child: Text('⚠️ You have left the designated area! Return to the group immediately.')),
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

  @override
  void dispose() {
    _geofenceTripSub?.cancel();
    _geofenceAlertSub?.cancel();
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

  Widget _buildLinkRequestBanner() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const SizedBox.shrink();
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('linkRequests')
          .where('studentId', isEqualTo: uid)
          .where('status', isEqualTo: 'pending')
          .snapshots(),
      builder: (context, snap) {
        if (!snap.hasData || snap.data!.docs.isEmpty) return const SizedBox.shrink();
        final doc = snap.data!.docs.first;
        final parentName = (doc['parentName'] ?? 'A parent').toString();
        return SafeArea(
          bottom: false,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            color: AppTheme.primaryColor,
            child: Row(
              children: [
                const Icon(Icons.family_restroom, color: Colors.white, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    "$parentName wants to link as your parent.",
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                ),
                TextButton(
                  onPressed: () => _handleLinkRequest(doc.id, false),
                  style: TextButton.styleFrom(foregroundColor: Colors.white70, padding: EdgeInsets.zero, minimumSize: Size.zero, tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  child: const Text("Deny", style: TextStyle(fontSize: 12)),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: () => _handleLinkRequest(doc.id, true),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: AppTheme.primaryColor,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                  ),
                  child: const Text("Approve"),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Future<void> _handleLinkRequest(String requestId, bool approve) async {
    try {
      if (approve) {
        await FirebaseFunctions.instance
            .httpsCallable('approveLinkRequest')
            .call({'requestId': requestId});
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Parent linked successfully.'), backgroundColor: Colors.green),
          );
        }
      } else {
        await FirebaseFirestore.instance
            .collection('linkRequests')
            .doc(requestId)
            .update({'status': 'rejected'});
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Request denied.'), backgroundColor: Colors.orange),
          );
        }
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Something went wrong. Try again.'), backgroundColor: Colors.red),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _buildEmergencyBanner(),
          _buildLinkRequestBanner(),
          Expanded(child: _pages[_selectedIndex]),
        ],
      ),
      floatingActionButton: Padding(
        padding: const EdgeInsets.only(bottom: 1.0),
        child: FloatingActionButton(
          onPressed: _showEmergencyButton,
          backgroundColor: Colors.red,
          child: const Icon(Icons.emergency, color: Colors.white, size: 32),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.centerFloat,
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 16, offset: const Offset(0, -4))],
        ),
        child: NavigationBar(
          selectedIndex: _selectedIndex,
          onDestinationSelected: (i) => setState(() => _selectedIndex = i),
          backgroundColor: Colors.white,
          indicatorColor: AppTheme.primaryColor.withValues(alpha: 0.12),
          elevation: 0,
          labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
          height: 70,
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.route_outlined),
              selectedIcon: Icon(Icons.route, color: AppTheme.primaryColor),
              label: "Trips",
            ),
            NavigationDestination(
              icon: Icon(Icons.qr_code_outlined),
              selectedIcon: Icon(Icons.qr_code, color: AppTheme.primaryColor),
              label: "My QR",
            ),
            NavigationDestination(
              icon: Icon(Icons.chat_bubble_outline_rounded),
              selectedIcon: Icon(Icons.chat_bubble_rounded, color: AppTheme.primaryColor),
              label: "Chats",
            ),
            NavigationDestination(
              icon: Icon(Icons.person_outline),
              selectedIcon: Icon(Icons.person, color: AppTheme.primaryColor),
              label: "Profile",
            ),
          ],
        ),
      ),
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
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('trips')
            .where('status', isNotEqualTo: 'completed')
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
          }

          final myTrips = snapshot.data!.docs.where((doc) {
            final data = doc.data() as Map<String, dynamic>;
            final buses = data['buses'] as List<dynamic>? ?? [];
            for (var bus in buses) {
              List passengers = bus['passengers'] ?? [];
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
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            itemCount: myTrips.length,
            itemBuilder: (context, index) {
              final doc = myTrips[index];
              final data = doc.data() as Map<String, dynamic>;
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
                          color: AppTheme.primaryColor.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.directions_bus_rounded, color: AppTheme.primaryColor, size: 24),
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
        bg = AppTheme.primaryColor.withValues(alpha: 0.1);
        fg = AppTheme.primaryColor;
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

  Map<String, dynamic>? _currentTripData;
  bool _isOutOfBounds = false;

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
      FirebaseFirestore.instance.collection('users').doc(widget.myUid).update({
        'battery': batteryLevel,
        'lastActivity': netStatus,
        'lastUpdate': FieldValue.serverTimestamp(),
      });
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
    // Tight distance filter so small movements (walking) actually emit.
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 3,
      ),
    ).listen((Position pos) {
      _lastKnownPos = pos;
      _sendDataToDatabase(pos);
    });
    // Heartbeat: re-publish the last known position every few seconds so the
    // server sees us as "alive" even when standing still or when the OS
    // throttles getPositionStream. This is what makes the marker continue to
    // update visibly on other devices.
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final pos = _lastKnownPos;
      if (pos != null) _sendDataToDatabase(pos);
    });
  }

  Future<void> _sendDataToDatabase(Position pos) async {
    int batteryLevel = await _battery.batteryLevel;
    var connectivityResult = await Connectivity().checkConnectivity();
    String netStatus = "Offline";
    String resStr = connectivityResult.toString().toLowerCase();
    if (resStr.contains('mobile') || resStr.contains('cellular')) {
      netStatus = "Mobile Data";
    } else if (resStr.contains('wifi')) {
      netStatus = "WiFi Active";
    }
    FirebaseFirestore.instance.collection('users').doc(widget.myUid).update({
      'lat': pos.latitude,
      'lng': pos.longitude,
      'battery': batteryLevel,
      'lastActivity': netStatus,
      'lastUpdate': FieldValue.serverTimestamp(),
    });

    if (_currentTripData != null) {
      int activeStop = _currentTripData!['activeStopIndex'] ?? -1;
      if (activeStop != -1) {
        var stopsList = _currentTripData!['stops'] as List?;
        if (stopsList != null && activeStop < stopsList.length) {
          var stop = stopsList[activeStop];
          double centerLat = (stop['lat'] as num).toDouble();
          double centerLng = (stop['lng'] as num).toDouble();
          double radius = (stop['geofenceRadius'] as num).toDouble();

          double distance = Geolocator.distanceBetween(pos.latitude, pos.longitude, centerLat, centerLng);

          if (distance > radius) {
            if (!_isOutOfBounds) {
              _isOutOfBounds = true;
              FlutterRingtonePlayer().play(
                fromAsset: "assets/audio/alarm.mp3",
                looping: true,
                volume: 1.0,
                asAlarm: true,
              );
              _showOutOfBoundsWarning();
              // Alert write is handled by the background service so we don't
              // create a duplicate Firestore doc here.
            }
          } else {
            if (_isOutOfBounds) {
              _isOutOfBounds = false;
              FlutterRingtonePlayer().stop();
            }
          }
        }
      }
    }
  }

  void _showOutOfBoundsWarning() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 28),
            const SizedBox(width: 8),
            const Text("GEOFENCE WARNING", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        content: const Text("You left the designated area. Return immediately.", style: TextStyle(fontSize: 15)),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              FlutterRingtonePlayer().stop();
              Navigator.pop(ctx);
            },
            child: const Text("I Understand", style: TextStyle(color: Colors.white)),
          )
        ]
      )
    );
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
                    const Text("People on the bus",
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.secondaryColor)),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                      decoration: BoxDecoration(
                        color: AppTheme.primaryColor.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text("${people.length} tracked",
                          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.primaryColor)),
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
                        : (isTeacher ? Colors.red : AppTheme.primaryColor);
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
          return const Scaffold(body: Center(child: CircularProgressIndicator(color: AppTheme.primaryColor)));
        }

        final currentTripData = tripSnap.data!.data() as Map<String, dynamic>;
        _currentTripData = currentTripData;

        final List buses = currentTripData['buses'] ?? [];
        final List<String> visibleUserIds = [widget.myUid];

        // Locate the student's own bus + seat number.
        Map<String, dynamic>? myBus;
        int? mySeat;
        for (final bus in buses) {
          List passengers = bus['passengers'] ?? [];
          for (var p in passengers) {
            if (p['id'] == widget.myUid) {
              myBus = Map<String, dynamic>.from(bus as Map);
              final dynamic seat = p['seatNumber'];
              mySeat = seat is int
                  ? seat
                  : (seat is String ? int.tryParse(seat) : null);
              break;
            }
          }
          if (myBus != null) {
            if (bus['mainTeacher'] != null) visibleUserIds.add(bus['mainTeacher']['id']);
            if (bus['coTeacher'] != null) visibleUserIds.add(bus['coTeacher']['id']);
            for (var p in passengers) visibleUserIds.add(p['id']);
            break;
          }
        }

        final String busLabel = myBus?['busLabel']?.toString() ??
            myBus?['busNo']?.toString() ??
            '—';

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
                .collection('users')
                .where(FieldPath.documentId, whereIn: visibleUserIds)
                .snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) {
                return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
              }

              List<Map<String, dynamic>> peopleList = [];
              final Map<String, LatLng> targets = {};

              for (var doc in snapshot.data!.docs) {
                final data = doc.data() as Map<String, dynamic>;
                peopleList.add(data);
                _peopleInfo[doc.id] = data;
                if (data['lat'] is num && data['lng'] is num) {
                  bool isMe = doc.id == widget.myUid;
                  Color markerColor = isMe
                      ? Colors.green
                      : (data['role'] == 'teacher' ? Colors.red : AppTheme.primaryColor);
                  _loadMarker(doc.id, data['name'], markerColor);
                  targets[doc.id] = LatLng(
                    (data['lat'] as num).toDouble(),
                    (data['lng'] as num).toDouble(),
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
                    fillColor: AppTheme.primaryColor.withValues(alpha: 0.15),
                    strokeColor: AppTheme.primaryColor,
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
                        final pos = _tracker.current(uid);
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
                                  color: AppTheme.primaryColor.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.2)),
                                ),
                                child: Row(
                                  children: [
                                    const Icon(Icons.place, color: AppTheme.primaryColor, size: 24),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          const Text("Current Destination",
                                              style: TextStyle(fontSize: 11, color: AppTheme.primaryColor, fontWeight: FontWeight.w600)),
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
                                  icon: const Icon(Icons.people_alt_outlined, size: 18),
                                  label: Text("People (${peopleList.length})"),
                                  style: OutlinedButton.styleFrom(
                                    foregroundColor: AppTheme.primaryColor,
                                    side: BorderSide(color: AppTheme.primaryColor.withValues(alpha: 0.4)),
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
                                        color: AppTheme.primaryColor.withValues(alpha: 0.1),
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                      child: Text(
                                        "Total ${currentTripData['totalDuration']}",
                                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.primaryColor),
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
                                            ? AppTheme.primaryColor
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
                                              color: isActive ? AppTheme.primaryColor : AppTheme.secondaryColor,
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
                                                    color: AppTheme.primaryColor.withValues(alpha: 0.1),
                                                    borderRadius: BorderRadius.circular(6),
                                                  ),
                                                  child: Text(
                                                    "ETA ${stop['etaFromPrev']}",
                                                    style: const TextStyle(
                                                      fontSize: 10,
                                                      fontWeight: FontWeight.w600,
                                                      color: AppTheme.primaryColor,
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
                                          color: AppTheme.primaryColor.withValues(alpha: 0.1),
                                          borderRadius: BorderRadius.circular(10),
                                        ),
                                        child: const Text("Current",
                                            style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: AppTheme.primaryColor)),
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

class StudentQRTab extends StatefulWidget {
  const StudentQRTab({super.key});

  @override
  State<StudentQRTab> createState() => _StudentQRTabState();
}

class _StudentQRTabState extends State<StudentQRTab> {
  final String myUid = FirebaseAuth.instance.currentUser!.uid;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        titleSpacing: 24,
        title: const Text(
          "My QR Code",
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22, color: AppTheme.secondaryColor),
        ),
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('trips')
            .where('status', isEqualTo: 'in_progress')
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
          }

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const _LockedQRView(message: "You have no active trips running right now.");
          }

          Map<String, dynamic>? myActiveTrip;
          String? myActiveTripId;

          for (var doc in snapshot.data!.docs) {
            final data = doc.data() as Map<String, dynamic>;

            bool isMyTrip = false;
            List buses = data['buses'] ?? [];
            for (var bus in buses) {
              List passengers = bus['passengers'] ?? [];
              for (var p in passengers) {
                if (p['id'] == myUid) {
                  isMyTrip = true;
                  break;
                }
              }
              if (isMyTrip) break;
            }

            if (isMyTrip) {
              int currentActive = data['activeStopIndex'] ?? -1;
              if (currentActive != -1) {
                myActiveTrip = data;
                myActiveTripId = doc.id;
                break;
              } else {
                myActiveTrip ??= data;
                myActiveTripId ??= doc.id;
              }
            }
          }

          if (myActiveTrip == null || myActiveTripId == null) {
            return const _LockedQRView(message: "You are not assigned to any currently active trip.");
          }

          int activeStopIndex = myActiveTrip['activeStopIndex'] ?? -1;

          if (activeStopIndex == -1) {
            return const _LockedQRView(message: "Your teacher hasn't started the destination yet.");
          }

          List stopsList = myActiveTrip['stops'] ?? [];
          if (activeStopIndex >= stopsList.length) {
            return const _LockedQRView(message: "Invalid destination index.");
          }

          bool qrEnabled = stopsList[activeStopIndex]['qrEnabled'] == true;

          if (!qrEnabled) {
            return const _LockedQRView(
              message: "QR generation is locked. Wait for your teacher to allow QR for this destination.",
            );
          }

          return _ActiveQRView(tripId: myActiveTripId, stopIndex: activeStopIndex);
        },
      ),
    );
  }
}

class _ActiveQRView extends StatefulWidget {
  final String tripId;
  final int stopIndex;
  const _ActiveQRView({required this.tripId, required this.stopIndex});

  @override
  State<_ActiveQRView> createState() => _ActiveQRViewState();
}

class _ActiveQRViewState extends State<_ActiveQRView> {
  String qrData = "";
  bool _isGenerating = false;
  Timer? _timer;
  static const int _qrInterval = 25;
  int _secondsLeft = _qrInterval;

  @override
  void initState() {
    super.initState();
    _generateQR();
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() {
        _secondsLeft--;
        if (_secondsLeft <= 0) {
          _secondsLeft = _qrInterval;
          _generateQR();
        }
      });
    });
  }

  Future<void> _generateQR() async {
    if (_isGenerating || !mounted) return;
    setState(() => _isGenerating = true);
    try {
      final result = await FirebaseFunctions.instance
          .httpsCallable('generateAttendanceToken')
          .call({'tripId': widget.tripId, 'stopIndex': widget.stopIndex});
      if (mounted) {
        setState(() => qrData = (result.data['tokenId'] as String?) ?? '');
      }
    } catch (_) {
      // Keep showing the last token until the next cycle.
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              "Present to your teacher",
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: AppTheme.secondaryColor),
            ),
            const SizedBox(height: 6),
            Text(
              "Show this QR code to mark your attendance",
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
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
                      border: Border.all(color: AppTheme.primaryColor.withValues(alpha: 0.2), width: 2),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: qrData.isEmpty
                        ? const SizedBox(width: 220, height: 220, child: Center(child: CircularProgressIndicator()))
                        : QrImageView(data: qrData, version: QrVersions.auto, size: 220),
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          value: _secondsLeft / _qrInterval,
                          strokeWidth: 2.5,
                          color: AppTheme.primaryColor,
                          backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.1),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        "Refreshes in $_secondsLeft second${_secondsLeft == 1 ? '' : 's'}",
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade500, fontWeight: FontWeight.w500),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.primaryColor.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.info_outline_rounded, size: 14, color: AppTheme.primaryColor),
                  const SizedBox(width: 6),
                  const Text(
                    "QR auto-refreshes for security",
                    style: TextStyle(fontSize: 12, color: AppTheme.primaryColor, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LockedQRView extends StatelessWidget {
  final String message;
  const _LockedQRView({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: Colors.grey.shade100,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.lock_outline_rounded, size: 40, color: Colors.grey.shade400),
            ),
            const SizedBox(height: 20),
            const Text(
              "QR Locked",
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.secondaryColor),
            ),
            const SizedBox(height: 10),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey.shade500, fontSize: 14, height: 1.5),
            ),
          ],
        ),
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

      final tripsSnapshot = await FirebaseFirestore.instance
          .collection('trips')
          .where('status', isEqualTo: 'in_progress')
          .get();

      String? teacherId;
      String? tripId;

      for (var doc in tripsSnapshot.docs) {
        final data = doc.data();
        final buses = data['buses'] as List<dynamic>? ?? [];
        for (var bus in buses) {
          List passengers = bus['passengers'] ?? [];
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
        'lat': userData['lat'],
        'lng': userData['lng'],
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
            return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
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
                  backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12),
                  child: Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: AppTheme.primaryColor),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  name,
                  style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.secondaryColor),
                ),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text(
                    "Student",
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.primaryColor),
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
                    icon: const Icon(Icons.settings_outlined),
                    label: const Text("Settings"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryColor,
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
              color: AppTheme.primaryColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: AppTheme.primaryColor),
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
              color: AppTheme.primaryColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 20, color: AppTheme.primaryColor),
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