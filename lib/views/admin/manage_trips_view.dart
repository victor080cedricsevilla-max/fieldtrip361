import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import '../../config/theme.dart';
import '../../utils/utils.dart';
import '../../utils/firestore_utils.dart';
import '../../models/directions_model.dart';
import '../../repositories/directions_repository.dart';
import 'create_trip_view.dart';

class ManageTripsView extends StatefulWidget {
  const ManageTripsView({super.key});

  @override
  State<ManageTripsView> createState() => _ManageTripsViewState();
}

class _ManageTripsViewState extends State<ManageTripsView> {
  final TextEditingController _searchCtrl = TextEditingController();
  DateTimeRange? _dateRange;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _searchCtrl.addListener(() {
      setState(() => _searchQuery = _searchCtrl.text.trim().toLowerCase());
    });
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _pickDateRange(BuildContext context) async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2020),
      lastDate: DateTime(2030),
      initialDateRange: _dateRange,
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: const ColorScheme.light(
            primary: AppTheme.primaryColor,
            onPrimary: Colors.white,
            surface: Colors.white,
            onSurface: AppTheme.secondaryColor,
          ),
        ),
        child: child!,
      ),
    );
    if (picked != null) setState(() => _dateRange = picked);
  }

  void _clearFilters() {
    _searchCtrl.clear();
    setState(() => _dateRange = null);
  }

  bool _matchesFilters(Map<String, dynamic> data) {
    // Search filter
    if (_searchQuery.isNotEmpty) {
      final title = (data['title'] ?? '').toString().toLowerCase();
      final date = (data['date'] ?? '').toString().toLowerCase();
      if (!title.contains(_searchQuery) && !date.contains(_searchQuery)) return false;
    }
    // Date range filter
    if (_dateRange != null) {
      final dateStr = (data['date'] ?? '').toString();
      // Try to parse trip date (format: MMMM d, yyyy or yyyy-MM-dd)
      DateTime? tripDate;
      try {
        tripDate = DateTime.parse(dateStr);
      } catch (_) {
        // fallback: match raw string against range
      }
      if (tripDate != null) {
        final from = _dateRange!.start;
        final to = _dateRange!.end.add(const Duration(days: 1));
        if (tripDate.isBefore(from) || !tripDate.isBefore(to)) return false;
      }
    }
    return true;
  }

  void _handleEditClick(BuildContext context, String docId, Map<String, dynamic> tripData) {
    Timestamp? createdAt = tripData['createdAt'];
    if (createdAt != null) {
      if (DateTime.now().difference(createdAt.toDate()).inDays > 14) {
        _showPasswordDialog(context, () => _showEditTripDialog(context, docId, tripData));
      } else {
        _showEditTripDialog(context, docId, tripData);
      }
    } else {
      _showEditTripDialog(context, docId, tripData);
    }
  }

  void _showPasswordDialog(BuildContext context, VoidCallback onSuccess) {
    TextEditingController passCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Admin Verification"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text("This trip is older than 14 days. Enter password to continue."),
            const SizedBox(height: 15),
            TextField(controller: passCtrl, obscureText: true, decoration: const InputDecoration(labelText: "Password", border: OutlineInputBorder()))
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () async {
              try {
                await FirebaseAuth.instance.currentUser?.reauthenticateWithCredential(
                  EmailAuthProvider.credential(email: FirebaseAuth.instance.currentUser!.email!, password: passCtrl.text)
                );
                Navigator.pop(ctx);
                onSuccess();
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Incorrect password"), backgroundColor: Colors.red));
              }
            },
            child: const Text("Verify"),
          )
        ],
      ),
    );
  }

  void _showEditTripDialog(BuildContext context, String docId, Map<String, dynamic> tripData) {
    showDialog(context: context, barrierDismissible: false, builder: (ctx) => EditTripDialog(docId: docId, tripData: tripData));
  }

  void _deleteTrip(BuildContext context, String docId, String title) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Delete Trip?"),
        content: Text("Delete '$title'? This action is permanent."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await FirebaseFirestore.instance.collection('trips').doc(docId).delete();
              await LogService.addLog("Delete Trip", "Deleted: $title");
              ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Trip '$title' deleted"), backgroundColor: Colors.green));
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text("Delete"),
          )
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("Trip Management", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        // ── Search & Filter row ──────────────────────────────────────────────
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchCtrl,
                decoration: InputDecoration(
                  hintText: 'Search trips…',
                  prefixIcon: const Icon(Icons.search_rounded, color: AppTheme.primaryColor, size: 20),
                  contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 16),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(30),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(30),
                    borderSide: BorderSide(color: Colors.grey.shade300),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(30),
                    borderSide: const BorderSide(color: AppTheme.primaryColor, width: 1.5),
                  ),
                  filled: true,
                  fillColor: Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton.icon(
              onPressed: () => _pickDateRange(context),
              icon: const Icon(Icons.date_range_rounded, size: 18, color: AppTheme.primaryColor),
              label: Text(
                _dateRange == null
                    ? 'Date Range'
                    : '${_dateRange!.start.year}-${_dateRange!.start.month.toString().padLeft(2,'0')}-${_dateRange!.start.day.toString().padLeft(2,'0')} – ${_dateRange!.end.year}-${_dateRange!.end.month.toString().padLeft(2,'0')}-${_dateRange!.end.day.toString().padLeft(2,'0')}',
                style: const TextStyle(color: AppTheme.primaryColor, fontWeight: FontWeight.w500),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: AppTheme.primaryColor),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30)),
              ),
            ),
            if (_searchQuery.isNotEmpty || _dateRange != null) ...[
              const SizedBox(width: 8),
              IconButton(
                onPressed: _clearFilters,
                icon: const Icon(Icons.close_rounded, color: Colors.red),
                tooltip: 'Clear filters',
              ),
            ],
          ],
        ),
        const SizedBox(height: 16),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('trips').orderBy('createdAt', descending: true).snapshots(),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) return const Center(child: CircularProgressIndicator());
              if (!snapshot.hasData || snapshot.data!.docs.isEmpty) return const Center(child: Text("No trips found."));

              final filtered = snapshot.data!.docs.where((doc) {
                return _matchesFilters(doc.data() as Map<String, dynamic>);
              }).toList();

              if (filtered.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.search_off_rounded, size: 48, color: Colors.grey.shade300),
                      const SizedBox(height: 12),
                      Text('No trips match your filters.',
                          style: TextStyle(color: Colors.grey.shade500, fontWeight: FontWeight.w500)),
                      const SizedBox(height: 8),
                      TextButton(onPressed: _clearFilters, child: const Text('Clear filters')),
                    ],
                  ),
                );
              }

              return ListView.builder(
                itemCount: filtered.length,
                itemBuilder: (context, index) {
                  var data = filtered[index].data() as Map<String, dynamic>;
                  String docId = filtered[index].id;
                  bool isCompleted = data['status'] == "completed";

                  return Card(
                    margin: const EdgeInsets.only(bottom: 15),
                    child: ExpansionTile(
                      leading: Icon(isCompleted ? Icons.check_circle : Icons.directions_bus, color: isCompleted ? Colors.grey : Colors.blue),
                      title: Text(data['title'] ?? "Untitled", style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text("${data['date']} - ${data['status'] ?? 'pending'}"),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (isCompleted) const Icon(Icons.lock, color: Colors.grey)
                          else IconButton(icon: const Icon(Icons.edit, color: Colors.blue), onPressed: () => _handleEditClick(context, docId, data)),
                          const Icon(Icons.expand_more)
                        ],
                      ),
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text("Itinerary", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
                              const SizedBox(height: 5),
                              ...asList(data['stops']).map((stop) => Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Text("- ${stop['time']}: ${stop['name']}"),
                              )),
                              const SizedBox(height: 15),
                              const Text("Buses & Assignments", style: TextStyle(fontWeight: FontWeight.bold, color: Colors.grey)),
                              const SizedBox(height: 5),
                              ...asList(data['buses']).map((bus) => Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text("Bus #${bus['busNo']}", style: const TextStyle(fontWeight: FontWeight.bold)),
                                    Text("Main: ${bus['mainTeacher']?['name'] ?? 'None'}"),
                                    Text("Co-Teacher: ${bus['coTeacher']?['name'] ?? 'None'}"),
                                    Text("Students: ${asList(bus['passengers']).length} assigned"),
                                  ],
                                ),
                              )),
                              const Divider(),
                              Row(
                                children: [
                                  ElevatedButton.icon(
                                    onPressed: () => _showPreview(context, data),
                                    icon: const Icon(Icons.map),
                                    label: const Text("View Map"),
                                  ),
                                  const Spacer(),
                                  OutlinedButton.icon(
                                    onPressed: () => _deleteTrip(context, docId, data['title']),
                                    icon: const Icon(Icons.delete, color: Colors.red),
                                    label: const Text("Delete", style: TextStyle(color: Colors.red)),
                                  )
                                ],
                              ),
                            ]
                          )
                        )
                      ],
                    ),
                  );
                },
              );
            },
          ),
        )
      ],
    );
  }

  void _showPreview(BuildContext context, Map<String, dynamic> data) async {
    Set<Marker> markers = {};
    Set<Circle> circles = {};
    List<dynamic> stops = asList(data['stops']);
    List<LatLng> locations = [];

    for (int i = 0; i < stops.length; i++) {
      var stop = stops[i];
      LatLng position = LatLng((stop['lat'] as num).toDouble(), (stop['lng'] as num).toDouble());
      locations.add(position);
      
      bool isOrigin = (i == 0);
      bool isReturn = (i == stops.length - 1 && stop['name'].toString().contains("Return"));

      markers.add(
        Marker(
          markerId: MarkerId(stop['name']),
          position: position,
          icon: BitmapDescriptor.defaultMarkerWithHue((isOrigin || isReturn) ? BitmapDescriptor.hueGreen : BitmapDescriptor.hueOrange),
          infoWindow: InfoWindow(title: stop['name'], snippet: stop['time']),
        ),
      );

      if (!isOrigin && !isReturn && stop['geofenceRadius'] != null) {
        circles.add(
          Circle(
            circleId: CircleId("geofence_$i"),
            center: position,
            radius: (stop['geofenceRadius'] as num).toDouble(),
            fillColor: Colors.green.withOpacity(0.2),
            strokeColor: Colors.green,
            strokeWidth: 2,
            visible: true,
          ),
        );
      }
    }

    if (locations.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Not enough locations to show route.")));
      return;
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: SizedBox(
          height: 80,
          child: Row(
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 20),
              Text("Loading map..."),
            ],
          ),
        ),
      ),
    );

    LatLng origin = locations.first;
    LatLng destination = locations.last;
    List<LatLng> waypoints = locations.length > 2 ? locations.sublist(1, locations.length - 1) : [];
      
    Directions? info = await DirectionsRepository().getDirections(
      origin: origin, 
      destination: destination, 
      waypoints: waypoints
    );

    if (!context.mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    Set<Polyline> polylines = {};
    if (info != null && info.polylinePoints.isNotEmpty) {
      polylines.add(
        Polyline(
          polylineId: const PolylineId('overview_polyline'),
          color: Colors.blue,
          width: 5,
          points: info.polylinePoints,
        )
      );
    }

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        child: SizedBox(
          height: 650, width: 800,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: const BoxDecoration(color: AppTheme.primaryColor, borderRadius: BorderRadius.only(topLeft: Radius.circular(12), topRight: Radius.circular(12))),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(data['title'], style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold)),
                    IconButton(icon: const Icon(Icons.close, color: Colors.white), onPressed: () => Navigator.pop(ctx)),
                  ],
                ),
              ),
              Expanded(
                child: _MapPreviewWidget(
                  initialTarget: locations.first,
                  markers: markers,
                  circles: circles,
                  polylines: polylines,
                  bounds: info?.bounds,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


/// Edit-mode wrapper around [CreateTripView]. We reuse the create form so
/// editing has identical fields (bus label, capacity, seat assignment, …)
/// and so existing passenger data — especially `seatNumber` — is preserved.
class EditTripDialog extends StatelessWidget {
  final String docId;
  final Map<String, dynamic> tripData;

  const EditTripDialog({super.key, required this.docId, required this.tripData});

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final width = size.width > 1100 ? 1000.0 : size.width * 0.95;
    final height = size.height * 0.92;
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      insetPadding: const EdgeInsets.all(24),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          children: [
            // Header
            Container(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 14),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: Colors.grey.shade100,
                  ),
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 38,
                    height: 38,
                    decoration: BoxDecoration(
                      color: AppTheme.primaryColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.edit_outlined,
                        color: AppTheme.primaryColor, size: 18),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text("Edit Trip",
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: AppTheme.secondaryColor,
                            )),
                        Text(
                          (tripData['title'] ?? '').toString(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
            // Reusable form
            Expanded(
              child: CreateTripView(
                existingDocId: docId,
                initialData: tripData,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Internal Google Map widget used by ManageTripsView's preview dialog.
/// Re-introduced after the legacy edit-form was removed.
class _MapPreviewWidget extends StatefulWidget {
  final LatLng initialTarget;
  final Set<Marker> markers;
  final Set<Circle> circles;
  final Set<Polyline> polylines;
  final LatLngBounds? bounds;

  const _MapPreviewWidget({
    required this.initialTarget,
    required this.markers,
    required this.circles,
    required this.polylines,
    this.bounds,
  });

  @override
  State<_MapPreviewWidget> createState() => _MapPreviewWidgetState();
}

class _MapPreviewWidgetState extends State<_MapPreviewWidget> {
  GoogleMapController? _mapController;
  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GoogleMap(
      initialCameraPosition: CameraPosition(target: widget.initialTarget, zoom: 12),
      markers: widget.markers,
      circles: widget.circles,
      polylines: widget.polylines,
      onMapCreated: (c) {
        _mapController = c;
        if (widget.bounds != null) {
          Future.delayed(const Duration(milliseconds: 500), () {
            if (!_disposed && mounted) {
              _mapController?.animateCamera(
                CameraUpdate.newLatLngBounds(widget.bounds!, 60),
              );
            }
          });
        }
      },
    );
  }
}
