import 'dart:async';
import 'package:cloud_functions/cloud_functions.dart';
import 'dart:ui' as ui;
import 'dart:typed_data';
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
import '../../controllers/auth_controller.dart';
import '../../utils/chat_sync.dart';
import '../../utils/firestore_utils.dart';
import '../../utils/live_tracker.dart';
import '../auth/mobile_login_view.dart';
import '../shared/settings_view.dart';
import '../shared/chat_view.dart';

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
  StreamSubscription<QuerySnapshot>? _geofenceAlertSub;
  String? _watchedTripId;

  @override
  void initState() {
    super.initState();
    _pages = [const TeacherTripsTab(), const ChatListView(), const TeacherProfileTab()];
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
      for (var change in snapshot.docChanges) {
        if (change.type == DocumentChangeType.added) {
          _showEmergencyAlarm(change.doc);
        }
      }
    });
  }

  /// Watches in-progress trips for this teacher. When a student leaves the
  /// geofence (a new alert doc is written to trips/{id}/alerts), plays the
  /// alarm and shows a dialog — regardless of which tab is active.
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
      // Firestore sends ALL existing docs as "added" — we collect their IDs
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
        if (isFirstSnapshot) {
          isFirstSnapshot = false;
          for (final d in alertSnap.docs) seenIds.add(d.id);
          return;
        }
        for (final change in alertSnap.docChanges) {
          if (change.type == DocumentChangeType.added &&
              !seenIds.contains(change.doc.id)) {
            seenIds.add(change.doc.id);
            final data = change.doc.data() as Map<String, dynamic>;
            _showGeofenceAlert(change.doc.reference, data);
          }
        }
      });
    });
  }

  void _showGeofenceAlert(DocumentReference ref, Map<String, dynamic> data) {
    if (!mounted) return;
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
              Navigator.pop(ctx);
            },
            child: const Text('Dismiss'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.orange),
            onPressed: () {
              ref.update({'status': 'acknowledged'});
              _stopEmergencySound();
              Navigator.pop(ctx);
            },
            child: const Text('Acknowledge', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  void _showEmergencyAlarm(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;

    _playEmergencyAlarm();

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
            const Text("EMERGENCY ALERT", style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 18)),
          ],
        ),
        content: Text(
          "${data['studentName']} has pressed the emergency button!",
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
        ),
        actions: [
          TextButton(
            onPressed: () {
              doc.reference.update({'status': 'dismissed'});
              _stopEmergencySound();
              Navigator.pop(ctx);
            },
            child: const Text("Dismiss", style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              doc.reference.update({'status': 'accepted'});
              FlutterRingtonePlayer().stop();
              Navigator.pop(ctx);
            },
            child: const Text("Accept & Rescue", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _buildEmergencyBanner(),
          Expanded(child: _pages[_selectedIndex]),
        ],
      ),
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
          destinations: const [
            NavigationDestination(
              icon: Icon(Icons.route_outlined),
              selectedIcon: Icon(Icons.route, color: AppTheme.primaryColor),
              label: "Trips",
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
        title: const Text("My Trips", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22, color: AppTheme.secondaryColor)),
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
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
            itemCount: myTrips.length,
            itemBuilder: (context, index) {
              final doc = myTrips[index];
              final data = doc.data() as Map<String, dynamic>;
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

  Future<void> _toggleQRGeneration(int stopIndex, bool value, List stops) async {
    try {
      List<dynamic> updatedStops = List.from(stops);
      Map<String, dynamic> targetStop = Map<String, dynamic>.from(updatedStops[stopIndex]);
      targetStop['qrEnabled'] = value;
      updatedStops[stopIndex] = targetStop;

      await FirebaseFirestore.instance.collection('trips').doc(widget.tripId).update({
        'stops': updatedStops,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(value ? "QR Generation Unlocked" : "QR Generation Locked"),
        backgroundColor: value ? Colors.green : Colors.orange,
        duration: const Duration(seconds: 2),
      ));
    } catch (e) {
      debugPrint("QR Toggle Error: $e");
    }
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
                      ? const CircularProgressIndicator(color: AppTheme.primaryColor)
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
      final result = await FirebaseFunctions.instance
          .httpsCallable('redeemAttendanceToken')
          .call({'tokenId': rawData.trim()});
      final data = result.data as Map<String, dynamic>;
      final studentName = (data['studentName'] ?? 'Student').toString();
      if (!ctx.mounted) return;
      if (data['alreadyScanned'] == true) {
        await _showResultDialog(ctx, "Already Scanned", "$studentName already scanned for this stop.", Colors.orange, Icons.info_outline);
      } else {
        await _showResultDialog(ctx, "Success", "Attendance recorded for $studentName!", Colors.green, Icons.check_circle);
      }
    } on FirebaseFunctionsException catch (e) {
      if (!ctx.mounted) return;
      final msg = switch (e.code) {
        'deadline-exceeded' => "QR code expired. Ask student to refresh.",
        'not-found'         => "Invalid QR code or student not in this trip.",
        'already-exists'    => "QR code already used.",
        _                   => e.message ?? "An error occurred.",
      };
      await _showResultDialog(ctx, "Scan Failed", msg, Colors.red, Icons.qr_code_scanner);
    } catch (e) {
      if (!ctx.mounted) return;
      await _showResultDialog(ctx, "Invalid QR", "Could not read QR code.", Colors.red, Icons.qr_code_scanner);
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
            child: const Text("OK", style: TextStyle(color: AppTheme.secondaryColor)),
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
          return const Scaffold(body: Center(child: CircularProgressIndicator(color: AppTheme.primaryColor)));
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
                        color: AppTheme.primaryColor.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.schedule_rounded,
                              size: 16, color: AppTheme.primaryColor),
                          const SizedBox(width: 8),
                          Text(
                            "Estimated total trip time: ${data['totalDuration']}",
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.primaryColor,
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
                  final bool isQrEnabled = stop['qrEnabled'] ?? false;
                  final int presentCount = assignedStudents.where((s) => s['attendance']?['stop_$i'] == true).length;

                  return Container(
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(
                        color: isActive ? AppTheme.primaryColor : Colors.transparent,
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
                            color: isActive ? AppTheme.primaryColor.withValues(alpha: 0.12) : Colors.grey.shade100,
                            shape: BoxShape.circle,
                          ),
                          child: Icon(Icons.location_on_rounded,
                              color: isActive ? AppTheme.primaryColor : Colors.grey.shade400, size: 20),
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
                        trailing: isDone
                            ? const Icon(Icons.check_circle_rounded, color: Colors.green, size: 26)
                            : isAtDest
                                ? GestureDetector(
                                    onTap: () => _departFromStop(context, stops, statuses, i),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                                      decoration: BoxDecoration(
                                        color: Colors.orange.shade50,
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Text("Depart", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: Colors.orange.shade700)),
                                    ),
                                  )
                                : canStartOrArrive
                                    ? GestureDetector(
                                        onTap: () => _arriveAtStop(context, stops, statuses, i),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                                          decoration: BoxDecoration(
                                            color: AppTheme.primaryColor.withValues(alpha: 0.1),
                                            borderRadius: BorderRadius.circular(20),
                                          ),
                                          child: Text(
                                            isOriginStop ? "Start" : "Arrive",
                                            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.primaryColor),
                                          ),
                                        ),
                                      )
                                    : Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                                        decoration: BoxDecoration(
                                          color: Colors.grey.shade100,
                                          borderRadius: BorderRadius.circular(20),
                                        ),
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
                                Row(
                                  children: [
                                    Expanded(
                                      child: Text("Allow QR Generation",
                                          style: TextStyle(fontWeight: FontWeight.w500, fontSize: 13, color: Colors.grey.shade700)),
                                    ),
                                    Switch.adaptive(
                                      value: isQrEnabled,
                                      activeColor: AppTheme.primaryColor,
                                      onChanged: (val) => _toggleQRGeneration(i, val, stops),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 10),

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
                                        icon: const Icon(Icons.map_outlined, size: 18),
                                        label: const Text("View Map"),
                                        style: OutlinedButton.styleFrom(
                                          foregroundColor: AppTheme.primaryColor,
                                          side: BorderSide(color: AppTheme.primaryColor.withValues(alpha: 0.4)),
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
                                    const Text("Attendance", style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13, color: AppTheme.secondaryColor)),
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                                      decoration: BoxDecoration(
                                        color: AppTheme.primaryColor.withValues(alpha: 0.1),
                                        borderRadius: BorderRadius.circular(20),
                                      ),
                                      child: Text(
                                        "$presentCount / ${assignedStudents.length}",
                                        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.primaryColor),
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
                                          color: isPresent ? AppTheme.primaryColor : Colors.grey.shade300,
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
                      color: AppTheme.primaryColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.location_on_rounded,
                        color: AppTheme.primaryColor, size: 18),
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
                            style: const TextStyle(
                              fontSize: 12,
                              color: AppTheme.primaryColor,
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
                              fillColor: AppTheme.primaryColor.withValues(alpha: 0.15),
                              strokeColor: AppTheme.primaryColor,
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

  /// Format a student's name as "C. Sevilla" — initials of all name parts
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
                      color: AppTheme.primaryColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.event_seat_outlined,
                        color: AppTheme.primaryColor, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text("Bus $busLabel — Seat Map",
                            style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: AppTheme.secondaryColor)),
                        Text(
                          "${occupied.length}/$_capacity occupied"
                          "${unseated > 0 ? " · $unseated unseated" : ""}",
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
                                ? AppTheme.primaryColor.withValues(alpha: 0.12)
                                : Colors.grey.shade100,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: taken
                                  ? AppTheme.primaryColor.withValues(alpha: 0.4)
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
                                      ? AppTheme.primaryColor
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
                                  style: const TextStyle(
                                    fontSize: 10,
                                    height: 1.1,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.primaryColor,
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
                        style: const TextStyle(fontSize: 13),
                      ),
                      trailing: currentSeat != null
                          ? Text("Seat $currentSeat",
                              style: const TextStyle(
                                fontSize: 11,
                                color: AppTheme.primaryColor,
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
                              ? AppTheme.primaryColor
                              : (isTaken ? Colors.red.shade100 : Colors.grey.shade100),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isSelected
                                ? AppTheme.primaryColor
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
                color: AppTheme.primaryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(icon, color: AppTheme.primaryColor, size: 22),
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
  Timer? _heartbeatTimer;
  Position? _lastKnownPos;
  final String myUid = FirebaseAuth.instance.currentUser!.uid;
  final Battery _battery = Battery();
  late final LiveTracker _tracker = LiveTracker(vsync: this);

  @override
  void initState() {
    super.initState();
    _startLocationUpdates();
    _listenForAlerts();
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

  Future<void> _publishPosition(Position pos) async {
    int batteryLevel = await _battery.batteryLevel;
    var connectivityResult = await Connectivity().checkConnectivity();
    String netStatus = "Offline";
    if (connectivityResult.toString().contains('mobile')) netStatus = "Mobile Data";
    else if (connectivityResult.toString().contains('wifi')) netStatus = "WiFi Active";

    FirebaseFirestore.instance.collection('users').doc(myUid).update({
      'lat': pos.latitude,
      'lng': pos.longitude,
      'battery': batteryLevel,
      'lastActivity': netStatus,
      'lastUpdate': FieldValue.serverTimestamp(),
    });
  }

  void _startLocationUpdates() {
    // Tight distance filter so walking movements register.
    _positionStream = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 3,
      ),
    ).listen((Position pos) async {
      _lastKnownPos = pos;
      await _publishPosition(pos);

      // Auto-zoom to teacher's location the first time we get a fix.
      if (!_didInitialZoom && _mapController != null) {
        _didInitialZoom = true;
        _mapController!.animateCamera(
          CameraUpdate.newLatLngZoom(LatLng(pos.latitude, pos.longitude), 17),
        );
      }
    });
    // Heartbeat: re-publishes the last position every 5s so observers keep
    // seeing fresh updates even when the device is mostly still or when the
    // OS coalesces getPositionStream events. This is what keeps marker
    // movement smooth on the other side instead of jumping in big chunks.
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      final pos = _lastKnownPos;
      if (pos != null) _publishPosition(pos);
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
    _positionStream?.cancel();
    _tracker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    List<String> studentIds = widget.assignedStudents.map((s) => s['id'].toString()).toList();
    studentIds.add(myUid);

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
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('users')
            .where(FieldPath.documentId, whereIn: studentIds)
            .snapshots(),
        builder: (context, userSnap) {
          if (!userSnap.hasData) return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));

          List<Map<String, dynamic>> peopleList = [];
          final Map<String, LatLng> targets = {};

          for (var doc in userSnap.data!.docs) {
            final data = doc.data() as Map<String, dynamic>;
            peopleList.add(data);
            _peopleInfo[doc.id] = data;
            if (data['lat'] is num && data['lng'] is num) {
              bool isMe = doc.id == myUid;
              Color markerColor = isMe ? Colors.red : AppTheme.primaryColor;
              _loadMarker(doc.id, data['name'], markerColor);
              targets[doc.id] = LatLng(
                (data['lat'] as num).toDouble(),
                (data['lng'] as num).toDouble(),
              );
            }
          }
          // Hand the latest targets to the tracker; it tweens markers smoothly
          // toward these positions over ~1.5s instead of teleporting.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _tracker.setTargets(targets);
          });

          Set<Circle> circles = {};
          int activeStop = widget.tripData['activeStopIndex'] ?? -1;
          if (activeStop != -1) {
            var stop = widget.tripData['stops'][activeStop];
            circles.add(Circle(
              circleId: const CircleId("geofence"),
              center: LatLng(stop['lat'], stop['lng']),
              radius: (stop['geofenceRadius'] as num).toDouble(),
              fillColor: AppTheme.primaryColor.withValues(alpha: 0.15),
              strokeColor: AppTheme.primaryColor,
              strokeWidth: 2,
            ));
          }

          return Stack(
            children: [
              AnimatedBuilder(
                animation: _tracker,
                builder: (ctx, _) {
                  // Always pass a fresh Set<Marker>: Google Maps re-diffs only
                  // when the markers collection differs from the previous build.
                  final Set<Marker> markers = {};
                  for (final entry in _peopleInfo.entries) {
                    final uid = entry.key;
                    final data = entry.value;
                    final pos = _tracker.current(uid);
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
              Positioned(
                right: 16,
                bottom: 200,
                child: FloatingActionButton.small(
                  heroTag: 'teacher_map_zoom_to_me',
                  backgroundColor: Colors.white,
                  onPressed: _zoomToMe,
                  tooltip: "Center on my location",
                  child: const Icon(Icons.my_location_rounded, color: AppTheme.primaryColor),
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
                          width: 40, height: 4,
                          decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(10)),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              const Text("People", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: AppTheme.secondaryColor)),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: AppTheme.primaryColor.withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(20),
                                ),
                                child: Text("${peopleList.length} tracked",
                                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.primaryColor)),
                              ),
                            ],
                          ),
                        ),
                        Expanded(
                          child: ListView.separated(
                            controller: scrollController,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            itemCount: peopleList.length,
                            separatorBuilder: (_, __) => Divider(color: Colors.grey.shade100, height: 1),
                            itemBuilder: (context, index) {
                              final person = peopleList[index];
                              final int battery = person['battery'] ?? 0;
                              final String activity = person['lastActivity'] ?? "Unknown";
                              final bool isMe = person['name'] == (FirebaseAuth.instance.currentUser?.displayName ?? '');
                              final Color avatarColor = isMe ? Colors.red : AppTheme.primaryColor;

                              return Padding(
                                padding: const EdgeInsets.symmetric(vertical: 10),
                                child: Row(
                                  children: [
                                    CircleAvatar(
                                      radius: 22,
                                      backgroundColor: avatarColor.withValues(alpha: 0.12),
                                      child: Text(person['name'][0].toUpperCase(),
                                          style: TextStyle(color: avatarColor, fontWeight: FontWeight.bold, fontSize: 16)),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(person['name'],
                                              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: AppTheme.secondaryColor)),
                                          const SizedBox(height: 2),
                                          Text(person['role'].toString().toUpperCase(),
                                              style: TextStyle(fontSize: 10, color: Colors.grey.shade500, letterSpacing: 0.5)),
                                        ],
                                      ),
                                    ),
                                    Column(
                                      crossAxisAlignment: CrossAxisAlignment.end,
                                      children: [
                                        Row(
                                          children: [
                                            Icon(
                                              battery > 20 ? Icons.battery_full_rounded : Icons.battery_alert_rounded,
                                              color: battery > 20 ? Colors.green : Colors.red,
                                              size: 14,
                                            ),
                                            const SizedBox(width: 3),
                                            Text("$battery%",
                                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.secondaryColor)),
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        Text(activity, style: TextStyle(color: Colors.grey.shade500, fontSize: 10)),
                                      ],
                                    ),
                                  ],
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
      final snapshot = await FirebaseFirestore.instance.collection('users').where('role', isEqualTo: 'student').get();
      final students = snapshot.docs.map((doc) {
        final data = doc.data();
        return {'id': doc.id, 'name': data['name'] ?? 'Unknown', 'lrn': data['lrn'] ?? 'N/A'};
      }).toList();
      setState(() { _allStudents = students; _filteredStudents = students; _isLoading = false; });
    } catch (e) {
      setState(() => _isLoading = false);
    }
  }

  void _filterStudents() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      _filteredStudents = _allStudents.where((s) =>
        s['name'].toString().toLowerCase().contains(query) ||
        s['lrn'].toString().toLowerCase().contains(query)
      ).toList();
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
      // edits) already set on the passenger — seatNumber, attendance, status,
      // etc. — and only fill in defaults for newly added students.
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
                hintText: "Search by name or LRN…",
              ),
            ),
          ),
          if (_selectedIds.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
              child: Row(
                children: [
                  Icon(Icons.check_circle_rounded, size: 14, color: AppTheme.primaryColor),
                  const SizedBox(width: 6),
                  Text("${_selectedIds.length} selected",
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.primaryColor)),
                ],
              ),
            ),

          const SizedBox(height: 8),

          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor))
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
                                  color: isSelected ? AppTheme.primaryColor : Colors.transparent,
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: isSelected ? AppTheme.primaryColor : Colors.grey.shade300, width: 1.5),
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
            return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
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
                  backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12),
                  child: Text(
                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                    style: const TextStyle(fontSize: 36, fontWeight: FontWeight.bold, color: AppTheme.primaryColor),
                  ),
                ),
                const SizedBox(height: 14),
                Text(name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.secondaryColor)),
                const SizedBox(height: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.primaryColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Text("Teacher", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.primaryColor)),
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