import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:file_picker/file_picker.dart';
import 'dart:convert';
import 'dart:typed_data';
import '../../config/theme.dart';
import '../../utils/document_service.dart';
import '../../utils/utils.dart';
import '../../utils/chat_sync.dart';
import '../../utils/firestore_utils.dart';
import '../../utils/school_context.dart';
import '../../models/directions_model.dart';
import '../../repositories/directions_repository.dart';

/// A blank form the admin picked in the trip form but that has not been
/// uploaded yet — the upload waits until the trip has an id to file it under.
class _PickedTemplate {
  final Uint8List bytes;
  final String fileName;
  final String contentType;
  const _PickedTemplate(this.bytes, this.fileName, this.contentType);
}

// ─────────────────────────────────────────────────────────────────────────────
// ROOT WIDGET
// ─────────────────────────────────────────────────────────────────────────────
class CreateTripView extends StatefulWidget {
  /// If [existingDocId] is provided, the form loads [initialData] and saves
  /// with `update(...)`; otherwise it creates a brand new trip with `add(...)`.
  final String? existingDocId;
  final Map<String, dynamic>? initialData;

  const CreateTripView({
    super.key,
    this.existingDocId,
    this.initialData,
  });

  @override
  State<CreateTripView> createState() => _CreateTripViewState();
}

class _CreateTripViewState extends State<CreateTripView> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _dateController = TextEditingController();

  List<Map<String, dynamic>> _stops = [];
  List<Map<String, dynamic>> _buses = [];
  bool _isSaving = false;

  /// Whether parents are pushed a warning when their child leaves a stop's safe
  /// zone. Teachers and the student are always alerted regardless.
  bool _notifyParentsOnGeofence = true;

  /// Blank forms for this trip. Files chosen in the form are held in memory and
  /// only uploaded on save, once the trip has an id to file them under.
  final Map<String, _PickedTemplate> _pickedTemplates = {};

  /// Templates already stored on the trip being edited, keyed by document type.
  final Map<String, Map<String, dynamic>> _existingTemplates = {};

  /// Storage paths of templates replaced or detached during this edit, deleted
  /// once the trip saves successfully.
  final List<String> _removedTemplatePaths = [];

  bool _hasTemplate(String type) =>
      _pickedTemplates.containsKey(type) || _existingTemplates.containsKey(type);

  bool get _isEditing => widget.existingDocId != null;

  @override
  void initState() {
    super.initState();
    if (_isEditing && widget.initialData != null) {
      _loadFromExisting(widget.initialData!);
    } else {
      _resetForm();
    }
  }

  /// Hydrate the form from an existing trip document so editing preserves
  /// every field (including each passenger's `seatNumber`, `attendance`, etc.).
  void _loadFromExisting(Map<String, dynamic> data) {
    _titleController.text = (data['title'] ?? '').toString();
    _descriptionController.text = (data['description'] ?? '').toString();
    _dateController.text = (data['date'] ?? '').toString();
    // Trips created before this setting existed default to on.
    _notifyParentsOnGeofence = data['notifyParentsOnGeofence'] != false;

    _existingTemplates
      ..clear()
      ..addAll(DocumentService.templatesOfTrip(data));
    _pickedTemplates.clear();

    final List rawStops = (data['stops'] as List?) ?? const [];
    _stops = rawStops.map<Map<String, dynamic>>((s) {
      final stop = s as Map;
      return {
        'name': TextEditingController(text: (stop['name'] ?? '').toString()),
        'time': TextEditingController(text: (stop['time'] ?? '').toString()),
        'lat': (stop['lat'] is num) ? (stop['lat'] as num).toDouble() : 0.0,
        'lng': (stop['lng'] is num) ? (stop['lng'] as num).toDouble() : 0.0,
        'radius': TextEditingController(
            text: (stop['geofenceRadius'] ?? 200).toString()),
      };
    }).toList();
    if (_stops.isEmpty) {
      _stops = [
        {
          'name': TextEditingController(text: 'School (Origin)'),
          'time': TextEditingController(text: '07:00 AM'),
          'lat': 0.0,
          'lng': 0.0,
          'radius': TextEditingController(text: '100'),
        },
      ];
    }

    final List rawBuses = asList(data['buses']);
    _buses = rawBuses.map<Map<String, dynamic>>((b) {
      final bus = b as Map;
      final String label = (bus['busLabel'] ?? bus['busNo'] ?? '').toString();
      final int capacity = (bus['capacity'] is int)
          ? bus['capacity'] as int
          : int.tryParse((bus['capacity'] ?? '').toString()) ?? 60;
      final List<dynamic> passengers =
          asList(bus['passengers'])
              .map((p) => Map<String, dynamic>.from(p as Map))
              .toList();
      return {
        'busLabel': TextEditingController(text: label.isEmpty ? '1' : label),
        'capacity': TextEditingController(text: capacity.toString()),
        'mainTeacher':
            bus['mainTeacher'] == null ? null : Map<String, dynamic>.from(bus['mainTeacher'] as Map),
        'coTeacher':
            bus['coTeacher'] == null ? null : Map<String, dynamic>.from(bus['coTeacher'] as Map),
        // Keep every existing passenger field (id/name/lrn/seatNumber/attendance/status)
        // so editing the trip doesn't wipe seat assignments.
        'passengers': passengers,
      };
    }).toList();
    if (_buses.isEmpty) {
      _buses = [
        {
          'busLabel': TextEditingController(text: '1'),
          'capacity': TextEditingController(text: '60'),
          'mainTeacher': null,
          'coTeacher': null,
          'passengers': <Map<String, dynamic>>[],
        },
      ];
    }

    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    _dateController.dispose();
    for (var stop in _stops) {
      stop['name'].dispose();
      stop['time'].dispose();
      stop['radius'].dispose();
    }
    super.dispose();
  }

  void _resetForm() {
    _titleController.clear();
    _descriptionController.clear();
    _dateController.clear();
    _notifyParentsOnGeofence = true;
    _pickedTemplates.clear();
    _existingTemplates.clear();
    _stops = [
      {
        "name": TextEditingController(text: "School (Origin)"),
        "time": TextEditingController(text: "07:00 AM"),
        "lat": 0.0,
        "lng": 0.0,
        "radius": TextEditingController(text: "100"),
      },
      {
        "name": TextEditingController(),
        "time": TextEditingController(),
        "lat": 0.0,
        "lng": 0.0,
        "radius": TextEditingController(text: "200"),
      },
    ];
    _buses = [
      {
        "busLabel": TextEditingController(text: "1"),
        "capacity": TextEditingController(text: "60"),
        "mainTeacher": null,
        "coTeacher": null,
        "passengers": <Map<String, dynamic>>[],
      },
    ];
    if (mounted) setState(() {});
  }

  // ── Date Picker ────────────────────────────────────────────────────────────
  Future<void> _selectDate(BuildContext context) async {
    DateTime now = DateTime.now();
    // Create-mode keeps the original 1-month-ahead constraint; edit-mode lets
    // the admin keep the trip's existing date (which may be in the past).
    DateTime firstDate = _isEditing
        ? DateTime(now.year - 2, 1, 1)
        : DateTime(now.year, now.month + 1, now.day);
    DateTime initial = firstDate;
    final existing = _dateController.text.trim();
    if (existing.isNotEmpty) {
      try {
        initial = DateTime.parse(existing);
      } catch (_) {}
    }
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(firstDate) ? firstDate : initial,
      firstDate: firstDate,
      lastDate: DateTime(now.year + 2),
    );
    if (picked != null) {
      setState(() => _dateController.text =
          "${picked.year}-${picked.month.toString().padLeft(2, '0')}-${picked.day.toString().padLeft(2, '0')}");
    }
  }

  // ── Time Picker ────────────────────────────────────────────────────────────
  Future<TimeOfDay?> _pickTime15(BuildContext context) async {
    TimeOfDay initialTime = TimeOfDay.now();
    int minute = initialTime.minute;
    int roundedMinute = (minute / 15).round() * 15;
    if (roundedMinute == 60) roundedMinute = 0;
    DateTime initialDateTime = DateTime(2023, 1, 1, initialTime.hour, roundedMinute);
    TimeOfDay? selectedTime;

    return await showDialog<TimeOfDay>(
      context: context,
      builder: (ctx) {
        return Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: SizedBox(
            height: 300,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      GestureDetector(
                        onTap: () => Navigator.pop(ctx),
                        child: Text("Cancel", style: TextStyle(color: Colors.grey.shade500, fontWeight: FontWeight.w500)),
                      ),
                      const Text(
                        "Select Time",
                        style: TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppTheme.secondaryColor),
                      ),
                      GestureDetector(
                        onTap: () {
                          selectedTime ??= TimeOfDay.fromDateTime(initialDateTime);
                          Navigator.pop(ctx, selectedTime);
                        },
                        child: Text("Done", style: TextStyle(color: AppTheme.effectivePrimary, fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ),
                ),
                Divider(color: Colors.grey.shade100, height: 1),
                Expanded(
                  child: CupertinoDatePicker(
                    mode: CupertinoDatePickerMode.time,
                    minuteInterval: 15,
                    initialDateTime: initialDateTime,
                    onDateTimeChanged: (dt) => selectedTime = TimeOfDay.fromDateTime(dt),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── Location Picker ────────────────────────────────────────────────────────
  Future<void> _pickLocation(int index) async {
    LatLng center = const LatLng(14.9543, 120.9008);
    if (_stops[index]['lat'] != 0.0) {
      center = LatLng(_stops[index]['lat'], _stops[index]['lng']);
    }
    final result = await showDialog<(LatLng, String)>(
      context: context,
      builder: (ctx) => LocationPickerModal(initialCenter: center),
    );

    if (result != null) {
      final (latLng, searchName) = result;
      bool isReturnTrip = _stops[index]['name'].text.contains("Return");
      bool isDuplicate = false;

      if (!isReturnTrip) {
        for (int i = 0; i < _stops.length; i++) {
          if (i == index) continue;
          if ((_stops[i]['lat'] - latLng.latitude).abs() < 0.0001 &&
              (_stops[i]['lng'] - latLng.longitude).abs() < 0.0001) {
            isDuplicate = true;
            break;
          }
        }
      }

      if (isDuplicate) {
        if (!mounted) return;
        _showSnack("Location already used by another stop.", Colors.red);
        return;
      }

      if (searchName.isNotEmpty) {
        // User selected via search bar — use the search description directly
        setState(() {
          _stops[index]['lat'] = latLng.latitude;
          _stops[index]['lng'] = latLng.longitude;
          _stops[index]['name'].text = searchName;
        });
      } else {
        // User dragged pin without searching — reverse geocode for a name
        setState(() {
          _stops[index]['lat'] = latLng.latitude;
          _stops[index]['lng'] = latLng.longitude;
        });
        _reverseGeocode(index, latLng.latitude, latLng.longitude);
      }
    }
  }

  Future<void> _reverseGeocode(int index, double lat, double lng) async {
    const apiKey = 'AIzaSyAoBhWhuW725rdDv8AnX3GKLHcNIyMFYgg';
    final url = Uri.parse(
      'https://maps.googleapis.com/maps/api/geocode/json?latlng=$lat,$lng&key=$apiKey',
    );
    try {
      final res = await http.get(url);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final results = data['results'] as List?;
        if (results != null && results.isNotEmpty) {
          // Prefer a named result (not a Plus Code) when available
          String address = '';
          for (final r in results) {
            final a = r['formatted_address'] as String? ?? '';
            if (a.isNotEmpty && !RegExp(r'^[A-Z0-9]{4}\+').hasMatch(a)) {
              address = a;
              break;
            }
          }
          address = address.isNotEmpty ? address : (results[0]['formatted_address'] as String? ?? '');
          if (address.isNotEmpty && mounted) {
            setState(() => _stops[index]['name'].text = address);
          }
        }
      }
    } catch (_) {}
  }

  // ── Radius Picker ──────────────────────────────────────────────────────────
  void _showRadiusPicker(int index) {
    if (_stops[index]['lat'] == 0.0) {
      _showSnack("Select a location first.", Colors.orange);
      return;
    }
    LatLng center = LatLng(_stops[index]['lat'], _stops[index]['lng']);
    double currentRadius = double.tryParse(_stops[index]['radius'].text) ?? 200;
    final radiusTextController = TextEditingController(text: currentRadius.toStringAsFixed(0));

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setModalState) => AlertDialog(
          contentPadding: EdgeInsets.zero,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          content: SizedBox(
            width: 560,
            height: 520,
            child: Column(
              children: [
                Expanded(
                  flex: 3,
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                    child: GoogleMap(
                      initialCameraPosition: CameraPosition(target: center, zoom: 16),
                      markers: {Marker(markerId: const MarkerId("center"), position: center)},
                      circles: {
                        Circle(
                          circleId: const CircleId("geofence"),
                          center: center,
                          radius: currentRadius,
                          fillColor: AppTheme.effectivePrimary.withValues(alpha: 0.2),
                          strokeColor: AppTheme.effectivePrimary,
                          strokeWidth: 2,
                        ),
                      },
                    ),
                  ),
                ),
                Expanded(
                  flex: 2,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                    child: Column(
                      children: [
                        Text("Geofence Zone Radius",
                            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: AppTheme.secondaryColor)),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: TextField(
                                controller: radiusTextController,
                                keyboardType: TextInputType.number,
                                textAlign: TextAlign.center,
                                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: AppTheme.effectivePrimary),
                                decoration: InputDecoration(
                                  suffixText: "m",
                                  suffixStyle: TextStyle(fontSize: 16, color: AppTheme.effectivePrimary),
                                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                                  focusedBorder: OutlineInputBorder(
                                    borderRadius: BorderRadius.circular(10),
                                    borderSide: BorderSide(color: AppTheme.effectivePrimary, width: 2),
                                  ),
                                ),
                                onChanged: (v) {
                                  final val = double.tryParse(v);
                                  if (val != null && val >= 1 && val <= 4000) {
                                    setModalState(() => currentRadius = val);
                                  }
                                },
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            activeTrackColor: AppTheme.effectivePrimary,
                            thumbColor: AppTheme.effectivePrimary,
                            inactiveTrackColor: AppTheme.effectivePrimary.withValues(alpha: 0.15),
                            overlayColor: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                            trackHeight: 4,
                          ),
                          child: Slider(
                            value: currentRadius.clamp(1, 4000),
                            min: 1,
                            max: 4000,
                            divisions: 3999,
                            onChanged: (v) {
                              setModalState(() => currentRadius = v);
                              radiusTextController.text = v.toStringAsFixed(0);
                              radiusTextController.selection = TextSelection.collapsed(
                                  offset: radiusTextController.text.length);
                            },
                          ),
                        ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text("1 m", style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
                            Text("4000 m", style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text("Cancel", style: TextStyle(color: Colors.grey.shade500)),
            ),
            ElevatedButton(
              onPressed: () {
                setState(() => _stops[index]['radius'].text = currentRadius.toStringAsFixed(0));
                Navigator.pop(context);
              },
              child: const Text("Apply"),
            ),
          ],
        ),
      ),
    ).then((_) => radiusTextController.dispose());
  }

  // ── Map Preview ────────────────────────────────────────────────────────────
  void _showMapPreview() async {
    List<LatLng> locations = [];
    Set<Marker> markers = {};
    Set<Circle> circles = {};

    for (int i = 0; i < _stops.length; i++) {
      var stop = _stops[i];
      if (stop['lat'] == 0.0) continue;
      LatLng position = LatLng(stop['lat'], stop['lng']);
      locations.add(position);
      
      bool isOrigin = (i == 0);
      bool isReturn = (i == _stops.length - 1 && stop['name'].text.contains("Return"));

      markers.add(Marker(
        markerId: MarkerId("stop_$i"),
        position: position,
        icon: BitmapDescriptor.defaultMarkerWithHue(
            (isOrigin || isReturn) ? BitmapDescriptor.hueGreen : BitmapDescriptor.hueOrange),
        infoWindow: InfoWindow(
          title: stop['name'].text.isEmpty ? "Stop ${i + 1}" : stop['name'].text,
          snippet: stop['time'].text,
        ),
      ));
      
      double radius = double.tryParse(stop['radius'].text) ?? 200;
      circles.add(Circle(
        circleId: CircleId("geofence_$i"),
        center: position,
        radius: radius,
        fillColor: AppTheme.effectivePrimary.withValues(alpha: 0.15),
        strokeColor: AppTheme.effectivePrimary,
        strokeWidth: 2,
      ));
    }

    if (locations.length < 2) {
      _showSnack("Need at least 2 locations for preview.", Colors.orange);
      return;
    }

    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        content: SizedBox(
          height: 72,
          child: Row(
            children: [
              CircularProgressIndicator(color: AppTheme.effectivePrimary),
              SizedBox(width: 20),
              Text("Loading route preview…"),
            ],
          ),
        ),
      ),
    );

    final directionsRepo = DirectionsRepository();
    LatLng origin = locations.first;
    LatLng destination = locations.last;
    List<LatLng> waypoints = locations.length > 2 ? locations.sublist(1, locations.length - 1) : [];
    Directions? info = await directionsRepo.getDirections(origin: origin, destination: destination, waypoints: waypoints);

    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    final Set<Polyline> polylines = {};
    if (info != null && info.polylinePoints.isNotEmpty) {
      polylines.add(Polyline(
        polylineId: const PolylineId('overview_polyline'),
        color: AppTheme.effectivePrimary,
        width: 4,
        points: info.polylinePoints.map((e) => LatLng(e.latitude, e.longitude)).toList(),
      ));
    } else {
      _showSnack("Could not load route polyline. Check your API key or network.", Colors.orange);
    }

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: 650,
          width: 800,
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.fromLTRB(24, 20, 16, 20),
                color: Colors.white,
                child: Row(
                  children: [
                    Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(
                        color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Icons.map_outlined, color: AppTheme.effectivePrimary, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text("Trip Preview",
                              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.secondaryColor)),
                          if (info != null)
                            Text("${info.totalDistance} · ${info.totalDuration}",
                                style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                          if (info == null)
                            Text("Route unavailable",
                                style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, color: AppTheme.secondaryColor),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              Divider(color: Colors.grey.shade100, height: 1),
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

  // ── Submit ─────────────────────────────────────────────────────────────────
  Future<void> _submitTrip() async {
    if (!_formKey.currentState!.validate()) {
      _showSnack("Please fill in all required fields.", Colors.red);
      return;
    }
    for (var stop in _stops) {
      if (stop['lat'] == 0.0) {
        _showSnack("Select a location for every stop.", Colors.red);
        return;
      }
    }
    if (!_hasTemplate(DocType.waiver)) {
      _showSnack(
        "Attach a Parental Consent Waiver template before saving this trip.",
        Colors.red,
      );
      return;
    }
    final Set<String> seenLabels = {};
    for (var bus in _buses) {
      if (bus['mainTeacher'] == null) {
        _showSnack("Assign a Main Teacher for every bus.", Colors.red);
        return;
      }
      final String label = (bus['busLabel'] as TextEditingController).text.trim();
      if (label.isEmpty) {
        _showSnack("Give every bus a number/label.", Colors.red);
        return;
      }
      if (!seenLabels.add(label.toLowerCase())) {
        _showSnack("Bus labels must be unique (duplicate: $label).", Colors.red);
        return;
      }
      final int capacity = int.tryParse((bus['capacity'] as TextEditingController).text.trim()) ?? 0;
      if (capacity <= 0) {
        _showSnack("Set a valid capacity for Bus $label.", Colors.red);
        return;
      }
      final int assigned = asList(bus['passengers']).length;
      if (assigned > capacity) {
        _showSnack("Bus $label has $assigned passengers but capacity is $capacity.", Colors.red);
        return;
      }
    }

    setState(() => _isSaving = true);
    try {
      List<LatLng> locations = _stops
          .where((s) => s['lat'] != 0.0)
          .map((s) => LatLng(s['lat'], s['lng']))
          .toList();

      List<Map<String, double>> routePoints = [];
      List<String> legDurations = [];
      List<int> legDurationSeconds = [];
      String? totalDuration;
      if (locations.length >= 2) {
        final directionsRepo = DirectionsRepository();
        Directions? info = await directionsRepo.getDirections(
          origin: locations.first,
          destination: locations.last,
          waypoints: locations.length > 2 ? locations.sublist(1, locations.length - 1) : [],
        );
        if (info != null && info.polylinePoints.isNotEmpty) {
          routePoints = info.polylinePoints
              .map((p) => {'lat': p.latitude, 'lng': p.longitude})
              .toList();
          legDurations = info.legDurations;
          legDurationSeconds = info.legDurationSeconds;
          totalDuration = info.totalDuration;
        }
      }

      // Build stops; attach the leg-to-this-stop ETA (from previous stop).
      // legDurations[i] is the time from stop i to stop i+1, so stop[i+1].etaFromPrev = legDurations[i].
      List<Map<String, dynamic>> stopsData = [];
      for (int i = 0; i < _stops.length; i++) {
        final s = _stops[i];
        final Map<String, dynamic> entry = {
          'name': s['name'].text,
          'time': s['time'].text,
          'lat': s['lat'],
          'lng': s['lng'],
          'geofenceRadius': double.parse(s['radius'].text),
          'qrEnabled': false,
        };
        if (i > 0 && (i - 1) < legDurations.length) {
          entry['etaFromPrev'] = legDurations[i - 1];
          entry['etaFromPrevSeconds'] = legDurationSeconds[i - 1];
        }
        stopsData.add(entry);
      }

      List<Map<String, dynamic>> busesData = _buses.map((b) {
        final String label = (b['busLabel'] as TextEditingController).text.trim();
        final int capacity = int.tryParse((b['capacity'] as TextEditingController).text.trim()) ?? 60;
        return {
          'busLabel': label.isEmpty ? '?' : label,
          'capacity': capacity,
          // keep legacy 'busNo' for any older consumers that still read it
          'busNo': int.tryParse(label) ?? label,
          'mainTeacher': b['mainTeacher'],
          'coTeacher': b['coTeacher'],
          'passengers': b['passengers'] ?? [],
        };
      }).toList();

      // The trip id is minted up front so newly attached blank forms can be
      // filed under it before the document itself is written.
      final schoolId = await SchoolContext.schoolId();
      final trips = FirebaseFirestore.instance.collection('trips');
      final tripRef = _isEditing ? trips.doc(widget.existingDocId!) : trips.doc();
      final String tripId = tripRef.id;

      final Map<String, dynamic> documents = {};
      for (final type in DocType.all) {
        final picked = _pickedTemplates[type];
        if (picked != null) {
          final replaced = _existingTemplates[type]?['storagePath'] as String?;
          documents[type] = await DocumentService.uploadTripTemplate(
            schoolId: schoolId ?? 'unassigned',
            tripId: tripId,
            type: type,
            bytes: picked.bytes,
            fileName: picked.fileName,
            contentType: picked.contentType,
          );
          if (replaced != null) _removedTemplatePaths.add(replaced);
        } else if (_existingTemplates.containsKey(type)) {
          documents[type] = _existingTemplates[type];
        }
      }

      final Map<String, dynamic> payload = {
        'title': _titleController.text,
        'description': _descriptionController.text,
        'date': _dateController.text,
        'stops': stopsData,
        'buses': busesData,
        'totalDuration': totalDuration,
        'legDurationSeconds': legDurationSeconds,
        'notifyParentsOnGeofence': _notifyParentsOnGeofence,
        'documents': documents,
        if (schoolId != null) 'schoolId': schoolId,
      };

      if (_isEditing) {
        payload['updatedAt'] = FieldValue.serverTimestamp();
        if (routePoints.isNotEmpty) payload['route'] = routePoints;

        // Setting a trip up ends when it starts. Attendance is kept inside the
        // `buses` array, so once the trip is running the security rules refuse
        // an administrator's write to it — the facilitators on each bus own it
        // from that point. Everything else about the trip stays editable, so
        // the array is simply left out rather than the whole save failing.
        final startedStatus = (widget.initialData?['status'] ?? 'pending').toString();
        if (startedStatus != 'pending') {
          payload.remove('buses');
        }

        await tripRef.update(payload);
      } else {
        payload['route'] = routePoints;
        payload['status'] = 'pending';
        payload['createdAt'] = FieldValue.serverTimestamp();
        await tripRef.set(payload);
      }

      // Drop blank forms that were replaced or detached — best effort only.
      for (final path in _removedTemplatePaths) {
        await DocumentService.deleteFile(path);
      }
      _removedTemplatePaths.clear();

      // Create/refresh the group chat for every bus on this trip.
      // Mirrors the Cloud Function `onTripChatSync` so chats appear
      // immediately, even if the function isn't deployed yet.
      await ChatSync.syncTripChats(
        tripId: tripId,
        tripTitle: _titleController.text,
        buses: busesData,
      );

      await LogService.addLog(
        _isEditing ? "Update Trip" : "Create Trip",
        "${_isEditing ? 'Updated' : 'Created new'} trip: ${_titleController.text}",
      );

      if (mounted) {
        _showSnack(
          _isEditing ? "Trip updated successfully!" : "Trip created successfully!",
          Colors.green,
        );
        if (_isEditing) {
          Navigator.of(context).maybePop();
        } else {
          _resetForm();
        }
      }
    } catch (e) {
      if (mounted) _showSnack("Error: $e", Colors.red);
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────────
  void _addStop() => setState(() => _stops.add({
    "name": TextEditingController(),
    "time": TextEditingController(),
    "lat": 0.0,
    "lng": 0.0,
    "radius": TextEditingController(text: "200"),
  }));

  void _addReturnTrip() {
    if (_stops.isEmpty || _stops[0]['lat'] == 0.0) {
      _showSnack("Please set the Origin location first.", Colors.orange);
      return;
    }
    setState(() {
      _stops.add({
        "name": TextEditingController(text: "Return to School"),
        "time": TextEditingController(),
        "lat": _stops[0]['lat'],
        "lng": _stops[0]['lng'],
        "radius": TextEditingController(text: "100"),
      });
    });
  }

  void _addBus() => setState(() => _buses.add({
    "busLabel": TextEditingController(text: "${_buses.length + 1}"),
    "capacity": TextEditingController(text: "60"),
    "mainTeacher": null,
    "coTeacher": null,
    "passengers": <Map<String, dynamic>>[],
  }));

  /// Per-trip switch for pushing geofence warnings to parents. Teachers and the
  /// student are always alerted — this only controls the parent copy.
  Widget _buildParentAlertToggle() {
    final on = _notifyParentsOnGeofence;
    final accent = on ? AppTheme.effectivePrimary : Colors.grey.shade400;

    return Container(
      decoration: BoxDecoration(
        color: on ? AppTheme.effectivePrimary.withValues(alpha: 0.05) : Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: on ? AppTheme.effectivePrimary.withValues(alpha: 0.3) : Colors.grey.shade300,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              on ? Icons.notifications_active_rounded : Icons.notifications_off_rounded,
              size: 20,
              color: accent,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  "Send geofence warnings to parents",
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.secondaryColor,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  on
                      ? "Parents are alerted when their child leaves a stop's safe zone."
                      : "Only teachers and the student are alerted. Parents still receive "
                          "departure, arrival and trip-completed updates.",
                  style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600, height: 1.45),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            value: on,
            onChanged: (v) => setState(() => _notifyParentsOnGeofence = v),
          ),
        ],
      ),
    );
  }

  /// Blank forms students must print, sign and upload before this trip.
  /// Whatever is attached here becomes the requirement — a student is kept out
  /// of the bus group chat until every attached form is approved.
  Widget _buildTripDocuments() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.effectivePrimary.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppTheme.effectivePrimary.withValues(alpha: 0.2)),
          ),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.info_outline_rounded, size: 17, color: AppTheme.effectivePrimary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                "Students assigned to this trip download these forms, sign them on paper, "
                "and upload a photo. Each upload is checked automatically — and a student "
                "only joins the bus group chat once every attached form is approved.",
                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700, height: 1.5),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 14),
        for (final type in DocType.all) ...[
          _templateRow(type, required: type == DocType.waiver),
          if (type != DocType.all.last) const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _templateRow(String type, {required bool required}) {
    final picked = _pickedTemplates[type];
    final existing = _existingTemplates[type];
    final has = picked != null || existing != null;
    final fileName = picked?.fileName ?? (existing?['fileName'] ?? '').toString();

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        color: has ? Colors.white : Colors.grey.shade50,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: has
              ? AppTheme.effectivePrimary.withValues(alpha: 0.35)
              : (required ? Colors.orange.shade200 : Colors.grey.shade300),
        ),
      ),
      child: Row(children: [
        Icon(DocType.icon(type), size: 20,
            color: has ? AppTheme.effectivePrimary : Colors.grey.shade400),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text(DocType.label(type),
                  style: const TextStyle(
                      fontSize: 13.5, fontWeight: FontWeight.w600,
                      color: AppTheme.secondaryColor)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: required
                      ? Colors.orange.withValues(alpha: 0.14)
                      : Colors.grey.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  required ? 'Required' : 'Optional',
                  style: TextStyle(
                    fontSize: 9.5, fontWeight: FontWeight.w700,
                    color: required ? Colors.orange.shade900 : Colors.grey.shade700,
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 3),
            Text(
              has ? fileName : 'No file attached — ${DocType.blurb(type)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                color: has ? Colors.grey.shade700 : Colors.grey.shade500,
                fontStyle: has ? FontStyle.normal : FontStyle.italic,
              ),
            ),
          ]),
        ),
        const SizedBox(width: 8),
        if (has && !required)
          IconButton(
            onPressed: () => _clearTemplate(type),
            icon: const Icon(Icons.close_rounded, size: 18),
            color: Colors.grey.shade400,
            tooltip: 'Remove',
          ),
        OutlinedButton(
          onPressed: () => _pickTemplate(type),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 36),
            foregroundColor: AppTheme.effectivePrimary,
            side: BorderSide(color: AppTheme.effectivePrimary),
          ),
          child: Text(has ? 'Replace' : 'Attach'),
        ),
      ]),
    );
  }

  /// Lets the admin choose a blank form for this trip. Held in memory until
  /// save, when the trip id becomes the storage folder.
  Future<void> _pickTemplate(String type) async {
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'],
        withData: true,
      );
    } catch (_) {
      picked = await FilePicker.platform.pickFiles(withData: true);
    }
    if (picked == null || picked.files.isEmpty) return;

    final file = picked.files.first;
    final bytes = file.bytes;
    if (bytes == null) {
      _showSnack("Could not read that file.", Colors.red);
      return;
    }
    if (bytes.lengthInBytes > 10 * 1024 * 1024) {
      _showSnack("Templates must be under 10 MB.", Colors.red);
      return;
    }

    final ext = file.name.split('.').last.toLowerCase();
    final contentType = ext == 'pdf'
        ? 'application/pdf'
        : (ext == 'png' ? 'image/png' : 'image/jpeg');

    setState(() {
      _pickedTemplates[type] = _PickedTemplate(bytes, file.name, contentType);
    });
  }

  void _clearTemplate(String type) {
    setState(() {
      _pickedTemplates.remove(type);
      final removed = _existingTemplates.remove(type);
      final path = removed?['storagePath'] as String?;
      if (path != null) _removedTemplatePaths.add(path);
    });
  }

  void _showSnack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      content: Text(msg),
      backgroundColor: color,
    ));
  }

  void _showTeacherSelectionModal(int busIndex, String role) {
    TextEditingController searchCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setStateModal) => Dialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Container(
            padding: const EdgeInsets.all(24),
            width: 400,
            height: 520,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 38, height: 38,
                      decoration: BoxDecoration(
                        color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(Icons.person_search_rounded, size: 18, color: AppTheme.effectivePrimary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text("Select $role",
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.secondaryColor)),
                    ),
                    GestureDetector(
                      onTap: () => Navigator.pop(context),
                      child: Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(color: Colors.grey.shade100, shape: BoxShape.circle),
                        child: const Icon(Icons.close, size: 16, color: AppTheme.secondaryColor),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: searchCtrl,
                  decoration: const InputDecoration(
                    prefixIcon: Icon(Icons.search_rounded),
                    hintText: "Search teacher…",
                  ),
                  onChanged: (v) => setStateModal(() {}),
                ),
                SizedBox(height: 12),
                Expanded(
                  child: StreamBuilder<QuerySnapshot>(
                    stream: FirebaseFirestore.instance.collection('users').snapshots(),
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) {
                        return Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary));
                      }
                      // Teachers are deliberately NOT scoped to a school: every
                      // school searches the full teacher list and assigns them
                      // manually. Students are school-scoped; staff are not.
                      final list = snapshot.data!.docs.where((d) {
                        final data = d.data() as Map<String, dynamic>;
                        final r = (data['role'] ?? '').toString().toLowerCase().trim();
                        final nameMatch = data['name'].toString().toLowerCase().contains(searchCtrl.text.toLowerCase());
                        return r == 'teacher' && nameMatch;
                      }).toList();

                      if (list.isEmpty) {
                        return Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.person_off_outlined, size: 40, color: Colors.grey.shade300),
                              const SizedBox(height: 10),
                              Text("No teachers found", style: TextStyle(color: Colors.grey.shade400)),
                            ],
                          ),
                        );
                      }
                      return ListView.separated(
                        itemCount: list.length,
                        separatorBuilder: (_, __) => Divider(color: Colors.grey.shade100, height: 1),
                        itemBuilder: (c, i) {
                          final d = list[i].data() as Map<String, dynamic>;
                          return InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () {
                              setState(() {
                                final teacher = {'id': list[i].id, 'name': d['name'], 'email': d['email']};
                                if (role == "Main Teacher") {
                                  _buses[busIndex]['mainTeacher'] = teacher;
                                } else {
                                  _buses[busIndex]['coTeacher'] = teacher;
                                }
                              });
                              Navigator.pop(context);
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                              child: Row(
                                children: [
                                  CircleAvatar(
                                    radius: 20,
                                    backgroundColor: AppTheme.effectivePrimary.withValues(alpha: 0.12),
                                    child: Text(d['name'][0].toUpperCase(),
                                        style: TextStyle(color: AppTheme.effectivePrimary, fontWeight: FontWeight.bold)),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(d['name'],
                                            style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: AppTheme.secondaryColor)),
                                        Text(d['email'] ?? '',
                                            style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                                      ],
                                    ),
                                  ),
                                  Icon(Icons.chevron_right_rounded, color: AppTheme.effectivePrimary, size: 20),
                                ],
                              ),
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _manageStudents(int busIndex) async {
    List<dynamic> currentPassengers = _buses[busIndex]['passengers'] ?? [];
    final int capacity =
        int.tryParse((_buses[busIndex]['capacity'] as TextEditingController).text.trim()) ?? 60;

    // Seats already taken on OTHER buses, so the same seat-on-different-bus is fine
    // but a student cannot be on two buses; the selector already handles that via id.
    final result = await showDialog<List<dynamic>>(
      context: context,
      builder: (ctx) => _AdminStudentSelector(
        currentPassengers: currentPassengers,
        capacity: capacity,
        busLabel: (_buses[busIndex]['busLabel'] as TextEditingController).text.trim(),
      ),
    );
    if (result != null) setState(() => _buses[busIndex]['passengers'] = result);
  }

  Widget _buildTeacherSelect(int busIdx, String role, Map<String, dynamic>? selected) {
    return GestureDetector(
      onTap: () => _showTeacherSelectionModal(busIdx, role),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected != null ? AppTheme.effectivePrimary.withValues(alpha: 0.04) : Colors.grey.shade50,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected != null ? AppTheme.effectivePrimary.withValues(alpha: 0.3) : Colors.grey.shade200,
          ),
        ),
        child: Row(
          children: [
            CircleAvatar(
              radius: 16,
              backgroundColor: selected != null
                  ? AppTheme.effectivePrimary.withValues(alpha: 0.12)
                  : Colors.grey.shade200,
              child: Icon(
                selected != null ? Icons.check_rounded : Icons.person_add_outlined,
                size: 16,
                color: selected != null ? AppTheme.effectivePrimary : Colors.grey.shade400,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(role,
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.grey.shade500, letterSpacing: 0.3)),
                  const SizedBox(height: 2),
                  Text(
                    selected != null ? selected['name'] : "Tap to assign",
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected != null ? FontWeight.w600 : FontWeight.normal,
                      color: selected != null ? AppTheme.secondaryColor : Colors.grey.shade400,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, size: 18, color: Colors.grey.shade400),
          ],
        ),
      ),
    );
  }

  // ── BUILD ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(Icons.add_road_rounded, color: AppTheme.effectivePrimary, size: 22),
                ),
                const SizedBox(width: 14),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("Create Trip Plan",
                        style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: AppTheme.secondaryColor)),
                    Text("Fill in all sections below to set up the trip.",
                        style: TextStyle(fontSize: 13, color: Colors.grey)),
                  ],
                ),
              ],
            ),

            const SizedBox(height: 32),

            _SectionCard(
              icon: Icons.info_outline_rounded,
              title: "Trip Details",
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        flex: 2,
                        child: TextFormField(
                          controller: _titleController,
                          decoration: const InputDecoration(labelText: "Trip Title", prefixIcon: Icon(Icons.title_rounded)),
                          validator: (v) => v!.isEmpty ? "Required" : null,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: TextFormField(
                          controller: _dateController,
                          readOnly: true,
                          onTap: () => _selectDate(context),
                          decoration: const InputDecoration(
                            labelText: "Date",
                            prefixIcon: Icon(Icons.calendar_today_outlined),
                            suffixIcon: Icon(Icons.arrow_drop_down_rounded),
                          ),
                          validator: (v) => v!.isEmpty ? "Required" : null,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  TextFormField(
                    controller: _descriptionController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: "Description",
                      prefixIcon: Padding(
                        padding: EdgeInsets.only(bottom: 48),
                        child: Icon(Icons.notes_rounded),
                      ),
                      alignLabelWithHint: true,
                    ),
                    validator: (v) => v!.isEmpty ? "Required" : null,
                  ),
                  const SizedBox(height: 16),
                  _buildParentAlertToggle(),
                ],
              ),
            ),

            const SizedBox(height: 20),

            _SectionCard(
              icon: Icons.assignment_outlined,
              title: "Trip Documents",
              child: _buildTripDocuments(),
            ),

            const SizedBox(height: 20),

            _SectionCard(
              icon: Icons.directions_bus_rounded,
              title: "Buses & Facilitators",
              trailing: GestureDetector(
                onTap: _addBus,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                  decoration: BoxDecoration(
                    color: AppTheme.secondaryColor,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.add_rounded, size: 14, color: Colors.white),
                      SizedBox(width: 4),
                      Text("Add Bus", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white)),
                    ],
                  ),
                ),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _buses.length,
                itemBuilder: (ctx, i) {
                  final bus = _buses[i];
                  final passengerCount = asList(bus['passengers']).length;
                  final int capacity =
                      int.tryParse((bus['capacity'] as TextEditingController).text.trim()) ?? 60;
                  final bool atOrOver = passengerCount >= capacity;
                  return Container(
                    margin: const EdgeInsets.only(bottom: 12),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF7F8FA),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: Colors.grey.shade200),
                    ),
                    child: Column(
                      children: [
                        Row(
                          children: [
                            Container(
                              width: 36, height: 36,
                              decoration: BoxDecoration(
                                color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: Icon(Icons.directions_bus_rounded, size: 18, color: AppTheme.effectivePrimary),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              flex: 3,
                              child: TextFormField(
                                controller: bus['busLabel'] as TextEditingController,
                                onChanged: (_) => setState(() {}),
                                decoration: const InputDecoration(
                                  labelText: "Bus # / Label",
                                  isDense: true,
                                  prefixIcon: Icon(Icons.tag_rounded, size: 16),
                                ),
                                validator: (v) => (v == null || v.trim().isEmpty) ? "Required" : null,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              flex: 2,
                              child: TextFormField(
                                controller: bus['capacity'] as TextEditingController,
                                keyboardType: TextInputType.number,
                                onChanged: (_) => setState(() {}),
                                decoration: const InputDecoration(
                                  labelText: "Capacity",
                                  isDense: true,
                                  prefixIcon: Icon(Icons.event_seat_outlined, size: 16),
                                ),
                                validator: (v) {
                                  final n = int.tryParse((v ?? '').trim());
                                  if (n == null || n <= 0) return "Invalid";
                                  return null;
                                },
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (_buses.length > 1)
                              GestureDetector(
                                onTap: () => setState(() => _buses.removeAt(i)),
                                child: Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(color: Colors.red.shade50, shape: BoxShape.circle),
                                  child: Icon(Icons.delete_outline_rounded, size: 16, color: Colors.red.shade400),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(child: _buildTeacherSelect(i, "Main Teacher", bus['mainTeacher'])),
                            const SizedBox(width: 10),
                            Expanded(child: _buildTeacherSelect(i, "Co-Teacher", bus['coTeacher'])),
                          ],
                        ),
                        const SizedBox(height: 12),
                        GestureDetector(
                          onTap: () => _manageStudents(i),
                          child: Container(
                            width: double.infinity,
                            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(color: Colors.grey.shade200),
                            ),
                            child: Row(
                              children: [
                                Icon(Icons.group_outlined, size: 18, color: AppTheme.effectivePrimary),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    passengerCount == 0
                                        ? "Assign Students"
                                        : "$passengerCount student${passengerCount == 1 ? '' : 's'} assigned",
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w500,
                                      color: passengerCount == 0 ? Colors.grey.shade400 : AppTheme.secondaryColor,
                                    ),
                                  ),
                                ),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                                  decoration: BoxDecoration(
                                    color: atOrOver
                                        ? Colors.red.withValues(alpha: 0.1)
                                        : AppTheme.effectivePrimary.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Text(
                                    "$passengerCount/$capacity",
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: atOrOver ? Colors.red.shade600 : AppTheme.effectivePrimary,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Icon(Icons.chevron_right_rounded, size: 18, color: Colors.grey.shade400),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),

            const SizedBox(height: 20),

            _SectionCard(
              icon: Icons.route_rounded,
              title: "Itinerary & Stops",
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    onTap: _addReturnTrip,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: Colors.orange.shade500,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.keyboard_return_rounded, size: 14, color: Colors.white),
                          SizedBox(width: 4),
                          Text("Return to School", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white)),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(width: 8),
                  GestureDetector(
                    onTap: _addStop,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                      decoration: BoxDecoration(
                        color: AppTheme.effectivePrimary,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add_location_alt_rounded, size: 14, color: Colors.white),
                          SizedBox(width: 4),
                          Text("Add Stop", style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              child: ListView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: _stops.length,
                itemBuilder: (ctx, i) {
                  final bool isOrigin = (i == 0);
                  final bool isReturn = (i == _stops.length - 1 && _stops[i]['name'].text.contains("Return"));
                  final bool hasLoc = _stops[i]['lat'] != 0.0;

                  return Container(
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: hasLoc ? AppTheme.effectivePrimary.withValues(alpha: 0.25) : Colors.grey.shade200,
                      ),
                    ),
                    child: Column(
                      children: [
                        Container(
                          padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
                          decoration: BoxDecoration(
                            color: isOrigin || isReturn
                                ? Colors.green.shade50
                                : AppTheme.accentColor.withValues(alpha: 0.08),
                            borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 32, height: 32,
                                decoration: BoxDecoration(
                                  color: isOrigin || isReturn ? Colors.green.shade100 : AppTheme.accentColor.withValues(alpha: 0.15),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  isOrigin ? Icons.school_rounded : (isReturn ? Icons.home_work_rounded : Icons.flag_rounded),
                                  size: 16,
                                  color: isOrigin || isReturn ? Colors.green.shade600 : AppTheme.accentColor,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                isOrigin ? "Stop 1 — Origin" : (isReturn ? "Final Stop — Return" : "Stop ${i + 1}"),
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                  color: isOrigin || isReturn ? Colors.green.shade700 : AppTheme.secondaryColor,
                                ),
                              ),
                              if (hasLoc) ...[
                                SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Text("Located",
                                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: AppTheme.effectivePrimary)),
                                ),
                              ],
                              const Spacer(),
                              if (!isOrigin)
                                GestureDetector(
                                  onTap: () => setState(() => _stops.removeAt(i)),
                                  child: Container(
                                    padding: const EdgeInsets.all(5),
                                    decoration: BoxDecoration(color: Colors.red.shade50, shape: BoxShape.circle),
                                    child: Icon(Icons.close_rounded, size: 14, color: Colors.red.shade400),
                                  ),
                                ),
                            ],
                          ),
                        ),

                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    flex: 2,
                                    child: TextFormField(
                                      controller: _stops[i]["name"],
                                      decoration: const InputDecoration(
                                        labelText: "Location Name",
                                        prefixIcon: Icon(Icons.place_outlined),
                                      ),
                                      validator: (v) => v!.isEmpty ? "Required" : null,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: TextFormField(
                                      controller: _stops[i]["time"],
                                      readOnly: true,
                                      onTap: () async {
                                        final t = await _pickTime15(context);
                                        if (t != null && mounted) {
                                          setState(() => _stops[i]['time'].text = t.format(context));
                                        }
                                      },
                                      decoration: const InputDecoration(
                                        labelText: "Time",
                                        prefixIcon: Icon(Icons.access_time_rounded),
                                        suffixIcon: Icon(Icons.arrow_drop_down_rounded),
                                      ),
                                      validator: (v) => v!.isEmpty ? "Required" : null,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 14),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: () => _pickLocation(i),
                                      icon: Icon(
                                        hasLoc ? Icons.check_circle_rounded : Icons.add_location_alt_outlined,
                                        size: 16,
                                        color: hasLoc ? AppTheme.effectivePrimary : Colors.grey.shade500,
                                      ),
                                      label: Text(
                                        hasLoc ? "Change Location" : "Set Location",
                                        style: TextStyle(
                                          color: hasLoc ? AppTheme.effectivePrimary : Colors.grey.shade600,
                                          fontWeight: FontWeight.w500,
                                          fontSize: 13,
                                        ),
                                      ),
                                      style: OutlinedButton.styleFrom(
                                        padding: const EdgeInsets.symmetric(vertical: 12),
                                        side: BorderSide(
                                          color: hasLoc ? AppTheme.effectivePrimary.withValues(alpha: 0.4) : Colors.grey.shade300,
                                        ),
                                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                        backgroundColor: hasLoc ? AppTheme.effectivePrimary.withValues(alpha: 0.04) : null,
                                      ),
                                    ),
                                  ),
                                  ...[
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: OutlinedButton.icon(
                                        onPressed: () => _showRadiusPicker(i),
                                        icon: const Icon(Icons.radar_rounded, size: 16, color: AppTheme.secondaryColor),
                                        label: Text(
                                          "Geofence: ${_stops[i]['radius'].text}m",
                                          style: const TextStyle(color: AppTheme.secondaryColor, fontWeight: FontWeight.w500, fontSize: 13),
                                        ),
                                        style: OutlinedButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(vertical: 12),
                                          side: BorderSide(color: Colors.grey.shade300),
                                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                                        ),
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),

            const SizedBox(height: 28),

            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _showMapPreview,
                    icon: const Icon(Icons.map_outlined, size: 18),
                    label: const Text("Preview Map"),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.secondaryColor,
                      side: BorderSide(color: Colors.grey.shade300),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  flex: 2,
                  child: ElevatedButton.icon(
                    onPressed: _isSaving ? null : _submitTrip,
                    icon: _isSaving
                        ? const SizedBox(
                            width: 18, height: 18,
                            child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                        : const Icon(Icons.check_rounded, size: 20),
                    label: Text(_isSaving ? "Saving…" : "Save Trip",
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final Widget child;
  final Widget? trailing;

  const _SectionCard({required this.icon, required this.title, required this.child, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 16, 0),
            child: Row(
              children: [
                Container(
                  width: 34, height: 34,
                  decoration: BoxDecoration(
                    color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(icon, size: 17, color: AppTheme.effectivePrimary),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(title,
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: AppTheme.secondaryColor)),
                ),
                if (trailing != null) trailing!,
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
            child: Divider(color: Colors.grey.shade100),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
            child: child,
          ),
        ],
      ),
    );
  }
}

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
  bool _isDisposed = false;

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GoogleMap(
      initialCameraPosition: CameraPosition(target: widget.initialTarget, zoom: 12),
      markers: widget.markers,
      circles: widget.circles,
      polylines: widget.polylines,
      onMapCreated: (controller) {
        _mapController = controller;
        if (widget.bounds != null) {
          Future.delayed(const Duration(milliseconds: 500), () {
            if (!_isDisposed && mounted) {
              _mapController?.animateCamera(CameraUpdate.newLatLngBounds(widget.bounds!, 60));
            }
          });
        }
      },
    );
  }
}

class _AdminStudentSelector extends StatefulWidget {
  final List<dynamic> currentPassengers;
  final int capacity;
  final String busLabel;
  const _AdminStudentSelector({
    required this.currentPassengers,
    required this.capacity,
    required this.busLabel,
  });

  @override
  State<_AdminStudentSelector> createState() => __AdminStudentSelectorState();
}

class __AdminStudentSelectorState extends State<_AdminStudentSelector> {
  final TextEditingController _searchController = TextEditingController();
  List<Map<String, dynamic>> _allStudents = [];
  List<Map<String, dynamic>> _filteredStudents = [];
  Set<String> _selectedIds = {};
  // studentId -> seat number (1..capacity), or null if "any seat" (auto-assign at save)
  final Map<String, int?> _seatAssignments = {};
  bool _isLoading = true;

  /// Roster entries whose student has not signed up yet, and the reason the
  /// lookup failed — both feed the empty state so it can explain itself.
  int _pendingRoster = 0;
  String? _fetchError;

  /// Active "Grade · Section" filter, or null for the whole roster.
  String? _sectionFilter;

  @override
  void initState() {
    super.initState();
    for (final p in widget.currentPassengers) {
      final id = p['id'].toString();
      _selectedIds.add(id);
      final dynamic seat = p['seatNumber'];
      _seatAssignments[id] = seat is int ? seat : (seat is String ? int.tryParse(seat) : null);
    }
    _fetchStudents();
    _searchController.addListener(_filterStudents);
  }

  Future<void> _fetchStudents() async {
    try {
      // Only students on this admin's school roster can be assigned to a trip.
      // Accounts created before schools existed carry no schoolId — those admins
      // keep the original unscoped list so their existing trips still work.
      final schoolId = await SchoolContext.schoolId();
      Query<Map<String, dynamic>> query = FirebaseFirestore.instance
          .collection('users')
          .where('role', isEqualTo: 'student');
      if (schoolId != null) {
        query = query.where('schoolId', isEqualTo: schoolId);
      }

      final snapshot = await query.get();
      final students = snapshot.docs.map((doc) => {
        'id': doc.id,
        'name': doc.data()['name'] ?? 'Unknown',
        'studentId': doc.data()['studentId'] ?? doc.data()['lrn'] ?? 'N/A',
        // Carried so a whole section can be assigned in one go instead of
        // ticking students individually.
        'gradeLevel': (doc.data()['gradeLevel'] ?? '').toString(),
        'section': (doc.data()['section'] ?? '').toString(),
      }).toList();

      // Roster entries still waiting on a sign-up. Without this the picker can
      // only say "no students found", which is indistinguishable from an error
      // even when the roster is full.
      var pending = 0;
      if (schoolId != null) {
        final roster = await FirebaseFirestore.instance
            .collection('roster')
            .where('schoolId', isEqualTo: schoolId)
            .get();
        pending = roster.docs.where((d) => d.data()['status'] != 'claimed').length;
      }

      if (!mounted) return;
      setState(() {
        _allStudents = students;
        _filteredStudents = students;
        _pendingRoster = pending;
        _fetchError = null;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      // Surfaced in the picker — a swallowed error here looked exactly like an
      // empty roster, which sent us chasing the wrong problem.
      setState(() {
        _fetchError = e.toString();
        _isLoading = false;
      });
    }
  }

  /// Explains *why* the picker is empty, rather than a bare "no students found".
  Widget _buildNoStudents() {
    final String message;
    final IconData icon;

    if (_fetchError != null) {
      icon = Icons.error_outline_rounded;
      message = "Could not load students.\n\n$_fetchError";
    } else if (_pendingRoster > 0) {
      icon = Icons.hourglass_empty_rounded;
      message = "$_pendingRoster ${_pendingRoster == 1 ? "student is" : "students are"} "
          "on your roster but ${_pendingRoster == 1 ? "has" : "have"} not created "
          "an account yet.\n\nThey appear here once they register with the email on "
          "the roster. If they already have an account, use the link button on the "
          "Students page.";
    } else {
      icon = Icons.person_off_outlined;
      message = "No students are registered to your school yet.\n\n"
          "Add them on the Students page — import a CSV or add them one at a time.";
    }

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: Colors.grey.shade300),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }

  /// Distinct "Grade · Section" groups present in the roster, for the filter.
  List<String> get _sectionOptions {
    final set = <String>{};
    for (final s in _allStudents) {
      final label = _groupLabel(s);
      if (label.isNotEmpty) set.add(label);
    }
    final list = set.toList()..sort();
    return list;
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
        final matchesName = s['name'].toString().toLowerCase().contains(query);
        final matchesGroup = _sectionFilter == null || _groupLabel(s) == _sectionFilter;
        return matchesName && matchesGroup;
      }).toList();
    });
  }

  /// Selects everyone currently listed, stopping at the bus capacity rather
  /// than silently overfilling it.
  void _selectAllFiltered() {
    final toAdd = _filteredStudents
        .map((s) => s['id'].toString())
        .where((id) => !_selectedIds.contains(id))
        .toList();

    final room = widget.capacity - _selectedIds.length;
    final taking = toAdd.take(room < 0 ? 0 : room).toList();

    setState(() {
      for (final id in taking) {
        _selectedIds.add(id);
        _seatAssignments[id] = null; // any seat; assigned on save
      }
    });

    if (taking.length < toAdd.length) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.orange,
        content: Text(
          "Bus is full — added ${taking.length} of ${toAdd.length}. "
          "${toAdd.length - taking.length} could not fit in ${widget.capacity} seats.",
        ),
      ));
    }
  }

  /// Clears only what is currently listed, leaving other sections selected.
  void _clearFiltered() {
    setState(() {
      for (final s in _filteredStudents) {
        final id = s['id'].toString();
        _selectedIds.remove(id);
        _seatAssignments.remove(id);
      }
    });
  }

  Set<int> _takenSeats({String? exceptStudentId}) {
    final Set<int> taken = {};
    _seatAssignments.forEach((id, seat) {
      if (id == exceptStudentId) return;
      if (!_selectedIds.contains(id)) return;
      if (seat != null) taken.add(seat);
    });
    return taken;
  }

  Future<void> _pickSeat(String studentId, String studentName) async {
    final taken = _takenSeats(exceptStudentId: studentId);
    final int? current = _seatAssignments[studentId];

    final selected = await showDialog<int?>(
      context: context,
      builder: (ctx) => _SeatPickerDialog(
        capacity: widget.capacity,
        taken: taken,
        currentSeat: current,
        studentName: studentName,
        busLabel: widget.busLabel,
      ),
    );
    if (selected != null) {
      setState(() {
        // -1 sentinel = "any seat" (auto-assign at save)
        _seatAssignments[studentId] = selected == -1 ? null : selected;
      });
    }
  }

  int? _autoAssignSeat(Set<int> taken) {
    for (int s = 1; s <= widget.capacity; s++) {
      if (!taken.contains(s)) return s;
    }
    return null;
  }

  void _saveSelection() {
    if (_selectedIds.length > widget.capacity) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("Bus capacity is ${widget.capacity}. Remove ${_selectedIds.length - widget.capacity} student(s)."),
        backgroundColor: Colors.red,
      ));
      return;
    }

    // Auto-assign any "any seat" (null) selections to the next free seat.
    final Set<int> taken = _selectedIds
        .map((id) => _seatAssignments[id])
        .whereType<int>()
        .toSet();

    final List<Map<String, dynamic>> finalSelection = [];
    for (final s in _allStudents) {
      final id = s['id'] as String;
      if (!_selectedIds.contains(id)) continue;
      int? seat = _seatAssignments[id];
      if (seat == null) {
        seat = _autoAssignSeat(taken);
        if (seat != null) taken.add(seat);
      }
      finalSelection.add({
        'id': id,
        'name': s['name'],
        'studentId': s['studentId'],
        'status': 'absent',
        'seatNumber': seat,
      });
    }
    Navigator.pop(context, finalSelection);
  }

  void _toggleStudent(String id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
        _seatAssignments.remove(id);
      } else {
        if (_selectedIds.length >= widget.capacity) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text("Bus is full (${widget.capacity} seats)."),
            backgroundColor: Colors.orange,
          ));
          return;
        }
        _selectedIds.add(id);
        _seatAssignments[id] = null; // unassigned = any seat
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        width: 420,
        height: 620,
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Row(
              children: [
                Container(
                  width: 38, height: 38,
                  decoration: BoxDecoration(
                    color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.group_outlined, size: 18, color: AppTheme.effectivePrimary),
                ),
                const SizedBox(width: 12),
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text("Assign Students",
                          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.secondaryColor)),
                      Text("Select students for this bus",
                          style: TextStyle(fontSize: 11, color: Colors.grey)),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(color: Colors.grey.shade100, shape: BoxShape.circle),
                    child: const Icon(Icons.close, size: 16, color: AppTheme.secondaryColor),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _searchController,
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.search_rounded),
                hintText: "Search student name…",
              ),
            ),
            if (_sectionOptions.isNotEmpty) ...[
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: DropdownButtonFormField<String?>(
                    initialValue: _sectionFilter,
                    isDense: true,
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.filter_alt_outlined, size: 18),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
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
                // Assigning a whole section is the common case; ticking 40 boxes
                // one at a time is not.
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
            ],
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Row(
                children: [
                  Icon(Icons.check_circle_rounded, size: 14, color: AppTheme.effectivePrimary),
                  SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      "${_selectedIds.length}/${widget.capacity} selected · Bus ${widget.busLabel}",
                      style: TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.effectivePrimary),
                    ),
                  ),
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
            SizedBox(height: 8),
            Expanded(
              child: _isLoading
                  ? Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary))
                  : _filteredStudents.isEmpty
                      ? _buildNoStudents()
                      : ListView.separated(
                          itemCount: _filteredStudents.length,
                          separatorBuilder: (_, __) => Divider(color: Colors.grey.shade100, height: 1),
                          itemBuilder: (ctx, i) {
                            final s = _filteredStudents[i];
                            final id = s['id'] as String;
                            final bool isSelected = _selectedIds.contains(id);
                            final int? seat = _seatAssignments[id];
                            return InkWell(
                              borderRadius: BorderRadius.circular(10),
                              onTap: () => _toggleStudent(id),
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
                                        border: Border.all(
                                          color: isSelected ? AppTheme.effectivePrimary : Colors.grey.shade300,
                                          width: 1.5,
                                        ),
                                      ),
                                      child: isSelected
                                          ? Icon(Icons.check_rounded, size: 14, color: Colors.white)
                                          : null,
                                    ),
                                    SizedBox(width: 12),
                                    CircleAvatar(
                                      radius: 16,
                                      backgroundColor: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                                      child: Text(s['name'][0].toUpperCase(),
                                          style: TextStyle(color: AppTheme.effectivePrimary, fontWeight: FontWeight.bold, fontSize: 13)),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(s['name'],
                                              style: TextStyle(
                                                fontWeight: FontWeight.w500,
                                                fontSize: 14,
                                                color: isSelected ? AppTheme.secondaryColor : Colors.grey.shade700,
                                              )),
                                          Text("ID: ${s['studentId']}",
                                              style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
                                        ],
                                      ),
                                    ),
                                    if (isSelected)
                                      InkWell(
                                        onTap: () => _pickSeat(id, s['name'] as String),
                                        borderRadius: BorderRadius.circular(8),
                                        child: Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: seat == null
                                                ? Colors.grey.shade100
                                                : AppTheme.effectivePrimary.withValues(alpha: 0.12),
                                            borderRadius: BorderRadius.circular(8),
                                            border: Border.all(
                                              color: seat == null
                                                  ? Colors.grey.shade300
                                                  : AppTheme.effectivePrimary.withValues(alpha: 0.4),
                                            ),
                                          ),
                                          child: Row(
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Icon(Icons.event_seat_outlined,
                                                  size: 14,
                                                  color: seat == null
                                                      ? Colors.grey.shade500
                                                      : AppTheme.effectivePrimary),
                                              const SizedBox(width: 4),
                                              Text(
                                                seat == null ? "Any" : "Seat $seat",
                                                style: TextStyle(
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w600,
                                                  color: seat == null
                                                      ? Colors.grey.shade600
                                                      : AppTheme.effectivePrimary,
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: _saveSelection,
                child: Text("Confirm Selection (${_selectedIds.length})",
                    style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Seat picker — shows a 1..capacity grid with availability.
/// Returns: the picked seat number (1..capacity), or -1 for "Any seat",
/// or null if cancelled.
class _SeatPickerDialog extends StatefulWidget {
  final int capacity;
  final Set<int> taken;
  final int? currentSeat;
  final String studentName;
  final String busLabel;

  const _SeatPickerDialog({
    required this.capacity,
    required this.taken,
    required this.currentSeat,
    required this.studentName,
    required this.busLabel,
  });

  @override
  State<_SeatPickerDialog> createState() => _SeatPickerDialogState();
}

class _SeatPickerDialogState extends State<_SeatPickerDialog> {
  int? _selected;

  @override
  void initState() {
    super.initState();
    _selected = widget.currentSeat;
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Container(
        width: 460,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(Icons.event_seat_outlined,
                      size: 18, color: AppTheme.effectivePrimary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        "Pick a seat for ${widget.studentName}",
                        style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.secondaryColor),
                      ),
                      Text(
                        "Bus ${widget.busLabel} · ${widget.capacity} seats total",
                        style: const TextStyle(fontSize: 11, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                        color: Colors.grey.shade100, shape: BoxShape.circle),
                    child: Icon(Icons.close,
                        size: 16, color: AppTheme.secondaryColor),
                  ),
                ),
              ],
            ),
            SizedBox(height: 14),
            // Legend
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _legendDot(Colors.grey.shade200, "Free"),
                SizedBox(width: 14),
                _legendDot(AppTheme.effectivePrimary, "Selected"),
                const SizedBox(width: 14),
                _legendDot(Colors.red.shade300, "Taken"),
              ],
            ),
            const SizedBox(height: 14),
            // Auto-assign button
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: () => Navigator.pop(context, -1),
                icon: const Icon(Icons.shuffle_rounded, size: 16),
                label: const Text("Auto-assign (Any available seat)"),
              ),
            ),
            const SizedBox(height: 14),
            // Seat grid
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 380),
              child: SingleChildScrollView(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: List.generate(widget.capacity, (i) {
                    final int seat = i + 1;
                    final bool isTaken = widget.taken.contains(seat);
                    final bool isSelected = _selected == seat;
                    final Color bg;
                    final Color fg;
                    if (isSelected) {
                      bg = AppTheme.effectivePrimary;
                      fg = Colors.white;
                    } else if (isTaken) {
                      bg = Colors.red.shade100;
                      fg = Colors.red.shade400;
                    } else {
                      bg = Colors.grey.shade100;
                      fg = AppTheme.secondaryColor;
                    }
                    return InkWell(
                      borderRadius: BorderRadius.circular(8),
                      onTap: isTaken
                          ? null
                          : () => setState(() => _selected = seat),
                      child: Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: bg,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isSelected
                                ? AppTheme.effectivePrimary
                                : Colors.grey.shade200,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          "$seat",
                          style: TextStyle(
                            color: fg,
                            fontWeight: FontWeight.w600,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _selected == null
                    ? null
                    : () => Navigator.pop(context, _selected),
                child: Text(
                  _selected == null
                      ? "Pick a seat"
                      : "Assign seat $_selected",
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _legendDot(Color color, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),
      ],
    );
  }
}