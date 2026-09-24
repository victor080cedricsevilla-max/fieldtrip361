import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:geolocator/geolocator.dart';
import '../../config/theme.dart';
import '../../widgets/glass_nav_bar.dart';
import '../../widgets/glass_nav_scaffold.dart';
import '../../controllers/auth_controller.dart';
import '../auth/mobile_login_view.dart';
import '../../repositories/directions_repository.dart';
import '../../models/directions_model.dart';
import '../../utils/live_tracker.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../../utils/firestore_utils.dart';
import '../../utils/guardian_service.dart';
import '../../utils/trip_queries.dart';
import '../shared/settings_view.dart';
import '../shared/notification_panel.dart';

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

class ParentDashboard extends StatefulWidget {
  const ParentDashboard({super.key});

  @override
  State<ParentDashboard> createState() => _ParentDashboardState();
}

class _ParentDashboardState extends State<ParentDashboard> {
  int _currentIndex = 0;
  final List<Widget> _screens = [const ParentTripsTab(), const ParentProfileTab()];

  static const _navItems = <GlassNavItem>[
    GlassNavItem(icon: Icons.route_outlined, activeIcon: Icons.route_rounded, label: "Trips"),
    GlassNavItem(icon: Icons.person_outline, activeIcon: Icons.person_rounded, label: "Profile"),
  ];

  @override
  Widget build(BuildContext context) {
    return GlassNavScaffold(
      pages: _screens,
      items: _navItems,
      currentIndex: _currentIndex,
      onTap: (i) => setState(() => _currentIndex = i),
    );
  }
}

class ParentTripsTab extends StatelessWidget {
  const ParentTripsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final String myUid = FirebaseAuth.instance.currentUser!.uid;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        titleSpacing: 24,
        title: const Text("My Children's Trips", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22, color: AppTheme.secondaryColor)),
        actions: const [
          NotificationBell(),
          SizedBox(width: 8),
        ],
      ),
      body: StreamBuilder<DocumentSnapshot>(
        stream: FirebaseFirestore.instance.collection('users').doc(myUid).snapshots(),
        builder: (context, userSnap) {
          if (!userSnap.hasData) return Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary));
          
          List<dynamic> childrenIds = (userSnap.data!.data() as Map<String, dynamic>?)?['children'] ?? [];
          if (childrenIds.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.family_restroom, size: 64, color: Colors.grey.shade300),
                  const SizedBox(height: 16),
                  Text("No children linked", style: TextStyle(fontSize: 16, color: Colors.grey.shade500, fontWeight: FontWeight.w500)),
                  const SizedBox(height: 8),
                  Text("Go to your profile to link your child.", style: TextStyle(fontSize: 13, color: Colors.grey.shade400)),
                ],
              ),
            );
          }

          // Scoped to trips a linked child belongs to — the rules only permit
          // reads that match through children, so the query must say the same.
          return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: TripQueries.ofChildren(
              childrenIds.map((c) => c.toString()).toList(),
            ),
            builder: (context, snapshot) {
              if (!snapshot.hasData) return Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary));

              final myTrips = snapshot.data!.docs.where((doc) {
                final data = doc.data();
                if (data['status'] == 'completed') return false;
                final buses = asList(data['buses']);
                for (var bus in buses) {
                  final List passengers = asList(bus['passengers']);
                  for (var p in passengers) {
                    if (childrenIds.contains(p['id'])) return true;
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
                      Text("No active trips", style: TextStyle(fontSize: 16, color: Colors.grey.shade500, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 8),
                      Text("Your children's trips will appear here.", style: TextStyle(fontSize: 13, color: Colors.grey.shade400)),
                    ],
                  ),
                );
              }

              return ListView.builder(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, GlassNavScaffold.bottomInset),
                itemCount: myTrips.length,
                itemBuilder: (context, index) {
                  var doc = myTrips[index];
                  var data = doc.data();
                  final status = data['status'] ?? 'pending';

                  return GestureDetector(
                    onTap: () {
                      Navigator.push(context, MaterialPageRoute(
                        builder: (_) => ParentTripDetails(tripId: doc.id, tripData: data, childrenIds: childrenIds)
                      ));
                    },
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
          );
        }
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

class ParentTripDetails extends StatefulWidget {
  final String tripId;
  final Map<String, dynamic> tripData;
  final List<dynamic> childrenIds;

  const ParentTripDetails({super.key, required this.tripId, required this.tripData, required this.childrenIds});

  @override
  State<ParentTripDetails> createState() => _ParentTripDetailsState();
}

class _ParentTripDetailsState extends State<ParentTripDetails>
    with TickerProviderStateMixin {
  GoogleMapController? _mapController;
  final Map<String, BitmapDescriptor> _customMarkers = {};
  final Map<String, Map<String, dynamic>> _peopleInfo = {};
  final Set<Polyline> _polylines = {};
  late final LiveTracker _tracker = LiveTracker(vsync: this);

  String _eta = "--";
  String _distance = "--";
  LatLng? _lastTeacherLoc;
  int _lastActiveStop = -2;
  bool _isFetchingRoute = false;

  @override
  void initState() {
    super.initState();
    _fetchChildNames();
  }

  Future<void> _fetchChildNames() async {
    if (widget.childrenIds.isEmpty) return;
    try {
      final ids = widget.childrenIds.map((e) => e.toString()).toList();
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .where(FieldPath.documentId, whereIn: ids)
          .get();
      if (!mounted) return;
      setState(() {
        for (final doc in snap.docs) {
          _peopleInfo[doc.id] = {
            'name': doc.data()['name']?.toString() ?? '',
            'role': 'student',
          };
        }
      });
    } catch (_) {}
  }

  @override
  void dispose() {
    _tracker.dispose();
    super.dispose();
  }

  void _loadMarker(String id, String name, Color color) async {
    if (!_customMarkers.containsKey(id)) {
      BitmapDescriptor icon = await MarkerGenerator.createCustomMarker(name, color);
      if (mounted) setState(() => _customMarkers[id] = icon);
    }
  }

  Future<void> _fetchLiveRoute(LatLng origin, LatLng dest) async {
    if (_isFetchingRoute) return;
    _isFetchingRoute = true;
    try {
      Directions? info = await DirectionsRepository().getDirections(origin: origin, destination: dest);
      if (info != null && mounted) {
        setState(() {
          _eta = info.totalDuration;
          _distance = info.totalDistance;
          _polylines.removeWhere((p) => p.polylineId.value == 'active_route');
          _polylines.add(Polyline(
            polylineId: const PolylineId('active_route'),
            color: AppTheme.effectivePrimary,
            width: 6,
            points: info.polylinePoints.map((e) => LatLng(e.latitude, e.longitude)).toList()
          ));
        });
      }
    } catch (e) {
      debugPrint("Route fetch error: $e");
    } finally {
      _isFetchingRoute = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<DocumentSnapshot>(
      stream: FirebaseFirestore.instance.collection('trips').doc(widget.tripId).snapshots(),
      builder: (context, tripSnap) {
        if (!tripSnap.hasData) return Scaffold(body: Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary)));
        
        var currentTripData = tripSnap.data!.data() as Map<String, dynamic>;

        _polylines.removeWhere((p) => p.polylineId.value == 'full_route');
        if (currentTripData['route'] != null) {
          List<LatLng> pts = (currentTripData['route'] as List).map((p) => LatLng((p['lat'] as num).toDouble(), (p['lng'] as num).toDouble())).toList();
          _polylines.add(Polyline(
            polylineId: const PolylineId('full_route'),
            color: Colors.grey.shade400,
            width: 4,
            points: pts,
            patterns: [PatternItem.dash(20), PatternItem.gap(10)],
          ));
        }

        // Find teacher assigned to the same bus as the parent's children.
        String? teacherUid;
        outer:
        for (final b in asList(currentTripData['buses'])) {
          if (b is! Map) continue;
          for (final p in asList(b['passengers'])) {
            if (p is Map && widget.childrenIds.any((c) => c.toString() == p['id']?.toString())) {
              teacherUid = (b['mainTeacher'] as Map?)?['id']?.toString();
              break outer;
            }
          }
        }
        final List<String> queryIds = [
          ...widget.childrenIds.map((e) => e.toString()),
          if (teacherUid != null) teacherUid,
        ];

        return Scaffold(
          extendBodyBehindAppBar: true,
          appBar: AppBar(
            backgroundColor: Colors.white.withValues(alpha: 0.95),
            elevation: 0,
            leading: IconButton(
              icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: AppTheme.secondaryColor),
              onPressed: () => Navigator.pop(context),
            ),
            title: Text("Trip Dashboard", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: AppTheme.secondaryColor)),
          ),
          body: StreamBuilder<QuerySnapshot>(
            key: ValueKey(queryIds.join(',')),
            stream: FirebaseFirestore.instance.collection('locations').where(FieldPath.documentId, whereIn: queryIds).snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) return Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary));

              List<Map<String, dynamic>> peopleList = [];
              final Map<String, LatLng> targets = {};
              LatLng? teacherLoc;

              for (var doc in snapshot.data!.docs) {
                final locData = doc.data() as Map<String, dynamic>;
                // Capture teacher location for ETA but don't show on parent's map.
                if (doc.id == teacherUid) {
                  if (locData['lat'] is num && locData['lng'] is num) {
                    teacherLoc = LatLng((locData['lat'] as num).toDouble(), (locData['lng'] as num).toDouble());
                  }
                  continue;
                }
                final profile = _peopleInfo[doc.id] ?? {};
                final data = {...profile, ...locData, '_uid': doc.id};
                peopleList.add(data);
                _peopleInfo[doc.id] = data;
                final dynamic rawLat = locData['lat'];
                final dynamic rawLng = locData['lng'];
                if (rawLat is num && rawLng is num) {
                  _loadMarker(doc.id, profile['name']?.toString() ?? '', Colors.blue);
                  targets[doc.id] = LatLng(rawLat.toDouble(), rawLng.toDouble());
                }
              }
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) _tracker.setTargets(targets);
              });

              Set<Circle> circles = {};
              int activeStop = currentTripData['activeStopIndex'] ?? -1;
              List stops = currentTripData['stops'] ?? [];

              if (activeStop != -1 && activeStop < stops.length) {
                var stop = stops[activeStop];
                if (stop['lat'] is num && stop['lng'] is num) {
                  circles.add(Circle(
                    circleId: const CircleId("geofence"),
                    center: LatLng(
                      (stop['lat'] as num).toDouble(),
                      (stop['lng'] as num).toDouble(),
                    ),
                    radius: (stop['geofenceRadius'] is num)
                        ? (stop['geofenceRadius'] as num).toDouble()
                        : 100,
                    fillColor: Colors.green.withValues(alpha: 0.15),
                    strokeColor: Colors.green,
                    strokeWidth: 2,
                  ));
                }
              }

              // Reset ETA whenever the active stop changes.
              if (activeStop != _lastActiveStop) {
                _lastActiveStop = activeStop;
                _lastTeacherLoc = null;
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(() { _eta = '--'; _distance = '--'; });
                });
              }

              // Calculate ETA from teacher's live location to the active stop.
              if (teacherLoc != null && activeStop != -1 && activeStop < stops.length) {
                final stop = stops[activeStop];
                if (stop['lat'] is num && stop['lng'] is num) {
                  final LatLng dest = LatLng(
                    (stop['lat'] as num).toDouble(),
                    (stop['lng'] as num).toDouble(),
                  );
                  if (_lastTeacherLoc == null ||
                      Geolocator.distanceBetween(
                        teacherLoc.latitude, teacherLoc.longitude,
                        _lastTeacherLoc!.latitude, _lastTeacherLoc!.longitude,
                      ) > 20) {
                    _lastTeacherLoc = teacherLoc;
                    _fetchLiveRoute(teacherLoc, dest);
                  }
                }
              }

              return Stack(
                children: [
                  AnimatedBuilder(
                    animation: _tracker,
                    builder: (ctx, _) {
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
                        polylines: _polylines,
                        myLocationButtonEnabled: false,
                        onMapCreated: (c) => _mapController = c,
                      );
                    },
                  ),
                  DraggableScrollableSheet(
                    initialChildSize: 0.35,
                    minChildSize: 0.20,
                    maxChildSize: 0.85,
                    builder: (context, scrollController) {
                      return Container(
                        decoration: const BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                          boxShadow: [BoxShadow(blurRadius: 20, color: Colors.black26)]
                        ),
                        child: ListView(
                          controller: scrollController,
                          padding: EdgeInsets.zero,
                          children: [
                            Center(
                              child: Container(
                                margin: const EdgeInsets.symmetric(vertical: 12),
                                width: 40, height: 4,
                                decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(10))
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 20),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(currentTripData['title'] ?? 'Trip', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: AppTheme.secondaryColor)),
                                  const SizedBox(height: 4),
                                  Text(currentTripData['description'] ?? '', style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
                                  
                                  const SizedBox(height: 16),
                                  Container(
                                    padding: const EdgeInsets.all(16),
                                    decoration: BoxDecoration(
                                      color: AppTheme.effectivePrimary.withValues(alpha: 0.05),
                                      borderRadius: BorderRadius.circular(12),
                                      border: Border.all(color: AppTheme.effectivePrimary.withValues(alpha: 0.2)),
                                    ),
                                    child: Row(
                                      children: [
                                        Container(
                                          padding: const EdgeInsets.all(10),
                                          decoration: BoxDecoration(color: Colors.white, shape: BoxShape.circle),
                                          child: Icon(Icons.access_time_filled, color: AppTheme.effectivePrimary, size: 24),
                                        ),
                                        const SizedBox(width: 14),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(activeStop != -1 ? "Heading to: ${stops[activeStop]['name']}" : "Waiting for teacher...", style: TextStyle(fontWeight: FontWeight.bold, color: AppTheme.secondaryColor)),
                                              if (activeStop != -1) ...[
                                                const SizedBox(height: 4),
                                                Text("ETA: $_eta  --  $_distance", style: TextStyle(fontSize: 13, color: AppTheme.effectivePrimary, fontWeight: FontWeight.w600)),
                                              ],
                                            ],
                                          ),
                                        )
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const Divider(height: 32),
                            
                            // Itinerary Section
                            const Padding(
                              padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
                              child: Text("Itinerary", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.secondaryColor)),
                            ),
                            ...stops.asMap().entries.map((entry) {
                              int i = entry.key;
                              var stop = entry.value;
                              bool isOrigin = (i == 0);
                              bool isReturn = (i == stops.length - 1 && stop['name'].toString().contains("Return"));
                              bool isActive = (i == activeStop);
                              
                              return Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 32, height: 32,
                                      decoration: BoxDecoration(
                                        color: isActive ? AppTheme.effectivePrimary : (isOrigin || isReturn ? Colors.green.shade100 : Colors.grey.shade100),
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(
                                        isOrigin ? Icons.school : (isReturn ? Icons.home_work : Icons.location_on),
                                        size: 16,
                                        color: isActive ? Colors.white : (isOrigin || isReturn ? Colors.green.shade700 : Colors.grey.shade600),
                                      ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(stop['name'], style: TextStyle(fontWeight: isActive ? FontWeight.bold : FontWeight.w600, color: isActive ? AppTheme.effectivePrimary : AppTheme.secondaryColor)),
                                          Row(
                                            children: [
                                              Text(stop['time'] ?? '', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
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
                                        decoration: BoxDecoration(color: AppTheme.effectivePrimary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
                                        child: Text("Current", style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: AppTheme.effectivePrimary)),
                                      )
                                  ],
                                ),
                              );
                            }),

                            const Divider(height: 32),
                            Padding(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                              child: Row(
                                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                children: [
                                  Text("Children Tracker", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.secondaryColor)),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                                      borderRadius: BorderRadius.circular(20),
                                    ),
                                    child: Text("${peopleList.length} child active",
                                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.effectivePrimary)),
                                  ),
                                ],
                              ),
                            ),
                            Builder(builder: (_) {
                              // Build childId → attendance map from trip buses.
                              final Map<String, Map<String, dynamic>> attendanceMap = {};
                              for (final b in asList(currentTripData['buses'])) {
                                if (b is! Map) continue;
                                for (final p in asList(b['passengers'])) {
                                  if (p is! Map) continue;
                                  final id = p['id']?.toString();
                                  if (id == null) continue;
                                  attendanceMap[id] = Map<String, dynamic>.from(p['attendance'] as Map? ?? {});
                                }
                              }
                              final List stops = currentTripData['stops'] ?? [];

                              return ListView.separated(
                                shrinkWrap: true,
                                physics: const NeverScrollableScrollPhysics(),
                                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                                itemCount: peopleList.length,
                                separatorBuilder: (_, __) => Divider(color: Colors.grey.shade100, height: 1),
                                itemBuilder: (context, index) {
                                  final person = peopleList[index];
                                  final String personId = person['_uid'] ?? '';
                                  final int battery = person['battery'] ?? 0;
                                  final String activity = person['lastActivity'] ?? "Unknown";
                                  final att = attendanceMap[personId] ?? {};

                                  // Count how many stops the child is marked present.
                                  int presentCount = 0;
                                  for (int si = 0; si < stops.length; si++) {
                                    if (att['stop_$si'] == true) presentCount++;
                                  }
                                  final bool hasAnyAttendance = presentCount > 0;

                                  return Padding(
                                    padding: const EdgeInsets.symmetric(vertical: 10),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            CircleAvatar(
                                              radius: 22,
                                              backgroundColor: AppTheme.effectivePrimary.withValues(alpha: 0.12),
                                              child: Text(
                                                (person['name'] as String? ?? '?').isNotEmpty
                                                    ? (person['name'] as String)[0].toUpperCase()
                                                    : '?',
                                                style: TextStyle(color: AppTheme.effectivePrimary, fontWeight: FontWeight.bold, fontSize: 16),
                                              ),
                                            ),
                                            const SizedBox(width: 12),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                children: [
                                                  Text(person['name']?.toString() ?? '', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: AppTheme.secondaryColor)),
                                                  const SizedBox(height: 2),
                                                  Text("LRN: ${person['lrn'] ?? ''}", style: TextStyle(fontSize: 10, color: Colors.grey.shade500, letterSpacing: 0.5)),
                                                ],
                                              ),
                                            ),
                                            Column(
                                              crossAxisAlignment: CrossAxisAlignment.end,
                                              children: [
                                                Row(
                                                  children: [
                                                    Icon(battery > 20 ? Icons.battery_full_rounded : Icons.battery_alert_rounded, color: battery > 20 ? Colors.green : Colors.red, size: 14),
                                                    const SizedBox(width: 3),
                                                    Text("$battery%", style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12, color: AppTheme.secondaryColor)),
                                                  ],
                                                ),
                                                const SizedBox(height: 2),
                                                Text(activity, style: TextStyle(color: Colors.grey.shade500, fontSize: 10)),
                                              ],
                                            ),
                                          ],
                                        ),
                                        if (stops.isNotEmpty) ...[
                                          const SizedBox(height: 8),
                                          Row(
                                            children: [
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                                decoration: BoxDecoration(
                                                  color: hasAnyAttendance ? Colors.green.shade50 : Colors.grey.shade100,
                                                  borderRadius: BorderRadius.circular(8),
                                                ),
                                                child: Row(
                                                  mainAxisSize: MainAxisSize.min,
                                                  children: [
                                                    Icon(
                                                      hasAnyAttendance ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                                                      size: 12,
                                                      color: hasAnyAttendance ? Colors.green.shade700 : Colors.grey.shade400,
                                                    ),
                                                    const SizedBox(width: 4),
                                                    Text(
                                                      hasAnyAttendance ? "Present ($presentCount/${stops.length} stops)" : "Not yet scanned",
                                                      style: TextStyle(
                                                        fontSize: 11,
                                                        fontWeight: FontWeight.w600,
                                                        color: hasAnyAttendance ? Colors.green.shade700 : Colors.grey.shade500,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ],
                                          ),
                                        ],
                                      ],
                                    ),
                                  );
                                },
                              );
                            })
                          ],
                        ),
                      );
                    }
                  )
                ],
              );
            },
          )
        );
      }
    );
  }
}

class ParentProfileTab extends StatefulWidget {
  const ParentProfileTab({super.key});
  @override
  State<ParentProfileTab> createState() => _ParentProfileTabState();
}

class _ParentProfileTabState extends State<ParentProfileTab> {
  final _codeController = TextEditingController();
  bool _isSearching = false;

  /// Redeems a school-issued Parent Activation Code.
  ///
  /// This used to search students by a `code` field on their own user document
  /// and write the link straight from the client. A student knows their own
  /// code, so they could register a fake "parent" and attach it to themselves.
  /// Linking now happens only inside `activateGuardianCode`, which resolves the
  /// school, student and guardian from a code the school issued and emailed.
  Future<void> _addStudentByCode() async {
    final code = _codeController.text.trim();
    if (code.isEmpty) return;
    setState(() => _isSearching = true);

    try {
      final result = await GuardianService.activate(code);
      if (!mounted) return;
      Navigator.pop(context);
      final childName = (result['studentName'] ?? 'Your child').toString();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("$childName is now linked to your account."),
        backgroundColor: Colors.green,
      ));
      _codeController.clear();
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.message ?? "That activation code could not be used."),
        backgroundColor: Colors.red,
      ));
    } finally {
      if (mounted) setState(() => _isSearching = false);
    }
  }

  void _showAddChildModal() {
    showDialog(
      context: context,
      builder: (dlgCtx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text("Link a Child"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Your child's school sends you an activation code by email. Enter it here to "
              "follow their trips and see their live location.",
              style: TextStyle(fontSize: 13, height: 1.4, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _codeController,
              keyboardType: TextInputType.text,
              textCapitalization: TextCapitalization.characters,
              autofocus: true,
              decoration: InputDecoration(
                labelText: "Activation code",
                hintText: "From the school's email",
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                prefixIcon: const Icon(Icons.vpn_key_outlined),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dlgCtx), child: const Text("Cancel")),
          StatefulBuilder(
            builder: (ctx, setBtn) => ElevatedButton(
              onPressed: _isSearching ? null : () async {
                setBtn(() => _isSearching = true);
                await _addStudentByCode();
                setBtn(() => _isSearching = false);
              },
              child: _isSearching
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Text("Link by Code"),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    String uid = FirebaseAuth.instance.currentUser!.uid;

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
                    content: const Text("You'll need to sign in again to view your children's trips."),
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
                  Navigator.pushAndRemoveUntil(context, MaterialPageRoute(builder: (_) => const MobileLoginView()), (r) => false);
                }
              },
            ),
          )
        ],
      ),
      body: FutureBuilder<DocumentSnapshot>(
        future: FirebaseFirestore.instance.collection('users').doc(uid).get(),
        builder: (context, userSnapshot) {
          if (!userSnapshot.hasData) return Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary));
          
          var userData = userSnapshot.data!.data() as Map<String, dynamic>?;
          String name = userData?['name'] ?? 'Parent';
          String email = userData?['email'] ?? '';

          return Column(
            children: [
              Container(
                width: double.infinity,
                color: Colors.white,
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
                      child: Text("Parent/Guardian", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.effectivePrimary)),
                    ),
                    const SizedBox(height: 20),
                    Text(email, style: TextStyle(fontSize: 14, color: Colors.grey.shade600)),
                    const SizedBox(height: 16),
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
              ),

              const SizedBox(height: 20),

              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text("Linked Children", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.secondaryColor)),
                          TextButton.icon(
                            onPressed: _showAddChildModal, 
                            icon: const Icon(Icons.add, size: 18), 
                            label: const Text("Add Child")
                          )
                        ],
                      ),
                      const SizedBox(height: 10),
                      Expanded(
                        child: StreamBuilder<DocumentSnapshot>(
                          stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
                          builder: (context, snapshot) {
                            if (!snapshot.hasData) return Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary));
                            List<dynamic> childrenIds = (snapshot.data!.data() as Map<String, dynamic>?)?['children'] ?? [];
                            
                            if (childrenIds.isEmpty) {
                              return Center(
                                child: Text("No students linked yet.\nTap 'Add Child' to link a student.", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade500)),
                              );
                            }

                            return ListView.builder(
                              itemCount: childrenIds.length,
                              itemBuilder: (context, index) => FutureBuilder<DocumentSnapshot>(
                                future: FirebaseFirestore.instance.collection('users').doc(childrenIds[index]).get(),
                                builder: (context, childSnapshot) {
                                  if (!childSnapshot.hasData) return const SizedBox();
                                  var childData = childSnapshot.data!.data() as Map<String, dynamic>?;
                                  if (childData == null) return const SizedBox();
                                  
                                  return Container(
                                    margin: const EdgeInsets.only(bottom: 12),
                                    padding: const EdgeInsets.all(16),
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
                                          child: Icon(Icons.face_retouching_natural, size: 20, color: AppTheme.effectivePrimary),
                                        ),
                                        const SizedBox(width: 14),
                                        Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(childData['name'], style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppTheme.secondaryColor)),
                                            const SizedBox(height: 2),
                                            Text("LRN: ${childData['lrn']}", style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                                          ],
                                        ),
                                      ],
                                    ),
                                  );
                                },
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        }
      ),
    );
  }
}

