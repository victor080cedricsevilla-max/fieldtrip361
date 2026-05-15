import 'dart:convert';
import 'package:flutter/foundation.dart'; // for kIsWeb
import 'package:http/http.dart' as http;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:cloud_functions/cloud_functions.dart';
import '../models/directions_model.dart';

class DirectionsRepository {
  static const String _apiKey = 'AIzaSyDq1yfAFZ3MEat5ru-eIKWjAyftwuf3u6w';
  static const String _baseUrl =
      'https://maps.googleapis.com/maps/api/directions/json';

  Future<Directions?> getDirections({
    required LatLng origin,
    required LatLng destination,
    List<LatLng> waypoints = const [],
  }) async {
    // ── On Web: route through Firebase Cloud Function to avoid CORS ──
    if (kIsWeb) {
      return _getDirectionsViaCloudFunction(
          origin: origin, destination: destination, waypoints: waypoints);
    }

    // ── On Mobile (Android/iOS): call Google API directly via HTTP ──
    return _getDirectionsViaHttp(
        origin: origin, destination: destination, waypoints: waypoints);
  }

  // ---------------------------------------------------------------------------
  // WEB path — Firebase Cloud Function proxy (no CORS issue)
  // ---------------------------------------------------------------------------
  Future<Directions?> _getDirectionsViaCloudFunction({
    required LatLng origin,
    required LatLng destination,
    List<LatLng> waypoints = const [],
  }) async {
    try {
      final HttpsCallable callable =
          FirebaseFunctions.instance.httpsCallable('getGoogleDirections');

      final response = await callable.call(<String, dynamic>{
        'origin': '${origin.latitude},${origin.longitude}',
        'destination': '${destination.latitude},${destination.longitude}',
        'waypoints': waypoints
            .map((e) => '${e.latitude},${e.longitude}')
            .toList(),
      });

      final data = Map<String, dynamic>.from(response.data);

      if (data['status'] == 'OK') {
        return Directions.fromMap(data);
      } else {
        print(
            '⚠️ Cloud Function Directions status: ${data['status']} — ${data['error_message'] ?? ''}');
        return null;
      }
    } catch (e) {
      print('❌ Cloud Function error: $e');
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // MOBILE path — direct HTTP call (no CORS restriction on native)
  // ---------------------------------------------------------------------------
  Future<Directions?> _getDirectionsViaHttp({
    required LatLng origin,
    required LatLng destination,
    List<LatLng> waypoints = const [],
  }) async {
    try {
      final Map<String, String> params = {
        'origin': '${origin.latitude},${origin.longitude}',
        'destination': '${destination.latitude},${destination.longitude}',
        'key': _apiKey,
      };

      if (waypoints.isNotEmpty) {
        params['waypoints'] =
            waypoints.map((e) => '${e.latitude},${e.longitude}').join('|');
      }

      final uri = Uri.parse(_baseUrl).replace(queryParameters: params);
      final response = await http.get(uri);

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;

        if (data['status'] == 'OK') {
          return Directions.fromMap(data);
        } else {
          print(
              '⚠️ Directions API status: ${data['status']} — ${data['error_message'] ?? ''}');
          return null;
        }
      } else {
        print('⚠️ HTTP ${response.statusCode}: ${response.body}');
        return null;
      }
    } catch (e) {
      print('❌ DirectionsRepository HTTP Error: $e');
      return null;
    }
  }
}