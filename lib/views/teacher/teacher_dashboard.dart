import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_ringtone_player/flutter_ringtone_player.dart';
import 'package:audioplayers/audioplayers.dart';
import '../../config/theme.dart';
import '../../widgets/glass_nav_bar.dart';
import '../../widgets/glass_nav_scaffold.dart';
import '../../controllers/auth_controller.dart';
import '../../utils/chat_sync.dart';
import '../../utils/firestore_utils.dart';
import '../../utils/guardian_service.dart';
import '../../utils/live_tracker.dart';
import '../../utils/trip_queries.dart';
import '../auth/mobile_login_view.dart';
import '../shared/settings_view.dart';
import '../shared/chat_view.dart';
import 'teacher_documents_tab.dart';

/// Shared emergency-sound playback so any teacher screen can stop the alarm
/// regardless of who started it.
AudioPlayer? _sharedAlarmPlayer;

Future<void> _playEmergencyAlarm() async {
  HapticFeedback.heavyImpact();
  String? customUrl;
  try {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid != null) {
      final snap = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      customUrl = snap.data()?['emergencySoundUrl'] as String?;
    }
  } catch (_) {}

  if (customUrl != null && customUrl.isNotEmpty) {
    _sharedAlarmPlayer ??= AudioPlayer();
    await _sharedAlarmPlayer!.setReleaseMode(ReleaseMode.loop);
    await _sharedAlarmPlayer!.setVolume(1.0);
    await _sharedAlarmPlayer!.play(UrlSource(customUrl));
  } else {
    FlutterRingtonePlayer().play(
      fromAsset: "assets/audio/alarm.mp3",
      looping: true,
      volume: 1.0,
      asAlarm: true,
    );
  }
}

Future<void> _stopEmergencySound() async {
  await _sharedAlarmPlayer?.stop();
  await _sharedAlarmPlayer?.dispose();
  _sharedAlarmPlayer = null;
  FlutterRingtonePlayer().stop();
}

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

class TeacherDashboard extends StatefulWidget {
  const TeacherDashboard({super.key});

  @override
  State<TeacherDashboard> createState() => _TeacherDashboardState();
}

class _TeacherDashboardState extends State<TeacherDashboard> {
  int _selectedIndex = 0;
  late final List<Widget> _pages;
  StreamSubscription<QuerySnapshot>? _emergencySubscription;
  StreamSubscription<QuerySnapshot>? _geofenceTripSub;
  final _sosNotifier = ValueNotifier<List<Map<String, dynamic>>>([]);
  bool _sosDialogOpen = false;
  StreamSubscription<QuerySnapshot>? _geofenceAlertSub;
  String? _watchedTripId;
  final Set<String> _activeGeofenceStudents = {};

  @override
  void initState() {
    super.initState();
    _pages = [
      const TeacherTripsTab(),
      const TeacherStudentsTab(),
      const TeacherDocumentsTab(),
      const ChatListView(),
      const TeacherProfileTab(),
    ];
    _requestLocationPermission();
    _listenForEmergencies();
    _listenForGeofenceAlerts();
  }

  void _listenForEmergencies() {
    final String myUid = FirebaseAuth.instance.currentUser!.uid;
    _emergencySubscription = FirebaseFirestore.instance
        .collection('emergencies')
        .where('teacherId', isEqualTo: myUid)
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .listen((snapshot) {
      final newEntries = <Map<String, dynamic>>[];
      for (final change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added) {
          final data = change.doc.data() as Map<String, dynamic>;
          newEntries.add({
            'ref': change.doc.reference,
            'name': (data['studentName'] as String?) ?? 'Student',
          });
        }
      }
      if (newEntries.isEmpty) return;
      _sosNotifier.value = [..._sosNotifier.value, ...newEntries];
      if (!_sosDialogOpen) {
        _sosDialogOpen = true;
        _showConsolidatedSosDialog();
      }
    });
  }

  void _showConsolidatedSosDialog() {
    _playEmergencyAlarm();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ValueListenableBuilder<List<Map<String, dynamic>>>(
        valueListenable: _sosNotifier,
        builder: (_, entries, __) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          backgroundColor: Colors.red.shade50,
          title: Row(
            children: [
              const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 32),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  "SOS ALERT",
                  style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 18),
                ),
              ),
              if (entries.length > 1)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(color: Colors.red, borderRadius: BorderRadius.circular(12)),
                  child: Text('${entries.length}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                ),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entries.length == 1
                      ? '${entries.first['name']} has pressed the emergency button!'
                      : '${entries.length} students need help:',
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                ),
                if (entries.length > 1) ...[
                  const SizedBox(height: 10),
                  ...entries.map((e) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Row(
                      children: [
                        const Icon(Icons.person_rounded, size: 16, color: Colors.red),
                        const SizedBox(width: 8),
                        Text(e['name'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
                      ],
                    ),
                  )),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                for (final e in _sosNotifier.value) {
                  (e['ref'] as DocumentReference).update({'status': 'dismissed'});
                }
                _stopEmergencySound();
                _sosNotifier.value = [];
                Navigator.pop(ctx);
              },
              child: const Text("Dismiss All", style: TextStyle(color: Colors.grey)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () {
                for (final e in _sosNotifier.value) {
                  (e['ref'] as DocumentReference).update({'status': 'accepted'});
                }
                _stopEmergencySound();
                _sosNotifier.value = [];
                Navigator.pop(ctx);
              },
              child: const Text("Accept & Rescue", style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      ),
    ).then((_) {
      _sosDialogOpen = false;
      _sosNotifier.value = [];
    });
  }

  /// Watches in-progress trips for this teacher. When a student leaves the
  /// geofence (a new alert doc is written to trips/{id}/alerts), plays the
  /// alarm and shows a dialog -- regardless of which tab is active.
  void _listenForGeofenceAlerts() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;

    // Scoped to trips this teacher is assigned to; the in_progress check moves
    // into the loop because a second filter would require a composite index.
    _geofenceTripSub = TripQueries.mine().listen((snap) {
      String? newTripId;
      outer:
      for (final doc in snap.docs) {
        if (doc.data()['status'] != 'in_progress') continue;
        final buses = asList(doc.data()['buses']);
        for (final b in buses) {
          if (b is Map) {
            if (b['mainTeacher']?['id'] == uid || b['coTeacher']?['id'] == uid) {
              newTripId = doc.id;
              break outer;
            }
          }
        }
      }

      if (newTripId == _watchedTripId) return;
      _watchedTripId = newTripId;
      _geofenceAlertSub?.cancel();

      if (newTripId == null) return;
      // isFirstSnapshot + seenIds live in the closure so they reset each time
      // we set up a new listener (new tripId). On the very first snapshot
      // Firestore sends ALL existing docs as "added" -- we collect their IDs
      // and skip them. Only truly new docs (added after we started listening)
      // will trigger the alarm.
      bool isFirstSnapshot = true;
      final seenIds = <String>{};
      _geofenceAlertSub = FirebaseFirestore.instance
          .collection('trips')
          .doc(newTripId)
          .collection('alerts')
          .where('status', isEqualTo: 'pending')
          .snapshots()
          .listen((alertSnap) {
        for (final change in alertSnap.docChanges) {
          if (change.type != DocumentChangeType.added) continue;
          if (seenIds.contains(change.doc.id)) continue;
          seenIds.add(change.doc.id);
          final data = change.doc.data() as Map<String, dynamic>;
          // On first snapshot, only alarm for alerts created in the last 10 minutes
          // so the teacher sees alerts they missed while the app was closed, but
          // old resolved alerts from earlier in the trip don't trigger the alarm.
          if (isFirstSnapshot) {
            final ts = data['createdAt'];
            if (ts == null) continue;
            final created = (ts as Timestamp).toDate();
            if (DateTime.now().difference(created).inMinutes > 10) continue;
          }
          _showGeofenceAlert(change.doc.reference, data);
        }
        isFirstSnapshot = false;
      });
    });
  }

  void _showGeofenceAlert(DocumentReference ref, Map<String, dynamic> data) {
    if (!mounted) return;
    final studentId = data['studentId'] as String? ?? ref.id;
    if (_activeGeofenceStudents.contains(studentId)) {
      ref.update({'status': 'acknowledged'});
      return;
    }
    _activeGeofenceStudents.add(studentId);
    _playEmergencyAlarm();
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: Colors.orange.shade50,
        title: const Row(
          children: [
            Icon(Icons.location_off_rounded, color: Colors.orange, size: 28),
            SizedBox(width: 8),
            Text('Geofence Alert', style: TextStyle(color: Colors.orange, fontWeight: FontWeight.bold)),
          ],
        ),
        content: Text(
          '${data['studentName'] ?? 'A student'} has left the designated area!\n'
          'Distance from zone: ${(data['distance'] as num?)?.toStringAsFixed(0) ?? '?'} m',
        ),
        actions: [
          TextButton(
            onPressed: () {
              ref.update({'status': 'dismissed'});
              _stopEmergencySound();
              _activeGeofenceStudents.remove(studentId);
              Navigator.pop(ctx);
            },
            child: const Text('Dismiss'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () {
              ref.update({'status': 'acknowledged'});
              _stopEmergencySound();
              _activeGeofenceStudents.remove(studentId);
              Navigator.pop(ctx);
            },
            child: const Text('Acknowledge', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    ).then((_) => _activeGeofenceStudents.remove(studentId));
  }

  Future<void> _requestLocationPermission() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      await Geolocator.requestPermission();
    }
  }

  @override
  void dispose() {
    _emergencySubscription?.cancel();
    _geofenceTripSub?.cancel();
    _geofenceAlertSub?.cancel();
    _sosNotifier.dispose();
    super.dispose();
  }

  Widget _buildEmergencyBanner() {
    final String myUid = FirebaseAuth.instance.currentUser!.uid;
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('emergencies')
          .where('teacherId', isEqualTo: myUid)
          .where('status', isEqualTo: 'accepted')
          .snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) return const SizedBox.shrink();
        final doc = snapshot.data!.docs.first;
        final data = doc.data() as Map<String, dynamic>;

        return SafeArea(
          bottom: false,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            color: Colors.red.shade600,
            child: Row(
              children: [
                const Icon(Icons.run_circle, color: Colors.white),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    "Active Rescue: ${data['studentName']}",
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
                TextButton(
                  onPressed: () => doc.reference.update({'status': 'resolved'}),
                  child: const Text("Resolve", style: TextStyle(color: Colors.white, decoration: TextDecoration.underline)),
                )
              ],
            ),
          ),
        );
      },
    );
  }

  static const _navItems = <GlassNavItem>[
    GlassNavItem(icon: Icons.route_outlined, activeIcon: Icons.route_rounded, label: "Trips"),
    GlassNavItem(
        icon: Icons.people_outline_rounded, activeIcon: Icons.people_rounded, label: "Students"),
    GlassNavItem(
        icon: Icons.assignment_outlined, activeIcon: Icons.assignment_rounded, label: "Forms"),
    GlassNavItem(
        icon: Icons.chat_bubble_outline_rounded,
        activeIcon: Icons.chat_bubble_rounded,
        label: "Chats"),
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
    );
  }
}

class TeacherTripsTab extends StatelessWidget {
  const TeacherTripsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final String myUid = FirebaseAuth.instance.currentUser!.uid;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        titleSpacing: 24,
        title: Text("My Trips", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22, color: AppTheme.secondaryColor)),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: TripQueries.mine(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary));
          }

          final myTrips = snapshot.data!.docs.where((doc) {
            final data = doc.data();
            if (data['status'] == 'completed') return false;
            final buses = asList(data['buses']);
            for (var bus in buses) {
              if (bus?['mainTeacher']?['id'] == myUid || bus?['coTeacher']?['id'] == myUid) return true;
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
                  Text("No active trips", style: TextStyle(fontSize: 16, color: Colors.grey.shade500, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  Text("You will see your trips here once assigned.", style: TextStyle(fontSize: 13, color: Colors.grey.shade400)),
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
                  builder: (_) => TeacherTripDetails(tripId: doc.id, tripData: data, myUid: myUid),
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
                            Text(data['title'] ?? 'Untitled Trip',
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15, color: AppTheme.secondaryColor)),
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
    Color bg;
    Color fg;
    String label;

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

class TeacherTripDetails extends StatefulWidget {
  final String tripId;
  final Map<String, dynamic> tripData;
  final String myUid;

  const TeacherTripDetails({super.key, required this.tripId, required this.tripData, required this.myUid});

  @override
  State<TeacherTripDetails> createState() => _TeacherTripDetailsState();
}

class _TeacherTripDetailsState extends State<TeacherTripDetails> {
  MobileScannerController? _scannerController;
  bool _isProcessingQR = false;
  StreamSubscription<QuerySnapshot>? _alertSub;

  @override
  void initState() {
    super.initState();
    _listenForAlerts();
  }

  void _listenForAlerts() {
    bool isFirstSnapshot = true;
    final seenIds = <String>{};
    _alertSub = FirebaseFirestore.instance
        .collection('trips')
        .doc(widget.tripId)
        .collection('alerts')
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .listen((snapshot) {
      for (final change in snapshot.docChanges) {
        if (change.type != DocumentChangeType.added) continue;
        if (seenIds.contains(change.doc.id)) continue;
        seenIds.add(change.doc.id);
        final data = change.doc.data() as Map<String, dynamic>;
        if (isFirstSnapshot) {
          final ts = data['createdAt'];
          if (ts == null) continue;
          final created = (ts as Timestamp).toDate();
          if (DateTime.now().difference(created).inMinutes > 10) continue;
        }
        _showGeofenceAlarm(change.doc);
      }
      isFirstSnapshot = false;
    });
  }

  void _showGeofenceAlarm(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;

    _playEmergencyAlarm();

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: Colors.red.shade50,
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 32),
            const SizedBox(width: 8),
            const Text("GEOFENCE ALERT", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        content: Text(
          "${data['studentName']} went outside the designated area!",
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              doc.reference.update({'status': 'dismissed'});
              _stopEmergencySound();
              Navigator.pop(ctx);
            },
            child: const Text("Acknowledge", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _alertSub?.cancel();
    super.dispose();
  }

  List<String> _resolveStopStatuses(int length, List<dynamic>? raw) {
    if (raw != null && raw.length == length) {
      return raw.map((s) => s.toString()).toList();
    }
    return List.generate(length, (_) => 'pending');
  }

  Future<void> _arriveAtStop(BuildContext context, List stops, List<String> statuses, int i) async {
    final updated = List<String>.from(statuses);
    updated[i] = 'in_progress';
    await FirebaseFirestore.instance.collection('trips').doc(widget.tripId).update({
      'stopStatuses': updated,
      'activeStopIndex': i,
      'status': 'in_progress',
      'updatedAt': FieldValue.serverTimestamp(),
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      content: Text(i == 0 ? "Trip started at ${stops[i]['name']}!" : "Arrived at ${stops[i]['name']}!"),
      backgroundColor: Colors.green,
    ));
  }

  Future<void> _departFromStop(BuildContext context, List stops, List<String> statuses, int i) async {
    final updated = List<String>.from(statuses);
    updated[i] = 'completed';
    // Set activeStopIndex to -1 while in transit so the background service
    // does NOT activate the next stop's geofence until the bus arrives there.
    await FirebaseFirestore.instance.collection('trips').doc(widget.tripId).update({
      'stopStatuses': updated,
      'activeStopIndex': -1,
      'status': 'in_progress',
      'updatedAt': FieldValue.serverTimestamp(),
    });
    if (!mounted) return;
    final nextIndex = i + 1 < stops.length ? i + 1 : null;
    final msg = nextIndex != null
        ? "Departed. Heading to ${stops[nextIndex]['name']}."
        : "Departed from final stop.";
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      content: Text(msg),
      backgroundColor: Colors.orange,
    ));
  }

  void _showStudentAssignmentModal(BuildContext context, int busIndex, List<dynamic> currentPassengers) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: StudentSelectorModal(
          tripId: widget.tripId,
          busIndex: busIndex,
          alreadyAssignedIds: currentPassengers.map((p) => p['id']).toSet().cast<String>().toList(),
        ),
      ),
    );
  }

  void _openScannerModal(BuildContext context, int stopIndex, int myBusIndex) {
    _scannerController = MobileScannerController();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setModalState) {
          return Container(
            height: MediaQuery.of(context).size.height * 0.75,
            decoration: const BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
            ),
            child: Column(
              children: [
                Container(
                  margin: const EdgeInsets.only(top: 12, bottom: 4),
                  width: 40, height: 4,
                  decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(10)),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text("Scan Student QR", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.secondaryColor)),
                      ),
                      GestureDetector(
                        onTap: () => Navigator.pop(ctx),
                        child: Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(color: Colors.grey.shade100, shape: BoxShape.circle),
                          child: const Icon(Icons.close, size: 18, color: AppTheme.secondaryColor),
                        ),
                      )
                    ],
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: MobileScanner(
                      controller: _scannerController,
                      onDetect: (capture) async {
                        if (_isProcessingQR) return;
                        for (final barcode in capture.barcodes) {
                          if (barcode.rawValue != null) {
                            setModalState(() => _isProcessingQR = true);
                            await _processScannedQR(ctx, barcode.rawValue!, stopIndex, myBusIndex);
                            if (mounted) setModalState(() => _isProcessingQR = false);
                            break;
                          }
                        }
                      },
                    ),
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: _isProcessingQR
                      ? CircularProgressIndicator(color: AppTheme.effectivePrimary)
                      : Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.qr_code_scanner, size: 18, color: Colors.grey.shade500),
                            const SizedBox(width: 8),
                            Text("Point camera at student's QR code",
                                style: TextStyle(fontWeight: FontWeight.w500, color: Colors.grey.shade600)),
                          ],
                        ),
                ),
              ],
            ),
          );
        },
      ),
    ).then((_) => _scannerController?.dispose());
  }

  Future<void> _processScannedQR(BuildContext ctx, String rawData, int stopIndex, int myBusIndex) async {
    try {
      final qrMap = jsonDecode(rawData.trim()) as Map<String, dynamic>;
      final String? studentId = qrMap['studentId'] as String?;
      if (studentId == null || studentId.isEmpty) {
        if (!ctx.mounted) return;
        await _showResultDialog(ctx, "Invalid QR", "This is not a valid student QR code.", Colors.red, Icons.qr_code_scanner);
        return;
      }

      final tripRef = FirebaseFirestore.instance.collection('trips').doc(widget.tripId);
      final tripSnap = await tripRef.get();
      if (!tripSnap.exists) {
        if (!ctx.mounted) return;
        await _showResultDialog(ctx, "Error", "Trip not found.", Colors.red, Icons.error_outline);
        return;
      }

      final tripData = tripSnap.data() as Map<String, dynamic>;
      final List rawBuses = asList(tripData['buses']);
      final List<Map<String, dynamic>> buses =
          rawBuses.map((b) => Map<String, dynamic>.from(b as Map)).toList();

      bool found = false;
      bool alreadyScanned = false;
      String studentName = '';

      outer:
      for (int bi = 0; bi < buses.length; bi++) {
        final passengers = asList(buses[bi]['passengers']);
        final updatedPassengers = passengers
            .map((p) => Map<String, dynamic>.from(p as Map))
            .toList();
        for (int pi = 0; pi < updatedPassengers.length; pi++) {
          if (updatedPassengers[pi]['id'] == studentId) {
            found = true;
            studentName = (updatedPassengers[pi]['name'] ?? 'Student').toString();
            final att = Map<String, dynamic>.from(
                (updatedPassengers[pi]['attendance'] as Map?) ?? {});
            if (att['stop_$stopIndex'] == true) {
              alreadyScanned = true;
            } else {
              att['stop_$stopIndex'] = true;
              updatedPassengers[pi]['attendance'] = att;
              buses[bi]['passengers'] = updatedPassengers;
              await tripRef.update({
                'buses': buses,
                'updatedAt': FieldValue.serverTimestamp(),
              });
            }
            break outer;
          }
        }
      }

      if (!ctx.mounted) return;
      if (!found) {
        await _showResultDialog(ctx, "Not Found", "Student is not assigned to this trip.", Colors.red, Icons.person_off_outlined);
        return;
      }
      if (alreadyScanned) {
        await _showResultDialog(ctx, "Already Scanned", "$studentName already scanned for this stop.", Colors.orange, Icons.info_outline);
      } else {
        await _showResultDialog(ctx, "Success", "Attendance recorded for $studentName!", Colors.green, Icons.check_circle);
      }
    } catch (_) {
      if (!ctx.mounted) return;
      await _showResultDialog(ctx, "Invalid QR", "Could not read QR code. Make sure to scan a valid student QR.", Colors.red, Icons.qr_code_scanner);
    }
  }

  Future<void> _showResultDialog(BuildContext context, String title, String message, Color color, IconData icon) async {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            Icon(icon, color: color, size: 28),
            const SizedBox(width: 8),
            Expanded(child: Text(title, style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 18))),
          ],
        ),
        content: Text(message, style: const TextStyle(fontSize: 15)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text("OK", style: TextStyle(color: AppTheme.secondaryColor)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance.collection('trips').doc(widget.tripId).snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return Scaffold(body: Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary)));
        }

        final data = snapshot.data!.data() as Map<String, dynamic>;
        final List stops = data['stops'] ?? [];
        final int activeStop = data['activeStopIndex'] ?? -1;
        final buses = asList(data['buses']);

        int myBusIndex = -1;
        List<dynamic> assignedStudents = [];

        for (int i = 0; i < buses.length; i++) {
          if (buses[i]?['mainTeacher']?['id'] == widget.myUid || buses[i]?['coTeacher']?['id'] == widget.myUid) {
            myBusIndex = i;
            assignedStudents = asList(buses[i]?['passengers']);
            break;
          }
        }

        return Scaffold(
          backgroundColor: const Color(0xFFF7F8FA),
          appBar: AppBar(
            backgroundColor: Colors.white,
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: AppTheme.secondaryColor),
              onPressed: () => Navigator.pop(context),
            ),
            title: Text(
              data['title'] ?? 'Trip Details',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: AppTheme.secondaryColor),
            ),
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _SectionLabel(label: "Quick Actions"),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: _ActionButton(
                        icon: Icons.group_add_outlined,
                        label: "Assign Students",
                        onTap: () => _showStudentAssignmentModal(context, myBusIndex, assignedStudents),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _ActionButton(
                        icon: Icons.event_seat_outlined,
                        label: "Seat Map",
                        onTap: () {
                          if (myBusIndex < 0) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text("No bus assigned to you yet.")),
                            );
                            return;
                          }
                          showDialog(
                            context: context,
                            builder: (_) => TeacherSeatMapDialog(
                              tripId: widget.tripId,
                              busIndex: myBusIndex,
                              bus: Map<String, dynamic>.from(buses[myBusIndex] as Map),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _ActionButton(
                        icon: Icons.map_outlined,
                        label: "Live Map",
                        onTap: () => Navigator.push(context, MaterialPageRoute(
                          builder: (_) => TeacherMapScreen(assignedStudents: assignedStudents, tripData: data, tripId: widget.tripId),
                        )),
                      ),
                    ),
                  ],
                ),

                const SizedBox(height: 28),

                _SectionLabel(label: "Destinations & Attendance"),
                const SizedBox(height: 10),

                if ((data['totalDuration'] ?? '').toString().isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppTheme.effectivePrimary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.schedule_rounded,
                              size: 16, color: AppTheme.effectivePrimary),
                          const SizedBox(width: 8),
                          Text(
                            "Estimated total trip time: ${data['totalDuration']}",
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.effectivePrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),

                ..._buildStopsList(context, stops, activeStop, assignedStudents, myBusIndex, data),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: data['status'] == 'completed' ? null : () => _completeTrip(context),
                    icon: const Icon(Icons.flag_circle_outlined, size: 20),
                    label: Text(
                      data['status'] == 'completed' ? "Trip Completed" : "Complete Trip",
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                    ),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      backgroundColor: data['status'] == 'completed'
                          ? Colors.grey.shade300
                          : Colors.green.shade600,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }
    );
  }

  Future<void> _completeTrip(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text("Complete Trip?"),
        content: const Text(
          "Mark this trip as completed. Parents will be notified the trip has ended.",
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.green.shade600),
            child: const Text("Complete", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    await FirebaseFirestore.instance.collection('trips').doc(widget.tripId).update({
      'status': 'completed',
      'activeStopIndex': -1,
      'completedAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      content: const Text("Trip marked as completed."),
      backgroundColor: Colors.green.shade600,
    ));
  }

  List<Widget> _buildStopsList(
    BuildContext context,
    List stops,
    int activeStop,
    List<dynamic> assignedStudents,
    int myBusIndex,
    Map<String, dynamic> data,
  ) {
    return stops.asMap().entries.map<Widget>((entry) {
      final int i = entry.key;
      final stop = entry.value;
                  final statuses = _resolveStopStatuses(stops.length, data['stopStatuses'] as List<dynamic>?);
                  final String thisStatus = statuses[i];
                  final String prevStatus = i > 0 ? statuses[i - 1] : 'completed';
                  final bool isOriginStop = i == 0;
                  final bool isAtDest = thisStatus == 'in_progress';
                  final bool isDone = thisStatus == 'completed';
                  // Origin: can start if still pending.
                  // Other stops: can arrive only when previous stop is done.
                  final bool canStartOrArrive = !isDone && !isAtDest &&
                      (isOriginStop || prevStatus == 'completed');
                  final bool isActive = isAtDest;
                  final int presentCount = assignedStudents.where((s) => s['attendance']?['stop_$i'] == true).length;

                  return Container(
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isActive ? AppTheme.effectivePrimary : Colors.transparent,
                        width: 2,
                      ),
                      boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 4))],
                    ),
                    child: Theme(
                      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                      child: ExpansionTile(
                        tilePadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 4),
                        childrenPadding: EdgeInsets.zero,
                        leading: Container(
                          width: 38,
                          height: 38,
                          decoration: BoxDecoration(
                            color: isActive ? AppTheme.effectivePrimary.withValues(alpha: 0.12) : Colors.grey.shade100,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.location_on_rounded,
                              color: isActive ? AppTheme.effectivePrimary : Colors.grey.shade400, size: 20),
                        ),
                        title: Text(stop['name'],
                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: AppTheme.secondaryColor)),
                        subtitle: Row(
                          children: [
                            Text(stop['time'] ?? '',
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
                        trailing: isDone
                            ? const Icon(Icons.check_circle_rounded, color: Colors.green, size: 26)
                            : isAtDest && i == stops.length - 1
                                ? Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                                    decoration: BoxDecoration(color: Colors.green.shade50, borderRadius: BorderRadius.circular(20)),
                                    child: Text("Final Stop", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: Colors.green.shade700)),
                                  )
                                : isAtDest || canStartOrArrive
                                    ? Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                                        decoration: BoxDecoration(
                                          color: (isAtDest ? Colors.orange : AppTheme.effectivePrimary).withValues(alpha: 0.1),
                                          borderRadius: BorderRadius.circular(20),
                                        ),
                                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                                          Icon(Icons.swipe_right_alt_rounded, size: 14, color: isAtDest ? Colors.orange.shade700 : AppTheme.effectivePrimary),
                                          const SizedBox(width: 4),
                                          Text(
                                            isAtDest ? "Depart" : (isOriginStop ? "Start" : "Arrive"),
                                            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: isAtDest ? Colors.orange.shade700 : AppTheme.effectivePrimary),
                                          ),
                                        ]),
                                      )
                                    : Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                                        decoration: BoxDecoration(color: Colors.grey.shade100, borderRadius: BorderRadius.circular(20)),
                                        child: Text("Locked", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: Colors.grey.shade400)),
                                      ),
                        children: [
                          Container(
                            decoration: const BoxDecoration(
                              color: Color(0xFFF7F8FA),
                              borderRadius: BorderRadius.vertical(bottom: Radius.circular(14)),
                            ),
                            padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (canStartOrArrive) ...[
                                  _SlideToConfirm(
                                    label: isOriginStop ? "Slide to Start" : "Slide to Arrive",
                                    color: AppTheme.effectivePrimary,
                                    onConfirmed: () => _arriveAtStop(context, stops, statuses, i),
                                  ),
                                  const SizedBox(height: 14),
                                ],
                                if (isAtDest && i < stops.length - 1) ...[
                                  _SlideToConfirm(
                                    label: "Slide to Depart",
                                    color: Colors.orange,
                                    onConfirmed: () => _departFromStop(context, stops, statuses, i),
                                  ),
                                  const SizedBox(height: 14),
                                ],
                                Row(
                                  children: [
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
                                        label: const Text("QR Scanner"),
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: AppTheme.secondaryColor,
                                          side: BorderSide(color: Colors.grey.shade300),
                                          padding: const EdgeInsets.symmetric(vertical: 12),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                        ),
                                        onPressed: () => _openScannerModal(context, i, myBusIndex),
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        icon: Icon(Icons.map_outlined, size: 18),
                                        label: Text("View Map"),
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: AppTheme.effectivePrimary,
                                          side: BorderSide(color: AppTheme.effectivePrimary.withValues(alpha: 0.4)),
                                          padding: const EdgeInsets.symmetric(vertical: 12),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                        ),
                                        onPressed: () => showDialog(
                                          context: context,
                                          builder: (_) => DestinationMapDialog(
                                            stop: Map<String, dynamic>.from(stop),
                                            stopIndex: i,
                                            tripTitle: data['title'] ?? 'Trip',
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),

                                const SizedBox(height: 16),
                                Divider(color: Colors.grey.shade200, height: 1),
                                const SizedBox(height: 14),

                                Row(
                                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text("Attendance", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.secondaryColor)),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Text(
                                        "$presentCount / ${assignedStudents.length}",
                                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.effectivePrimary),
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),

                                ...assignedStudents.map((student) {
                                  final bool isPresent = student['attendance']?['stop_$i'] == true;
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: Row(
                                      children: [
                                        Icon(
                                          isPresent ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                                          color: isPresent ? AppTheme.effectivePrimary : Colors.grey.shade300,
                                          size: 18,
                                        ),
                                        const SizedBox(width: 10),
                                        Expanded(
                                          child: Text(student['name'],
                                              style: TextStyle(
                                                  fontSize: 13,
                                                  fontWeight: isPresent ? FontWeight.w500 : FontWeight.normal,
                                                  color: isPresent ? AppTheme.secondaryColor : Colors.grey.shade500)),
                                        ),
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                          decoration: BoxDecoration(
                                            color: isPresent ? Colors.green.shade50 : Colors.grey.shade100,
                                            borderRadius: BorderRadius.circular(10),
                                          ),
                                          child: Text(
                                            isPresent ? "Present" : "Pending",
                                            style: TextStyle(
                                              fontSize: 10,
                                              fontWeight: FontWeight.w600,
                                              color: isPresent ? Colors.green.shade700 : Colors.grey.shade500,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                }),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
      }).toList();
  }
}

/// Map dialog focused on a single destination, auto-zoomed to the user's
/// current location. Shows a marker on the destination and the user position.
class DestinationMapDialog extends StatefulWidget {
  final Map<String, dynamic> stop;
  final int stopIndex;
  final String tripTitle;

  const DestinationMapDialog({
    super.key,
    required this.stop,
    required this.stopIndex,
    required this.tripTitle,
  });

  @override
  State<DestinationMapDialog> createState() => _DestinationMapDialogState();
}

class _DestinationMapDialogState extends State<DestinationMapDialog> {
  GoogleMapController? _controller;

  @override
  Widget build(BuildContext context) {
    final double stopLat = (widget.stop['lat'] as num).toDouble();
    final double stopLng = (widget.stop['lng'] as num).toDouble();
    final LatLng dest = LatLng(stopLat, stopLng);
    final double radius = (widget.stop['geofenceRadius'] as num?)?.toDouble() ?? 0;

    // Pick a sensible zoom: tighter when there is a small geofence, wider
    // for big radius zones so the whole circle stays in view.
    final double initialZoom = radius <= 0
        ? 17
        : radius < 300
            ? 17
            : radius < 800
                ? 15.5
                : 14;

    final Set<Marker> markers = {
      Marker(
        markerId: const MarkerId('destination'),
        position: dest,
        infoWindow: InfoWindow(
          title: widget.stop['name']?.toString() ?? 'Destination',
          snippet: widget.stop['etaFromPrev'] != null
              ? "ETA from previous stop: ${widget.stop['etaFromPrev']}"
              : widget.stop['time']?.toString(),
        ),
      ),
    };

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: 700,
        height: 560,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 14),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.location_on_rounded,
                        color: AppTheme.effectivePrimary, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.stop['name']?.toString() ?? 'Destination',
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.secondaryColor,
                          ),
                        ),
                        if ((widget.stop['etaFromPrev'] ?? '').toString().isNotEmpty)
                          Text(
                            "ETA from previous: ${widget.stop['etaFromPrev']}",
                            style: TextStyle(
                              fontSize: 12,
                              color: AppTheme.effectivePrimary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded,
                        color: AppTheme.secondaryColor),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Stack(
                children: [
                  GoogleMap(
                    initialCameraPosition:
                        CameraPosition(target: dest, zoom: initialZoom),
                    markers: markers,
                    circles: radius > 0
                        ? {
                            Circle(
                              circleId: const CircleId('dest_geofence'),
                              center: dest,
                              radius: radius,
                              fillColor: AppTheme.effectivePrimary.withValues(alpha: 0.15),
                              strokeColor: AppTheme.effectivePrimary,
                              strokeWidth: 2,
                            ),
                          }
                        : const {},
                    myLocationButtonEnabled: false,
                    onMapCreated: (c) {
                      _controller = c;
                      // Always keep the dialog focused on the destination.
                      c.animateCamera(
                        CameraUpdate.newLatLngZoom(dest, initialZoom),
                      );
                    },
                  ),
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: FloatingActionButton.small(
                      heroTag: 'dest_dialog_zoom_dest',
                      backgroundColor: Colors.white,
                      tooltip: "Recenter on destination",
                      onPressed: () => _controller?.animateCamera(
                        CameraUpdate.newLatLngZoom(dest, initialZoom),
                      ),
                      child: const Icon(Icons.location_on_rounded,
                          color: Colors.red),
                    ),
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

/// Seat-map view for the teacher's own bus.
/// Shows seats 1..capacity with names; tap a student row to (re)assign a seat.
class TeacherSeatMapDialog extends StatefulWidget {
  final String tripId;
  final int busIndex;
  final Map<String, dynamic> bus;

  const TeacherSeatMapDialog({
    super.key,
    required this.tripId,
    required this.busIndex,
    required this.bus,
  });

  @override
  State<TeacherSeatMapDialog> createState() => _TeacherSeatMapDialogState();
}

class _TeacherSeatMapDialogState extends State<TeacherSeatMapDialog> {
  late int _capacity;
  late List<Map<String, dynamic>> _passengers;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _capacity = (widget.bus['capacity'] is int)
        ? widget.bus['capacity']
        : int.tryParse(widget.bus['capacity']?.toString() ?? '') ?? 60;
    _passengers = asList(widget.bus['passengers'])
        .map((p) => Map<String, dynamic>.from(p as Map))
        .toList();
  }

  Map<int, Map<String, dynamic>> get _seatToStudent {
    final Map<int, Map<String, dynamic>> map = {};
    for (final p in _passengers) {
      final dynamic seat = p['seatNumber'];
      final int? s = seat is int ? seat : (seat is String ? int.tryParse(seat) : null);
      if (s != null) map[s] = p;
    }
    return map;
  }

  Future<void> _assignSeat(Map<String, dynamic> student) async {
    final Set<int> taken = _seatToStudent.keys.toSet();
    final int? currentSeat = (student['seatNumber'] is int)
        ? student['seatNumber'] as int
        : int.tryParse(student['seatNumber']?.toString() ?? '');
    if (currentSeat != null) taken.remove(currentSeat);

    final picked = await showDialog<int?>(
      context: context,
      builder: (ctx) => _TeacherSeatPicker(
        capacity: _capacity,
        taken: taken,
        currentSeat: currentSeat,
        studentName: student['name']?.toString() ?? 'Student',
      ),
    );
    if (picked == null) return;
    setState(() {
      for (final p in _passengers) {
        if (p['id'] == student['id']) {
          if (picked == -1) {
            p.remove('seatNumber'); // any/clear
          } else {
            p['seatNumber'] = picked;
          }
          break;
        }
      }
    });
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final ref = FirebaseFirestore.instance.collection('trips').doc(widget.tripId);
      final snap = await ref.get();
      final List buses = List.from(snap.data()?['buses'] ?? []);
      final Map<String, dynamic> myBus = Map<String, dynamic>.from(buses[widget.busIndex]);
      myBus['passengers'] = _passengers;
      buses[widget.busIndex] = myBus;
      await ref.update({'buses': buses});

      // Keep the chat membership in sync (no-op if Cloud Function already ran).
      await ChatSync.syncTripChats(
        tripId: widget.tripId,
        tripTitle: snap.data()?['title']?.toString() ?? 'Field Trip',
        buses: buses,
      );
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text("Seat assignments saved."),
        backgroundColor: Colors.green.shade600,
        behavior: SnackBarBehavior.floating,
      ));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("Save failed: $e"),
        backgroundColor: Colors.red,
      ));
    }
  }

  /// Format a student's name as "C. Sevilla" -- initials of all name parts
  /// except the last word, then the last word as the surname.
  /// "Cedric Sevilla" -> "C. Sevilla"
  /// "Juan Dela Cruz" -> "J. D. Cruz"
  static String _shortName(String fullName) {
    final parts = fullName.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return '';
    if (parts.length == 1) return parts.first;
    final initials = parts
        .sublist(0, parts.length - 1)
        .map((p) => '${p[0].toUpperCase()}.')
        .join(' ');
    return '$initials ${parts.last}';
  }

  @override
  Widget build(BuildContext context) {
    final occupied = _seatToStudent;
    final String busLabel = widget.bus['busLabel']?.toString() ??
        widget.bus['busNo']?.toString() ??
        '?';
    final int unseated = _passengers.where((p) {
      final s = p['seatNumber'];
      return s is! int && (s is! String || int.tryParse(s) == null);
    }).length;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: SizedBox(
        width: 640,
        height: 660,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 14),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.event_seat_outlined,
                        color: AppTheme.effectivePrimary, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("Bus $busLabel -- Seat Map",
                            style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: AppTheme.secondaryColor)),
                        Text(
                          "${occupied.length}/$_capacity occupied"
                          "${unseated > 0 ? " Â· $unseated unseated" : ""}",
                          style: const TextStyle(fontSize: 12, color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: Center(
                  child: Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    alignment: WrapAlignment.center,
                    children: List.generate(_capacity, (i) {
                      final int seat = i + 1;
                      final student = occupied[seat];
                      final bool taken = student != null;
                      final String displayName = taken
                          ? _shortName(student['name']?.toString() ?? '')
                          : '';
                      return InkWell(
                        onTap: () {
                          // If the seat is taken, let the teacher reassign that
                          // student. Otherwise let them pick which student to
                          // place on this seat.
                          if (taken) {
                            _assignSeat(student);
                          } else {
                            _pickStudentForSeat(seat);
                          }
                        },
                        borderRadius: BorderRadius.circular(10),
                        child: Container(
                          width: 86,
                          height: 86,
                          decoration: BoxDecoration(
                            color: taken
                                ? AppTheme.effectivePrimary.withValues(alpha: 0.12)
                                : Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: taken
                                  ? AppTheme.effectivePrimary.withValues(alpha: 0.4)
                                  : Colors.grey.shade300,
                            ),
                          ),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 6),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                "$seat",
                                style: TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                  color: taken
                                      ? AppTheme.effectivePrimary
                                      : Colors.grey.shade500,
                                ),
                              ),
                              if (taken) ...[
                                const SizedBox(height: 4),
                                Text(
                                  displayName,
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10,
                                    height: 1.1,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.effectivePrimary,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    }),
                  ),
                ),
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.all(14),
              child: SizedBox(
                width: double.infinity,
                height: 46,
                child: ElevatedButton.icon(
                  onPressed: _saving ? null : _save,
                  icon: _saving
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.check_rounded, size: 18),
                  label: const Text("Save seat assignments"),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Open a small student picker for a free seat.
  Future<void> _pickStudentForSeat(int seat) async {
    if (_passengers.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text("No students assigned to this bus yet."),
        backgroundColor: Colors.orange.shade600,
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: SizedBox(
          width: 360,
          height: 440,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        "Assign to seat $seat",
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.secondaryColor,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.separated(
                  itemCount: _passengers.length,
                  separatorBuilder: (_, __) =>
                      Divider(color: Colors.grey.shade100, height: 1),
                  itemBuilder: (c, i) {
                    final p = _passengers[i];
                    final dynamic s = p['seatNumber'];
                    final int? currentSeat =
                        s is int ? s : (s is String ? int.tryParse(s) : null);
                    return ListTile(
                      title: Text(
                        p['name']?.toString() ?? '',
                        style: TextStyle(fontSize: 13),
                      ),
                      trailing: currentSeat != null
                          ? Text("Seat $currentSeat",
                              style: TextStyle(
                                fontSize: 11,
                                color: AppTheme.effectivePrimary,
                                fontWeight: FontWeight.w600,
                              ))
                          : Text("Any",
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.grey.shade500,
                              )),
                      onTap: () => Navigator.pop(ctx, p['id'] as String),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (picked == null) return;
    setState(() {
      for (final p in _passengers) {
        if (p['id'] == picked) {
          p['seatNumber'] = seat;
          break;
        }
      }
    });
  }
}

/// Reused mini seat-picker for the teacher's seat-map dialog.
class _TeacherSeatPicker extends StatefulWidget {
  final int capacity;
  final Set<int> taken;
  final int? currentSeat;
  final String studentName;
  const _TeacherSeatPicker({
    required this.capacity,
    required this.taken,
    required this.currentSeat,
    required this.studentName,
  });

  @override
  State<_TeacherSeatPicker> createState() => _TeacherSeatPickerState();
}

class _TeacherSeatPickerState extends State<_TeacherSeatPicker> {
  int? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.currentSeat;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Container(
        width: 420,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text("Seat for ${widget.studentName}",
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.secondaryColor)),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.pop(context, -1),
                icon: const Icon(Icons.shuffle_rounded, size: 16),
                label: const Text("Any seat (clear assignment)"),
              ),
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: List.generate(widget.capacity, (i) {
                    final s = i + 1;
                    final bool isTaken = widget.taken.contains(s);
                    final bool isSelected = _selected == s;
                    return InkWell(
                      onTap: isTaken ? null : () => setState(() => _selected = s),
                      child: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: isSelected
                              ? AppTheme.effectivePrimary
                              : (isTaken ? Colors.red.shade100 : Colors.grey.shade100),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isSelected
                                ? AppTheme.effectivePrimary
                                : Colors.grey.shade200,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Text("$s",
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: isSelected
                                  ? Colors.white
                                  : (isTaken
                                      ? Colors.red.shade400
                                      : AppTheme.secondaryColor),
                            )),
                      ),
                    );
                  }),
                ),
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _selected == null
                    ? null
                    : () => Navigator.pop(context, _selected),
                child: Text(_selected == null ? "Pick a seat" : "Assign seat $_selected"),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Text(label,
        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.secondaryColor, letterSpacing: 0.3));
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 4))],
        ),
        child: Column(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: AppTheme.effectivePrimary, size: 22),
            ),
            const SizedBox(height: 8),
            Text(label, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.secondaryColor)),
          ],
        ),
      ),
    );
  }
}

class TeacherMapScreen extends StatefulWidget {
  final List<dynamic> assignedStudents;
  final Map<String, dynamic> tripData;
  final String tripId;

  const TeacherMapScreen({super.key, required this.assignedStudents, required this.tripData, required this.tripId});

  @override
  State<TeacherMapScreen> createState() => _TeacherMapScreenState();
}

class _TeacherMapScreenState extends State<TeacherMapScreen>
    with TickerProviderStateMixin {
  GoogleMapController? _mapController;
  final Map<String, BitmapDescriptor> _customMarkers = {};
  final Map<String, Map<String, dynamic>> _peopleInfo = {};
  StreamSubscription<Position>? _positionStream;
  StreamSubscription<QuerySnapshot>? _alertSubMap;
  StreamSubscription<DocumentSnapshot>? _tripStatusSub;
  StreamSubscription<QuerySnapshot>? _sosSub;
  Timer? _heartbeatTimer;
  Position? _lastKnownPos;
  double? _nextStopLat;
  double? _nextStopLng;
  String? _nextStopName;
  bool _atStop = false;
  String _liveEta = '';
  Set<String> _pendingSosIds = {};
  final String myUid = FirebaseAuth.instance.currentUser!.uid;
  final Battery _battery = Battery();
  late final LiveTracker _tracker = LiveTracker(vsync: this);

  @override
  void initState() {
    super.initState();
    // Pre-populate name/role from trip data so the map works before locations stream fires.
    for (final s in widget.assignedStudents) {
      if (s is! Map) continue;
      final id = s['id']?.toString();
      if (id == null || id.isEmpty) continue;
      _peopleInfo[id] = {'name': s['name']?.toString() ?? '', 'role': 'student'};
    }
    _fetchMyName();
    _startLocationUpdates();
    _listenForAlerts();
    _watchTripStatus();
    _listenForSosAlerts();
  }

  Future<void> _fetchMyName() async {
    try {
      final snap = await FirebaseFirestore.instance.collection('users').doc(myUid).get();
      final name = snap.data()?['name']?.toString() ?? '';
      if (mounted) {
        setState(() {
          _peopleInfo[myUid] = {...(_peopleInfo[myUid] ?? {}), 'name': name, 'role': 'teacher'};
        });
      }
    } catch (_) {}
  }

  void _listenForSosAlerts() {
    _sosSub = FirebaseFirestore.instance
        .collection('emergencies')
        .where('tripId', isEqualTo: widget.tripId)
        .where('status', whereIn: ['pending', 'accepted'])
        .snapshots()
        .listen((snap) {
      if (!mounted) return;
      setState(() {
        _pendingSosIds = snap.docs
            .map((d) => (d.data()['studentId'] as String?) ?? '')
            .where((id) => id.isNotEmpty)
            .toSet();
      });
    });
  }

  // activeStopIndex >= 0 → bus is AT that stop (waiting).
  // activeStopIndex == -1 → bus is in transit; find the next pending stop.
  void _updateNextStop(List stops, List? stopStatuses, int activeStopIndex) {
    if (activeStopIndex >= 0 && activeStopIndex < stops.length) {
      // At a stop: show the NEXT pending destination, status = "Waiting".
      _atStop = true;
      for (int i = activeStopIndex + 1; i < stops.length; i++) {
        final s = (stopStatuses != null && i < stopStatuses.length)
            ? stopStatuses[i].toString()
            : 'pending';
        if (s == 'pending') {
          final stop = stops[i];
          if (stop is Map && stop['lat'] is num && stop['lng'] is num) {
            _nextStopLat = (stop['lat'] as num).toDouble();
            _nextStopLng = (stop['lng'] as num).toDouble();
            _nextStopName = stop['name']?.toString() ?? 'Next Stop';
            return;
          }
        }
      }
      // Last stop — no further destination.
      _nextStopLat = null;
      _nextStopLng = null;
      _nextStopName = null;
      return;
    }
    // In transit: show first pending stop with ETA.
    _atStop = false;
    for (int i = 0; i < stops.length; i++) {
      final s = (stopStatuses != null && i < stopStatuses.length)
          ? stopStatuses[i].toString()
          : 'pending';
      if (s == 'pending') {
        final stop = stops[i];
        if (stop is Map && stop['lat'] is num && stop['lng'] is num) {
          _nextStopLat = (stop['lat'] as num).toDouble();
          _nextStopLng = (stop['lng'] as num).toDouble();
          _nextStopName = stop['name']?.toString() ?? 'Next Stop';
          return;
        }
      }
    }
    _nextStopLat = null;
    _nextStopLng = null;
    _nextStopName = null;
  }

  void _computeEta(Position pos) {
    if (_atStop || _nextStopLat == null || _nextStopLng == null) {
      if (mounted) setState(() => _liveEta = '');
      return;
    }
    final distM = Geolocator.distanceBetween(
      pos.latitude, pos.longitude, _nextStopLat!, _nextStopLng!,
    );
    final speed = (pos.speed > 0.5) ? pos.speed : 8.33; // default 30 km/h
    final mins = (distM / speed / 60).round();
    String eta;
    if (mins < 1) {
      eta = 'Arriving';
    } else if (mins < 60) {
      eta = '~$mins min';
    } else {
      final h = mins ~/ 60;
      final m = mins % 60;
      eta = '~${h}h ${m}m';
    }
    if (mounted) setState(() => _liveEta = eta);
  }

  void _watchTripStatus() {
    _tripStatusSub = FirebaseFirestore.instance
        .collection('trips')
        .doc(widget.tripId)
        .snapshots()
        .listen((snap) {
      if (!snap.exists) return;
      final data = snap.data()!;
      _updateNextStop(
        asList(data['stops']),
        data['stopStatuses'] as List?,
        (data['activeStopIndex'] as int?) ?? -1,
      );
      final status = data['status'] as String?;
      if (status == 'completed' && mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: Text('Trip Ended',
                style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.secondaryColor)),
            content: Text(
              'This trip has been completed. Location tracking has stopped.',
            ),
            actions: [
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: AppTheme.effectivePrimary),
                onPressed: () {
                  Navigator.pop(ctx);
                  if (mounted) Navigator.pop(context);
                },
                child: const Text('OK', style: TextStyle(color: Colors.white)),
              ),
            ],
          ),
        );
      }
    });
  }

  void _listenForAlerts() {
    bool isFirstSnapshot = true;
    final seenIds = <String>{};
    _alertSubMap = FirebaseFirestore.instance
        .collection('trips')
        .doc(widget.tripId)
        .collection('alerts')
        .where('status', isEqualTo: 'pending')
        .snapshots()
        .listen((snapshot) {
      if (isFirstSnapshot) {
        isFirstSnapshot = false;
        for (final d in snapshot.docs) seenIds.add(d.id);
        return;
      }
      for (var change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added && !seenIds.contains(change.doc.id)) {
          seenIds.add(change.doc.id);
          _showGeofenceAlarm(change.doc);
        }
      }
    });
  }

  void _showGeofenceAlarm(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;

    _playEmergencyAlarm();

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        backgroundColor: Colors.red.shade50,
        title: Row(
          children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 32),
            const SizedBox(width: 8),
            const Text("GEOFENCE ALERT", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        content: Text(
          "${data['studentName']} went outside the designated area!",
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        ),
        actions: [
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              doc.reference.update({'status': 'dismissed'});
              _stopEmergencySound();
              Navigator.pop(ctx);
            },
            child: const Text("Acknowledge", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  bool _didInitialZoom = false;
  DateTime? _lastWriteTime;
  int _cachedBattery = 0;
  String _cachedNetStatus = 'Offline';
  DateTime? _lastBatteryCheck;

  Future<void> _publishPosition(Position pos, {bool fromHeartbeat = false}) async {
    // Heartbeat: skip if a GPS write already happened in the last 25 s to avoid
    // writing the same coords twice in quick succession.
    if (fromHeartbeat && _lastWriteTime != null &&
        DateTime.now().difference(_lastWriteTime!) < const Duration(seconds: 25)) {
      return;
    }

    // Refresh battery + connectivity at most once per 60 s (these are slow
    // async operations and almost never change between GPS events).
    if (_lastBatteryCheck == null ||
        DateTime.now().difference(_lastBatteryCheck!) >= const Duration(seconds: 60)) {
      _lastBatteryCheck = DateTime.now();
      try { _cachedBattery = await _battery.batteryLevel; } catch (_) {}
      try {
        final conn = await Connectivity().checkConnectivity();
        final s = conn.toString();
        if (s.contains('mobile')) {
          _cachedNetStatus = 'Mobile Data';
        } else if (s.contains('wifi')) {
          _cachedNetStatus = 'WiFi Active';
        } else {
          _cachedNetStatus = 'Offline';
        }
      } catch (_) {}
    }

    _lastWriteTime = DateTime.now();
    try {
      await FirebaseFirestore.instance.collection('locations').doc(myUid).set({
        'lat': pos.latitude,
        'lng': pos.longitude,
        'battery': _cachedBattery,
        'lastActivity': _cachedNetStatus,
        'lastUpdate': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    } catch (e) {
      debugPrint("Firestore write error (teacher): $e");
    }
  }

  void _startLocationUpdates() {
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 0,
      ),
    ).listen(
      (Position pos) async {
        _lastKnownPos = pos;
        _computeEta(pos);
        await _publishPosition(pos);

        // Auto-zoom to teacher's location the first time we get a fix.
        if (!_didInitialZoom && _mapController != null) {
          _didInitialZoom = true;
          _mapController!.animateCamera(
            CameraUpdate.newLatLngZoom(LatLng(pos.latitude, pos.longitude), 17),
          );
        }
      },
      onError: (e) => debugPrint("GPS stream error (teacher): $e"),
      cancelOnError: false,
    );
    // Heartbeat keeps presence alive when standing still. The guard inside
    // _publishPosition prevents double-writing if GPS already fired recently.
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      Position? pos = _lastKnownPos;
      if (pos == null) {
        try { pos = await Geolocator.getLastKnownPosition(); } catch (_) {}
      }
      if (pos != null) _publishPosition(pos, fromHeartbeat: true);
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

  void _loadMarker(String id, String name, Color color) async {
    if (!_customMarkers.containsKey(id)) {
      BitmapDescriptor icon = await MarkerGenerator.createCustomMarker(name, color);
      if (mounted) setState(() => _customMarkers[id] = icon);
    }
  }

  @override
  void dispose() {
    _heartbeatTimer?.cancel();
    _alertSubMap?.cancel();
    _tripStatusSub?.cancel();
    _sosSub?.cancel();
    _positionStream?.cancel();
    _tracker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        backgroundColor: Colors.white.withValues(alpha: 0.95),
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: AppTheme.secondaryColor),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text("Live Map", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: AppTheme.secondaryColor)),
      ),
      // Outer stream: live trip doc â†' determines which students have been scanned.
      body: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('trips')
            .doc(widget.tripId)
            .snapshots(),
        builder: (context, tripSnap) {
          final tripData = tripSnap.data?.data() ?? widget.tripData;

          // Build the set of student IDs that have at least one attendance mark.
          final Set<String> scannedIds = {};
          for (final b in asList(tripData['buses'])) {
            if (b is! Map) continue;
            for (final p in asList(b['passengers'])) {
              if (p is! Map) continue;
              final att = p['attendance'];
              if (att is Map && att.values.any((v) => v == true)) {
                final id = p['id']?.toString();
                if (id != null && id.isNotEmpty) scannedIds.add(id);
              }
            }
          }

          // Geofence circle from live trip data.
          Set<Circle> circles = {};
          final activeStop = tripData['activeStopIndex'];
          if (activeStop is int && activeStop >= 0) {
            final stops = asList(tripData['stops']);
            if (activeStop < stops.length) {
              final stop = stops[activeStop];
              if (stop is Map && stop['lat'] is num && stop['lng'] is num) {
                circles.add(Circle(
                  circleId: const CircleId("geofence"),
                  center: LatLng(
                      (stop['lat'] as num).toDouble(), (stop['lng'] as num).toDouble()),
                  radius: stop['geofenceRadius'] is num
                      ? (stop['geofenceRadius'] as num).toDouble()
                      : 200.0,
                  fillColor: AppTheme.effectivePrimary.withValues(alpha: 0.15),
                  strokeColor: AppTheme.effectivePrimary,
                  strokeWidth: 2,
                ));
              }
            }
          }

          // Inner stream: only scanned students + teacher — reads from locations
          // collection (not users) so GPS writes don't trigger session/theme watchers.
          final queryIds = [...scannedIds, myUid];
          return StreamBuilder<QuerySnapshot>(
            key: ValueKey(queryIds.join(',')),
            stream: FirebaseFirestore.instance
                .collection('locations')
                .where(FieldPath.documentId, whereIn: queryIds)
                .snapshots(),
            builder: (context, locSnap) {
              if (!locSnap.hasData) {
                return Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary));
              }

              List<Map<String, dynamic>> peopleList = [];
              final Map<String, LatLng> targets = {};

              for (var doc in locSnap.data!.docs) {
                final locData = doc.data() as Map<String, dynamic>;
                final profile = _peopleInfo[doc.id] ?? {};
                final merged = {...profile, ...locData, '_uid': doc.id};
                peopleList.add(merged);
                _peopleInfo[doc.id] = merged;
                if (locData['lat'] is num && locData['lng'] is num) {
                  final isMe = doc.id == myUid;
                  _loadMarker(doc.id, profile['name']?.toString() ?? '', isMe ? Colors.red : AppTheme.effectivePrimary);
                  targets[doc.id] = LatLng(
                    (locData['lat'] as num).toDouble(),
                    (locData['lng'] as num).toDouble(),
                  );
                }
              }

              // Drop stale entries for students removed from the query.
              _peopleInfo.removeWhere((id, _) => !queryIds.contains(id));

              // SOS students bubble to the top.
              peopleList.sort((a, b) {
                final aHasSos = _pendingSosIds.contains(a['_uid'] as String? ?? '');
                final bHasSos = _pendingSosIds.contains(b['_uid'] as String? ?? '');
                if (aHasSos == bHasSos) return 0;
                return aHasSos ? -1 : 1;
              });

              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _tracker.setTargets(targets);
              });

              return Stack(
                children: [
                  AnimatedBuilder(
                    animation: _tracker,
                    builder: (ctx, _) {
                      final Set<Marker> markers = {};
                      for (final entry in _peopleInfo.entries) {
                        final uid = entry.key;
                        final data = entry.value;
                        // Own marker: use local GPS directly — no Firestore round-trip, zero lag.
                        final LatLng? pos = (uid == myUid && _lastKnownPos != null)
                            ? LatLng(_lastKnownPos!.latitude, _lastKnownPos!.longitude)
                            : _tracker.current(uid);
                        if (pos == null) continue;
                        markers.add(Marker(
                          markerId: MarkerId(uid),
                          position: pos,
                          infoWindow: InfoWindow(title: data['name']?.toString() ?? ''),
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
                          _zoomToMe();
                        },
                      );
                    },
                  ),
                  if (_nextStopName != null)
                    Positioned(
                      top: kToolbarHeight + MediaQuery.of(context).padding.top + 8,
                      left: 16,
                      right: 16,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: const [BoxShadow(color: Colors.black12, blurRadius: 8, offset: Offset(0, 2))],
                        ),
                        child: Row(
                          children: [
                            Icon(
                              _atStop ? Icons.location_on_rounded : Icons.navigation_rounded,
                              color: _atStop ? Colors.orange : AppTheme.effectivePrimary,
                              size: 18,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _nextStopName!,
                                    style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.secondaryColor),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    _atStop ? 'Next destination' : 'Next stop',
                                    style: TextStyle(fontSize: 10, color: Colors.grey.shade500),
                                  ),
                                ],
                              ),
                            ),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                              decoration: BoxDecoration(
                                color: (_atStop ? Colors.orange : AppTheme.effectivePrimary).withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                _atStop ? 'Waiting' : _liveEta,
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.bold,
                                  color: _atStop ? Colors.orange : AppTheme.effectivePrimary,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  Positioned(
                    right: 16,
                    bottom: 200,
                    child: FloatingActionButton.small(
                      heroTag: 'teacher_map_zoom_to_me',
                      backgroundColor: Colors.white,
                      onPressed: _zoomToMe,
                      tooltip: "Center on my location",
                      child: Icon(Icons.my_location_rounded, color: AppTheme.effectivePrimary),
                    ),
                  ),
                  DraggableScrollableSheet(
                    initialChildSize: 0.3,
                    minChildSize: 0.15,
                    maxChildSize: 0.8,
                    builder: (context, scrollController) {
                      return Container(
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                          boxShadow: [BoxShadow(blurRadius: 20, color: Colors.black26)],
                        ),
                        child: Column(
                          children: [
                            Container(
                              margin: const EdgeInsets.symmetric(vertical: 12),
                              width: 40,
                              height: 4,
                              decoration: BoxDecoration(
                                  color: Colors.grey.shade300,
                                  borderRadius: BorderRadius.circular(10)),
                            ),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  const Text("People",
                                      style: TextStyle(
                                          fontSize: 18,
                                          fontWeight: FontWeight.bold,
                                          color: AppTheme.secondaryColor)),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Text("${peopleList.length} tracked",
                                        style: TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.w600,
                                            color: AppTheme.effectivePrimary)),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              child: ListView.separated(
                                controller: scrollController,
                                padding: const EdgeInsets.symmetric(horizontal: 16),
                                itemCount: peopleList.length,
                                separatorBuilder: (_, __) =>
                                    Divider(color: Colors.grey.shade100, height: 1),
                                itemBuilder: (context, index) {
                                  final person = peopleList[index];
                                  final String uid = person['_uid'] ?? '';
                                  final int battery = (person['battery'] as num?)?.toInt() ?? 0;
                                  final String activity = person['lastActivity'] ?? 'Unknown';
                                  final bool isMe = uid == myUid;
                                  final bool hasSos = _pendingSosIds.contains(uid);
                                  final Color avatarColor = hasSos ? Colors.red : (isMe ? Colors.red : AppTheme.effectivePrimary);

                                  // Activity icon
                                  IconData actIcon;
                                  Color actColor;
                                  if (activity.contains('WiFi')) {
                                    actIcon = Icons.wifi_rounded;
                                    actColor = Colors.green;
                                  } else if (activity.contains('Mobile')) {
                                    actIcon = Icons.signal_cellular_alt_rounded;
                                    actColor = Colors.blue;
                                  } else {
                                    actIcon = Icons.wifi_off_rounded;
                                    actColor = Colors.red;
                                  }

                                  return InkWell(
                                    borderRadius: BorderRadius.circular(12),
                                    onTap: () {
                                      final pos = _tracker.current(uid);
                                      if (pos != null) {
                                        _mapController?.animateCamera(
                                          CameraUpdate.newLatLngZoom(pos, 18),
                                        );
                                      }
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                                      child: Row(
                                        children: [
                                          CircleAvatar(
                                            radius: 22,
                                            backgroundColor: avatarColor.withValues(alpha: 0.12),
                                            child: Text(
                                              (person['name'] as String? ?? '?')[0].toUpperCase(),
                                              style: TextStyle(color: avatarColor, fontWeight: FontWeight.bold, fontSize: 16),
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text(
                                                  person['name']?.toString() ?? '',
                                                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: AppTheme.secondaryColor),
                                                ),
                                                const SizedBox(height: 2),
                                                Row(
                                                  children: [
                                                    Icon(actIcon, size: 11, color: actColor),
                                                    const SizedBox(width: 3),
                                                    Flexible(
                                                      child: Text(
                                                        activity,
                                                        style: TextStyle(fontSize: 10, color: actColor),
                                                        overflow: TextOverflow.ellipsis,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                          Column(
                                            crossAxisAlignment: CrossAxisAlignment.end,
                                            children: [
                                              Row(children: [
                                                Icon(
                                                  battery > 20 ? Icons.battery_full_rounded : Icons.battery_alert_rounded,
                                                  color: battery > 20 ? Colors.green : Colors.red,
                                                  size: 14,
                                                ),
                                                const SizedBox(width: 3),
                                                Text(
                                                  '$battery%',
                                                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.secondaryColor),
                                                ),
                                              ]),
                                              const SizedBox(height: 2),
                                              Text(
                                                person['role']?.toString().toUpperCase() ?? '',
                                                style: TextStyle(fontSize: 9, color: Colors.grey.shade400, letterSpacing: 0.5),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(width: 4),
                                          if (hasSos)
                                            const Padding(
                                              padding: EdgeInsets.only(right: 4),
                                              child: Icon(Icons.warning_amber_rounded, size: 18, color: Colors.red),
                                            ),
                                          Icon(Icons.my_location_rounded, size: 14, color: Colors.grey.shade300),
                                        ],
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class StudentSelectorModal extends StatefulWidget {
  final String tripId;
  final int busIndex;
  final List<String> alreadyAssignedIds;

  const StudentSelectorModal({super.key, required this.tripId, required this.busIndex, required this.alreadyAssignedIds});

  @override
  State<StudentSelectorModal> createState() => _StudentSelectorModalState();
}

class _StudentSelectorModalState extends State<StudentSelectorModal> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _allStudents = [];
  List<Map<String, dynamic>> _filteredStudents = [];

  /// Active "Grade · Section" filter, or null for the whole roster.
  String? _sectionFilter;
  Set<String> _selectedIds = {};
  bool _isLoading = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _selectedIds = widget.alreadyAssignedIds.toSet();
    _fetchStudents();
    _searchController.addListener(_filterStudents);
  }

  Future<void> _fetchStudents() async {
    try {
      // Scope to the school that owns this trip. Teachers carry no schoolId of
      // their own, so the trip is the authority on which roster applies; trips
      // predating school scoping fall back to the unscoped list.
      String? schoolId;
      try {
        final trip =
            await FirebaseFirestore.instance.collection('trips').doc(widget.tripId).get();
        schoolId = (trip.data()?['schoolId'] as String?)?.trim();
        if (schoolId != null && schoolId.isEmpty) schoolId = null;
      } catch (_) {/* fall through to the unscoped query */}

      Query<Map<String, dynamic>> query = FirebaseFirestore.instance
          .collection('users')
          .where('role', isEqualTo: 'student');
      if (schoolId != null) query = query.where('schoolId', isEqualTo: schoolId);

      final snapshot = await query.get();
      final students = snapshot.docs.map((doc) {
        final data = doc.data();
        return {
          'id': doc.id,
          'name': data['name'] ?? 'Unknown',
          'lrn': data['lrn'] ?? 'N/A',
          // Needed so a whole section can be assigned at once.
          'gradeLevel': (data['gradeLevel'] ?? '').toString(),
          'section': (data['section'] ?? '').toString(),
        };
      }).toList();
      if (!mounted) return;
      setState(() { _allStudents = students; _filteredStudents = students; _isLoading = false; });
    } catch (e) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Distinct "Grade · Section" groups in the roster, for the filter dropdown.
  List<String> get _sectionOptions {
    final set = <String>{};
    for (final s in _allStudents) {
      final label = _groupLabel(s);
      if (label.isNotEmpty) set.add(label);
    }
    return set.toList()..sort();
  }

  String _groupLabel(Map<String, dynamic> s) {
    final grade = (s['gradeLevel'] ?? '').toString().trim();
    final section = (s['section'] ?? '').toString().trim();
    return [grade, section].where((v) => v.isNotEmpty).join(' · ');
  }

  void _filterStudents() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredStudents = _allStudents.where((s) {
        final matchesText = s['name'].toString().toLowerCase().contains(query) ||
            s['lrn'].toString().toLowerCase().contains(query);
        final matchesGroup = _sectionFilter == null || _groupLabel(s) == _sectionFilter;
        return matchesText && matchesGroup;
      }).toList();
    });
  }

  /// Ticks everyone currently listed — assigning a section should not mean
  /// forty individual taps.
  void _selectAllFiltered() {
    setState(() {
      for (final s in _filteredStudents) {
        _selectedIds.add(s['id'].toString());
      }
    });
  }

  /// Unticks only what is listed, leaving other sections alone.
  void _clearFiltered() {
    setState(() {
      for (final s in _filteredStudents) {
        _selectedIds.remove(s['id'].toString());
      }
    });
  }

  Future<void> _saveAssignments() async {
    setState(() => _isSaving = true);
    try {
      DocumentReference tripRef = FirebaseFirestore.instance.collection('trips').doc(widget.tripId);
      DocumentSnapshot tripSnapshot = await tripRef.get();
      if (!tripSnapshot.exists) return;

      List<dynamic> buses = List.from(tripSnapshot['buses'] ?? []);
      Map<String, dynamic> myBus = Map<String, dynamic>.from(buses[widget.busIndex]);
      List existingPassengers = List.from(myBus['passengers'] ?? []);

      // Build the new passenger list. Preserve every field the admin (or earlier
      // edits) already set on the passenger -- seatNumber, attendance, status,
      // etc. -- and only fill in defaults for newly added students.
      final Map<String, Map<String, dynamic>> existingById = {
        for (final p in existingPassengers)
          (p['id'] as String): Map<String, dynamic>.from(p as Map),
      };

      final List<Map<String, dynamic>> passengersToSave = [];
      for (final s in _allStudents) {
        final String id = s['id'] as String;
        if (!_selectedIds.contains(id)) continue;
        if (existingById.containsKey(id)) {
          // Carry over admin's seat / attendance / etc., but refresh basic display fields.
          final merged = Map<String, dynamic>.from(existingById[id]!);
          merged['name'] = s['name'];
          merged['lrn'] = s['lrn'];
          passengersToSave.add(merged);
        } else {
          passengersToSave.add({
            'id': id,
            'name': s['name'],
            'lrn': s['lrn'],
            'status': 'absent',
          });
        }
      }

      myBus['passengers'] = passengersToSave;
      buses[widget.busIndex] = myBus;

      await tripRef.update({'buses': buses});

      // Keep the bus group chat membership in sync with the new passenger list.
      await ChatSync.syncTripChats(
        tripId: widget.tripId,
        tripTitle: (tripSnapshot.data() as Map<String, dynamic>?)?['title']?.toString() ?? 'Field Trip',
        buses: buses,
      );

      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        content: Text("Assigned ${passengersToSave.length} students."),
        backgroundColor: Colors.green,
      ));
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("Error: $e"), backgroundColor: Colors.red));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.88,
      child: Column(
        children: [
          Container(
            margin: const EdgeInsets.only(top: 12, bottom: 4),
            width: 40, height: 4,
            decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(10)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 12, 16, 0),
            child: Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("Assign Students", style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.secondaryColor)),
                      SizedBox(height: 2),
                      Text("Select students for this bus", style: TextStyle(fontSize: 12, color: Colors.grey)),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(color: Colors.grey.shade100, shape: BoxShape.circle),
                    child: const Icon(Icons.close, size: 18, color: AppTheme.secondaryColor),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                prefixIcon: Icon(Icons.search_rounded, color: Colors.grey.shade400),
                hintText: "Search by name or LRN--",
              ),
            ),
          ),
          if (_sectionOptions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String?>(
                    initialValue: _sectionFilter,
                    isDense: true,
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.filter_alt_outlined, size: 18),
                      contentPadding:
                          const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(9)),
                    ),
                    items: [
                      const DropdownMenuItem<String?>(
                        value: null,
                        child: Text('All sections', style: TextStyle(fontSize: 13)),
                      ),
                      for (final opt in _sectionOptions)
                        DropdownMenuItem<String?>(
                          value: opt,
                          child: Text(opt, style: const TextStyle(fontSize: 13)),
                        ),
                    ],
                    onChanged: (v) {
                      setState(() => _sectionFilter = v);
                      _filterStudents();
                    },
                  ),
                ),
                const SizedBox(width: 8),
                TextButton.icon(
                  onPressed: _filteredStudents.isEmpty ? null : _selectAllFiltered,
                  icon: const Icon(Icons.done_all_rounded, size: 17),
                  label: Text(
                    _sectionFilter == null
                        ? 'Select all'
                        : 'Select section (${_filteredStudents.length})',
                    style: const TextStyle(fontSize: 12.5),
                  ),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(0, 40),
                    foregroundColor: AppTheme.effectivePrimary,
                  ),
                ),
              ]),
            ),
          if (_selectedIds.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: Row(
                children: [
                  Icon(Icons.check_circle_rounded, size: 14, color: AppTheme.effectivePrimary),
                  const SizedBox(width: 6),
                  Text("${_selectedIds.length} selected",
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.effectivePrimary)),
                  const Spacer(),
                  if (_filteredStudents.any((s) => _selectedIds.contains(s['id'].toString())))
                    TextButton(
                      onPressed: _clearFiltered,
                      style: TextButton.styleFrom(
                        minimumSize: const Size(0, 28),
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        foregroundColor: Colors.grey.shade600,
                      ),
                      child: Text(
                        _sectionFilter == null ? 'Clear all' : 'Clear section',
                        style: const TextStyle(fontSize: 11.5),
                      ),
                    ),
                ],
              ),
            ),

          const SizedBox(height: 8),

          Expanded(
            child: _isLoading
                ? Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary))
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _filteredStudents.length,
                    separatorBuilder: (_, __) => Divider(color: Colors.grey.shade100, height: 1),
                    itemBuilder: (ctx, i) {
                      final s = _filteredStudents[i];
                      final bool isSelected = _selectedIds.contains(s['id']);
                      return InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: () => setState(() => isSelected ? _selectedIds.remove(s['id']) : _selectedIds.add(s['id'])),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                          child: Row(
                            children: [
                              AnimatedContainer(
                                duration: const Duration(milliseconds: 150),
                                width: 22, height: 22,
                                decoration: BoxDecoration(
                                  color: isSelected ? AppTheme.effectivePrimary : Colors.transparent,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: isSelected ? AppTheme.effectivePrimary : Colors.grey.shade300, width: 1.5),
                                ),
                                child: isSelected ? const Icon(Icons.check_rounded, size: 14, color: Colors.white) : null,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(s['name'],
                                        style: TextStyle(fontWeight: FontWeight.w500, fontSize: 14,
                                            color: isSelected ? AppTheme.secondaryColor : Colors.grey.shade700)),
                                    Text("LRN: ${s['lrn']}",
                                        style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),

          Padding(
            padding: EdgeInsets.fromLTRB(20, 12, 20, MediaQuery.of(context).padding.bottom + 16),
            child: SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: _isSaving ? null : _saveAssignments,
                child: _isSaving
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text("Save Assignments"),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class TeacherProfileTab extends StatelessWidget {
  const TeacherProfileTab({super.key});

  @override
  Widget build(BuildContext context) {
    final String uid = FirebaseAuth.instance.currentUser!.uid;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        titleSpacing: 24,
        title: const Text("Profile", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22, color: AppTheme.secondaryColor)),
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
                    content: const Text("You'll need to sign in again to access your trips."),
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
                  Navigator.pushAndRemoveUntil(context,
                      MaterialPageRoute(builder: (_) => const MobileLoginView()), (r) => false);
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
          final String name = data['name'] ?? 'Teacher';
          final String email = data['email'] ?? '';

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
                Text(name, style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.secondaryColor)),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text("Teacher", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.effectivePrimary)),
                ),

                const SizedBox(height: 28),

                _ProfileInfoCard(
                  icon: Icons.person_outline_rounded,
                  label: "Full Name",
                  value: name,
                ),
                const SizedBox(height: 12),
                _ProfileInfoCard(
                  icon: Icons.email_outlined,
                  label: "Email Address",
                  value: email,
                ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const SettingsView(allowEmergencySoundUpload: true),
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
            width: 40, height: 40,
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

// â"€â"€â"€ Slide-to-confirm widget â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€
class _SlideToConfirm extends StatefulWidget {
  final String label;
  final Color color;
  final VoidCallback onConfirmed;

  const _SlideToConfirm({required this.label, required this.color, required this.onConfirmed});

  @override
  State<_SlideToConfirm> createState() => _SlideToConfirmState();
}

class _SlideToConfirmState extends State<_SlideToConfirm> {
  double _dragX = 0;
  double _maxDrag = 250; // updated on first frame
  static const double _thumbSize = 48;
  final GlobalKey _trackKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateMaxDrag());
  }

  void _updateMaxDrag() {
    final box = _trackKey.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && mounted) {
      setState(() => _maxDrag = box.size.width - _thumbSize - 8);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      key: _trackKey,
      height: 52,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(30),
        gradient: LinearGradient(
          colors: [widget.color.withValues(alpha: 0.15), widget.color.withValues(alpha: 0.05)],
        ),
        border: Border.all(color: widget.color.withValues(alpha: 0.3)),
      ),
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          Center(
            child: Text(
              widget.label,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: widget.color.withValues(alpha: 0.7)),
            ),
          ),
          Positioned(
            left: 4 + _dragX,
            child: GestureDetector(
              onHorizontalDragUpdate: (d) {
                setState(() {
                  _dragX = (_dragX + d.delta.dx).clamp(0, _maxDrag);
                });
                if (_dragX >= _maxDrag) {
                  widget.onConfirmed();
                  setState(() => _dragX = 0);
                }
              },
              onHorizontalDragEnd: (_) => setState(() => _dragX = 0),
              child: Container(
                width: _thumbSize,
                height: _thumbSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [widget.color, widget.color.withValues(alpha: 0.8)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [BoxShadow(color: widget.color.withValues(alpha: 0.4), blurRadius: 8, offset: const Offset(0, 3))],
                ),
                child: const Icon(Icons.chevron_right_rounded, color: Colors.white, size: 28),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// â"€â"€â"€ Teacher Students Tab â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€
class TeacherStudentsTab extends StatefulWidget {
  const TeacherStudentsTab({super.key});

  @override
  State<TeacherStudentsTab> createState() => _TeacherStudentsTabState();
}

class _TeacherStudentsTabState extends State<TeacherStudentsTab> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      appBar: AppBar(
        title: const Text("My Students", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: AppTheme.secondaryColor)),
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('trips')
            .where('allMemberIds', arrayContains: uid)
            .snapshots(),
        builder: (context, tripSnap) {
          if (!tripSnap.hasData) return Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary));

          // Only the buses this teacher actually leads — a teacher sees the
          // contact details of the children in their care, and no one else's.
          final Set<String> studentIds = {};
          for (final doc in tripSnap.data!.docs) {
            final tripData = doc.data() as Map<String, dynamic>?;
            if (tripData?['status'] == 'completed') continue;
            final buses = asList(tripData?['buses']);
            for (final b in buses) {
              if (b is! Map) continue;
              if (b['mainTeacher']?['id'] == uid || b['coTeacher']?['id'] == uid) {
                for (final p in asList(b['passengers'])) {
                  if (p is Map && p['id'] != null) studentIds.add(p['id'].toString());
                }
              }
            }
          }

          if (studentIds.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.people_outline_rounded, size: 56, color: Colors.grey),
                  SizedBox(height: 12),
                  Text("No active trip students", style: TextStyle(color: Colors.grey, fontSize: 15)),
                ],
              ),
            );
          }

          return _ChunkedUserStream(
            ids: studentIds.toList(),
            builder: (context, students, loaded) {
              if (!loaded) {
                return Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary));
              }
              return _StudentCards(
                students: students,
                search: _search,
                onSearch: (v) => setState(() => _search = v.toLowerCase().trim()),
                onShowQR: _showStudentQR,
              );
            },
          );
        },
      ),
    );
  }

  void _showStudentQR(BuildContext context, String name, String lrn, String studentId, String code) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(name, style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.secondaryColor), textAlign: TextAlign.center),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: AppTheme.effectivePrimary.withValues(alpha: 0.2), width: 2),
                borderRadius: BorderRadius.circular(16),
              ),
              child: CustomPaint(
                size: const Size(200, 200),
                painter: QrPainter(
                  data: '{"studentId":"$studentId","name":"$name","lrn":"$lrn","code":"$code"}',
                  version: QrVersions.auto,
                  eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black),
                  dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Colors.black),
                ),
              ),
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: AppTheme.effectivePrimary.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text("Code: $code",
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, letterSpacing: 1.2, color: AppTheme.effectivePrimary)),
            ),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text("Close"))],
      ),
    );
  }
}

/// Streams a set of user documents in `whereIn`-sized chunks.
///
/// Firestore caps `whereIn` at 30 values, so a single query silently failed the
/// moment a teacher's buses carried more students than that — the list came
/// back empty rather than short. Each chunk gets its own listener and the
/// results are merged as they arrive.
class _ChunkedUserStream extends StatefulWidget {
  final List<String> ids;
  final Widget Function(BuildContext, List<DocumentSnapshot>, bool loaded) builder;

  const _ChunkedUserStream({required this.ids, required this.builder});

  @override
  State<_ChunkedUserStream> createState() => _ChunkedUserStreamState();
}

class _ChunkedUserStreamState extends State<_ChunkedUserStream> {
  static const _chunkSize = 30;

  final _subs = <StreamSubscription<QuerySnapshot>>[];
  final _byChunk = <int, List<DocumentSnapshot>>{};
  int _chunkCount = 0;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(covariant _ChunkedUserStream old) {
    super.didUpdateWidget(old);
    // Re-subscribe only when the roster actually changes; a rebuild with the
    // same passengers would otherwise tear down and rebuild every listener.
    final a = old.ids.toSet();
    final b = widget.ids.toSet();
    if (a.length != b.length || !a.containsAll(b)) _subscribe();
  }

  void _subscribe() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _byChunk.clear();

    final ids = widget.ids;
    _chunkCount = (ids.length / _chunkSize).ceil();
    for (var i = 0; i < _chunkCount; i++) {
      final chunk = ids.skip(i * _chunkSize).take(_chunkSize).toList();
      final index = i;
      _subs.add(
        FirebaseFirestore.instance
            .collection('users')
            .where(FieldPath.documentId, whereIn: chunk)
            .snapshots()
            .listen((snap) {
          if (!mounted) return;
          setState(() => _byChunk[index] = snap.docs.where((d) => d.exists).toList());
        }, onError: (_) {
          if (!mounted) return;
          setState(() => _byChunk[index] = const []);
        }),
      );
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final loaded = _byChunk.length == _chunkCount;
    final all = <DocumentSnapshot>[
      for (var i = 0; i < _chunkCount; i++) ...(_byChunk[i] ?? const []),
    ]..sort((a, b) {
        final an = ((a.data() as Map<String, dynamic>?)?['name'] ?? '').toString().toLowerCase();
        final bn = ((b.data() as Map<String, dynamic>?)?['name'] ?? '').toString().toLowerCase();
        return an.compareTo(bn);
      });
    return widget.builder(context, all, loaded);
  }
}

/// The student list itself, with the contact details a teacher needs on a trip.
class _StudentCards extends StatelessWidget {
  final List<DocumentSnapshot> students;
  final String search;
  final ValueChanged<String> onSearch;
  final void Function(BuildContext, String, String, String, String) onShowQR;

  const _StudentCards({
    required this.students,
    required this.search,
    required this.onSearch,
    required this.onShowQR,
  });

  @override
  Widget build(BuildContext context) {
    final filtered = search.isEmpty
        ? students
        : students.where((d) {
            final m = d.data() as Map<String, dynamic>? ?? const {};
            return [m['name'], m['lrn'], m['email'], m['section']]
                .any((v) => (v ?? '').toString().toLowerCase().contains(search));
          }).toList();

    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
        child: TextField(
          onChanged: onSearch,
          decoration: InputDecoration(
            hintText: 'Search by name, LRN or section…',
            prefixIcon: const Icon(Icons.search_rounded, size: 20),
            isDense: true,
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Colors.grey.shade200),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: Colors.grey.shade200),
            ),
          ),
        ),
      ),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            search.isEmpty
                ? '${students.length} ${students.length == 1 ? "student" : "students"} on your buses'
                : '${filtered.length} of ${students.length} students',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
        ),
      ),
      Expanded(
        child: filtered.isEmpty
            ? Center(
                child: Text('No students match "$search".',
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
              )
            : ListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  final doc = filtered[index];
                  final data = doc.data() as Map<String, dynamic>? ?? const {};
                  final String name = (data['name'] ?? 'Unknown').toString();
                  final String lrn = (data['lrn'] ?? '').toString();
                  final String email = (data['email'] ?? '').toString();
                  final String section = (data['section'] ?? '').toString();
                  final String grade = (data['gradeLevel'] ?? '').toString();
                  final initials = name.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).map((w) => w[0].toUpperCase()).join();
                  final suffix = lrn.length >= 6 ? lrn.substring(lrn.length - 6) : lrn;
                  final code = '$initials-$suffix';
                  final gradeSection = [grade, section].where((s) => s.isNotEmpty).join(' · ');

                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                    elevation: 0,
                    color: Colors.white,
                    child: Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ListTile(
                            contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            leading: CircleAvatar(
                              backgroundColor: AppTheme.effectivePrimary.withValues(alpha: 0.12),
                              child: Text(name.isNotEmpty ? name[0].toUpperCase() : '?',
                                  style: TextStyle(color: AppTheme.effectivePrimary, fontWeight: FontWeight.bold)),
                            ),
                            title: Text(name, style: TextStyle(fontWeight: FontWeight.w600, color: AppTheme.secondaryColor)),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  [if (lrn.isNotEmpty) 'LRN: $lrn', if (gradeSection.isNotEmpty) gradeSection]
                                      .join('  ·  '),
                                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                                ),
                                if (email.isNotEmpty)
                                  Text(email,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500)),
                                Text("Code: $code",
                                    style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
                              ],
                            ),
                            isThreeLine: true,
                            trailing: IconButton(
                              icon: Icon(Icons.qr_code_rounded, color: AppTheme.effectivePrimary),
                              tooltip: "View QR",
                              onPressed: () => onShowQR(context, name, lrn, doc.id, code),
                            ),
                          ),
                          _GuardianContacts(studentUid: doc.id),
                        ],
                      ),
                    ),
                  );
                },
              ),
      ),
    ]);
  }
}

/// The guardians a school registered for this student, with how to reach them.
///
/// Read from the guardian records rather than the parent's login: the school
/// supplies the mobile number, and registration never asks for one. On a trip
/// the number is the part that matters.
class _GuardianContacts extends StatelessWidget {
  final String studentUid;

  const _GuardianContacts({required this.studentUid});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: GuardianService.ofStudentUid(studentUid),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? const [];
        if (!snap.hasData) return const SizedBox.shrink();
        if (docs.isEmpty) {
          return Padding(
            padding: const EdgeInsets.only(left: 68, bottom: 6),
            child: Text("No linked parents",
                style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
          );
        }

        return Padding(
          padding: const EdgeInsets.only(left: 16, right: 12, bottom: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Divider(height: 1),
              const SizedBox(height: 8),
              Row(children: [
                const Icon(Icons.family_restroom_rounded, size: 14, color: Colors.grey),
                const SizedBox(width: 6),
                Text("Parent / Guardian",
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey.shade600)),
              ]),
              const SizedBox(height: 6),
              for (final g in docs) _guardianTile(g.data()),
            ],
          ),
        );
      },
    );
  }

  Widget _guardianTile(Map<String, dynamic> g) {
    final name = (g['name'] ?? 'Guardian').toString();
    final relationship = (g['relationship'] ?? '').toString();
    final email = (g['email'] ?? '').toString();
    final phone = (g['phone'] ?? '').toString();
    final linked = GuardianService.isLinked(g);

    return Padding(
      padding: const EdgeInsets.only(left: 4, bottom: 8),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(linked ? Icons.verified_user_rounded : Icons.person_outline,
            size: 15,
            color: linked ? const Color(0xFF16A34A) : Colors.grey.shade400),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              relationship.isEmpty ? name : '$name · $relationship',
              style: TextStyle(
                  fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey.shade800),
            ),
            if (phone.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(children: [
                  Icon(Icons.phone_rounded, size: 12, color: AppTheme.effectivePrimary),
                  const SizedBox(width: 5),
                  SelectableText(phone,
                      style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700)),
                ]),
              ),
            if (email.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(children: [
                  Icon(Icons.email_outlined, size: 12, color: Colors.grey.shade500),
                  const SizedBox(width: 5),
                  Expanded(
                    child: SelectableText(email,
                        maxLines: 1,
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                  ),
                ]),
              ),
            if (phone.isEmpty && email.isEmpty)
              Text('No contact details on file',
                  style: TextStyle(fontSize: 11.5, color: AppTheme.errorColor)),
          ]),
        ),
        if (!linked)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text('Not yet linked',
                style: TextStyle(fontSize: 10.5, color: Colors.grey.shade400)),
          ),
      ]),
    );
  }
}

