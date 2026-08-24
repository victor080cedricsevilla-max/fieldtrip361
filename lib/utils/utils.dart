import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:geolocator/geolocator.dart';
import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../config/theme.dart';

const String _googleApiKey = "AIzaSyAoBhWhuW725rdDv8AnX3GKLHcNIyMFYgg"; 

class LogService {
  static Future<void> addLog(String action, String details) async {
    final user = FirebaseAuth.instance.currentUser;
    await FirebaseFirestore.instance.collection('activity_logs').add({
      'action': action,
      'details': details,
      'adminEmail': user?.email ?? 'Unknown',
      'timestamp': FieldValue.serverTimestamp(),
    });
  }
}

Future<TimeOfDay?> pickTime15(BuildContext context) async {
  final TimeOfDay? picked = await showTimePicker(
    context: context, 
    initialTime: TimeOfDay.now(),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: false), 
      child: child!
    )
  );

  if (picked != null) {
    int m = picked.minute;
    if (m < 8) m = 0; else if (m < 23) m = 15; else if (m < 38) m = 30; else if (m < 53) m = 45; else m = 0;
    return TimeOfDay(hour: picked.hour, minute: m);
  }
  return null;
}

Future<List<LatLng>> getGoogleRoute(List<LatLng> points) async {
  if (points.length < 2) return [];

  try {
    debugPrint("Attempting Google Directions...");
    
    String origin = "${points.first.latitude},${points.first.longitude}";
    String destination = "${points.last.latitude},${points.last.longitude}";
    
    String waypoints = "";
    if (points.length > 2) {
      List<String> wps = [];
      for (int i = 1; i < points.length - 1; i++) {
        wps.add("${points[i].latitude},${points[i].longitude}");
      }
      waypoints = "&waypoints=${wps.join('|')}";
    }

    String url = "https://maps.googleapis.com/maps/api/directions/json?origin=$origin&destination=$destination$waypoints&mode=driving&key=$_googleApiKey";
    
    if (kIsWeb) {
      url = "https://corsproxy.io/?${Uri.encodeComponent(url)}";
    }

    var response = await http.get(Uri.parse(url));
    
    if (response.statusCode == 200) {
      var data = jsonDecode(response.body);
      if (data['status'] == 'OK' && data['routes'].isNotEmpty) {
        debugPrint("Google Route Success!");
        String encodedPoints = data['routes'][0]['overview_polyline']['points'];
        return _decodePolyline(encodedPoints);
      } else {
        debugPrint("Google API Failed: ${data['status']}. Switching to OSRM...");
        throw Exception("Google API Error");
      }
    } else {
      throw Exception("HTTP Error");
    }
  } catch (e) {
    debugPrint("Google failed ($e). Using OSRM Fallback...");
    return await _getOSRMRoute(points);
  }
}

Future<List<LatLng>> _getOSRMRoute(List<LatLng> points) async {
  try {
    List<String> coords = points.map((p) => "${p.longitude},${p.latitude}").toList();
    String url = "https://router.project-osrm.org/route/v1/driving/${coords.join(';')}?overview=full&geometries=geojson";
    
    var response = await http.get(Uri.parse(url));
    
    if (response.statusCode == 200) {
      var data = jsonDecode(response.body);
      if (data['code'] == 'Ok') {
        var geometry = data['routes'][0]['geometry']['coordinates'];
        List<LatLng> route = [];
        for (var p in geometry) {
          route.add(LatLng(p[1].toDouble(), p[0].toDouble())); 
        }
        debugPrint("OSRM Route Success!");
        return route;
      }
    }
  } catch (e) {
    debugPrint("OSRM Failed: $e");
  }
  return points; 
}

List<LatLng> _decodePolyline(String encoded) {
  List<LatLng> poly = [];
  int index = 0, len = encoded.length;
  int lat = 0, lng = 0;

  while (index < len) {
    int b, shift = 0, result = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
    lat += dlat;

    shift = 0;
    result = 0;
    do {
      b = encoded.codeUnitAt(index++) - 63;
      result |= (b & 0x1f) << shift;
      shift += 5;
    } while (b >= 0x20);
    int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1));
    lng += dlng;

    poly.add(LatLng((lat / 1E5).toDouble(), (lng / 1E5).toDouble()));
  }
  return poly;
}

class LocationPickerModal extends StatefulWidget {
  final LatLng initialCenter;
  const LocationPickerModal({super.key, required this.initialCenter});
  @override State<LocationPickerModal> createState() => _LocationPickerModalState();
}

class _LocationPickerModalState extends State<LocationPickerModal> {
  late GoogleMapController _mapController;
  late LatLng _selectedLocation;
  final TextEditingController _searchController = TextEditingController();
  List<dynamic> _searchResults = [];

  /// Why the last search returned nothing. Shown in the results area — the old
  /// code discarded failures, so a broken search looked like "no matches".
  String? _searchError;

  @override
  void initState() {
    super.initState();
    _selectedLocation = widget.initialCenter;
  }

  /// Place search, proxied through Cloud Functions.
  ///
  /// The Places REST API cannot be called from a browser (no CORS), so this
  /// used to go through a public proxy. That proxy dropped anonymous access and
  /// began returning 403, which this method swallowed — search simply returned
  /// nothing, with no error anywhere. Going through our own function removes
  /// the third party and keeps the Maps key off the client.
  Future<void> _searchPlace(String input) async {
    if (input.isEmpty) {
      setState(() {
        _searchResults = [];
        _searchError = null;
      });
      return;
    }

    try {
      final res = await FirebaseFunctions.instance
          .httpsCallable('searchPlaces')
          .call(<String, dynamic>{'input': input});
      final data = Map<String, dynamic>.from(res.data as Map);
      if (!mounted) return;
      setState(() {
        _searchResults = (data['predictions'] as List?) ?? const [];
        _searchError = null;
      });
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      setState(() {
        _searchResults = [];
        _searchError = e.message ?? 'Place search is unavailable.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searchResults = [];
        _searchError = 'Place search failed. Check your connection.';
      });
    }
  }

  Future<void> _goToPlace(String placeId, String desc) async {
    try {
      final res = await FirebaseFunctions.instance
          .httpsCallable('getPlaceDetails')
          .call(<String, dynamic>{'placeId': placeId});
      final data = Map<String, dynamic>.from(res.data as Map);
      final lat = (data['lat'] as num?)?.toDouble();
      final lng = (data['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) throw Exception('No coordinates returned.');

      final LatLng newPos = LatLng(lat, lng);
      _mapController.animateCamera(CameraUpdate.newLatLngZoom(newPos, 16));
      if (!mounted) return;
      setState(() {
        _selectedLocation = newPos;
        _searchResults = [];
        _searchError = null;
        _searchController.text = desc;
      });
    } catch (e) { debugPrint("Details Error: $e"); }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(children: [
        GoogleMap(
          initialCameraPosition: CameraPosition(target: _selectedLocation, zoom: 15),
          onMapCreated: (c) async {
            _mapController = c;
            // Auto-zoom to current GPS position so admin sees where they are.
            try {
              final pos = await Geolocator.getCurrentPosition(
                locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
              );
              final here = LatLng(pos.latitude, pos.longitude);
              c.animateCamera(CameraUpdate.newLatLngZoom(here, 16));
              if (mounted) setState(() => _selectedLocation = here);
            } catch (_) {}
          },
          onCameraMove: (p) => _selectedLocation = p.target,
          myLocationButtonEnabled: true,
          myLocationEnabled: true,
        ),
        
        const Center(
          child: Padding(
            padding: EdgeInsets.only(bottom: 30), 
            child: Icon(Icons.location_on, size: 45, color: Colors.red)
          )
        ),
        
        Positioned(
          top: 20, left: 20, right: 20, 
          child: Column(children: [
            Container(
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8), boxShadow: [const BoxShadow(blurRadius: 5, color: Colors.black26)]), 
              child: TextField(
                controller: _searchController, 
                decoration: InputDecoration(
                  hintText: "Search location...", 
                  prefixIcon: const Icon(Icons.search), 
                  suffixIcon: IconButton(icon: const Icon(Icons.clear), onPressed: ()=>setState((){_searchController.clear(); _searchResults=[];})), 
                  border: InputBorder.none, 
                  contentPadding: const EdgeInsets.all(15)
                ), 
                onChanged: _searchPlace
              )
            ),
            if (_searchError != null)
              Container(
                margin: const EdgeInsets.only(top: 5),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.errorColor.withValues(alpha: 0.4)),
                ),
                child: Row(children: [
                  Icon(Icons.error_outline_rounded, size: 18, color: AppTheme.errorColor),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(_searchError!,
                        style: TextStyle(fontSize: 12.5, color: AppTheme.errorColor, height: 1.4)),
                  ),
                ]),
              )
            else if (_searchResults.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 5),
                height: 200,
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
                child: ListView.separated(
                  itemCount: _searchResults.length,
                  separatorBuilder: (ctx, i) => const Divider(height: 1),
                  itemBuilder: (c, i) {
                    // The function returns a trimmed shape: {placeId, description}.
                    final p = _searchResults[i] as Map;
                    final description = (p['description'] ?? '').toString();
                    // Show the place name on its own line; the rest is context.
                    final comma = description.indexOf(',');
                    final main = comma > 0 ? description.substring(0, comma) : description;
                    return ListTile(
                      title: Text(main, style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text(description, maxLines: 1, overflow: TextOverflow.ellipsis),
                      onTap: () => _goToPlace((p['placeId'] ?? '').toString(), description),
                    );
                  },
                )
              )
          ])
        ),
        
        Positioned(
          bottom: 30, left: 40, right: 40,
          child: ElevatedButton(
            onPressed: () => Navigator.pop(context, (_selectedLocation, _searchController.text.trim())),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.effectivePrimary, padding: EdgeInsets.symmetric(vertical: 15), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(30))),
            child: const Text("SELECT THIS LOCATION", style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold))
          )
        )
      ]),
    );
  }
}
