import 'package:google_maps_flutter/google_maps_flutter.dart';

class Directions {
  final List<LatLng> polylinePoints;
  final String totalDistance;
  final String totalDuration;
  final LatLngBounds bounds;
  /// Human-readable duration per leg, in order (e.g. ["12 mins", "8 mins"]).
  final List<String> legDurations;
  /// Duration per leg in seconds (parallel to [legDurations]).
  final List<int> legDurationSeconds;

  Directions({
    required this.polylinePoints,
    required this.totalDistance,
    required this.totalDuration,
    required this.bounds,
    this.legDurations = const [],
    this.legDurationSeconds = const [],
  });

  static String _formatDuration(int seconds) {
    final int hours = seconds ~/ 3600;
    final int minutes = (seconds % 3600) ~/ 60;
    String out = "";
    if (hours > 0) out += "$hours hr${hours > 1 ? 's' : ''} ";
    if (minutes > 0) out += "$minutes min${minutes > 1 ? 's' : ''}";
    if (out.isEmpty) out = "1 min";
    return out.trim();
  }

  factory Directions.fromMap(Map<String, dynamic> map) {
    if (map['routes'] == null || (map['routes'] as List).isEmpty) {
      return Directions(
        polylinePoints: [],
        totalDistance: "",
        totalDuration: "",
        bounds: LatLngBounds(
          northeast: const LatLng(0, 0),
          southwest: const LatLng(0, 0),
        ),
      );
    }

    final data = map['routes'][0];

    final boundsData = data['bounds'];
    final bounds = LatLngBounds(
      northeast: LatLng(
        boundsData['northeast']['lat'].toDouble(),
        boundsData['northeast']['lng'].toDouble(),
      ),
      southwest: LatLng(
        boundsData['southwest']['lat'].toDouble(),
        boundsData['southwest']['lng'].toDouble(),
      ),
    );

    String distance = "";
    String duration = "";
    final List<String> legDurations = [];
    final List<int> legDurationSeconds = [];
    if ((data['legs'] as List).isNotEmpty) {
      int totalDistanceMeters = 0;
      int totalDurationSeconds = 0;

      for (var leg in data['legs']) {
        totalDistanceMeters += (leg['distance']['value'] as num).toInt();
        final int legSecs = (leg['duration']['value'] as num).toInt();
        totalDurationSeconds += legSecs;
        legDurationSeconds.add(legSecs);
        legDurations.add(_formatDuration(legSecs));
      }

      if (totalDistanceMeters >= 1000) {
        distance = "${(totalDistanceMeters / 1000).toStringAsFixed(1)} km";
      } else {
        distance = "$totalDistanceMeters m";
      }

      duration = _formatDuration(totalDurationSeconds);
    }

    final overviewPolyline = data['overview_polyline']['points'] as String;
    List<LatLng> points = _decodePolySafe(overviewPolyline);

    return Directions(
      polylinePoints: points,
      totalDistance: distance,
      totalDuration: duration,
      bounds: bounds,
      legDurations: legDurations,
      legDurationSeconds: legDurationSeconds,
    );
  }

  static List<LatLng> _decodePolySafe(String poly) {
    var list = poly.codeUnits;
    var lList = <LatLng>[];
    int index = 0;
    int len = poly.length;
    int c = 0;
    int shift = 0;
    int result = 0;
    int lat = 0;
    int lng = 0;

    while (index < len) {
      shift = 0;
      result = 0;
      do {
        c = list[index] - 63;
        index++;
        result |= (c & 0x1f) << shift;
        shift += 5;
      } while (c >= 0x20 && index < len);
      
      int dlat = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1)).toSigned(32);
      lat += dlat;

      shift = 0;
      result = 0;
      do {
        c = list[index] - 63;
        index++;
        result |= (c & 0x1f) << shift;
        shift += 5;
      } while (c >= 0x20 && index < len);
      
      int dlng = ((result & 1) != 0 ? ~(result >> 1) : (result >> 1)).toSigned(32);
      lng += dlng;

      lList.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return lList;
  }
}