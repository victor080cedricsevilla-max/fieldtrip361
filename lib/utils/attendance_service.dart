import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

/// Client side of attendance.
///
/// Nothing here decides anything. The app asks the server to issue a code or to
/// record a scan, and shows whatever the server says — including its refusals,
/// which are written to be read aloud to the student standing in front of you.
class AttendanceService {
  AttendanceService._();

  static final _fns = FirebaseFunctions.instance;

  static Future<Map<String, dynamic>> _call(
    String name,
    Map<String, dynamic> payload,
  ) async {
    final res = await _fns.httpsCallable(name).call<Map<String, dynamic>>(payload);
    return Map<String, dynamic>.from(res.data);
  }

  /// Pushes a fresh position for the signed-in user and returns it.
  ///
  /// `observedAt` is the moment the device took the fix, recorded separately
  /// from the server's write time: the server judges freshness on the former,
  /// so re-uploading a stale position cannot make it look current.
  static Future<Position?> publishFreshFix({Duration? timeLimit}) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return null;
    try {
      final permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        final asked = await Geolocator.requestPermission();
        if (asked == LocationPermission.denied ||
            asked == LocationPermission.deniedForever) {
          return null;
        }
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(
          accuracy: LocationAccuracy.best,
          timeLimit: timeLimit ?? const Duration(seconds: 12),
        ),
      );

      await FirebaseFirestore.instance.collection('locations').doc(uid).set({
        'lat': pos.latitude,
        'lng': pos.longitude,
        'accuracy': pos.accuracy,
        'observedAt': Timestamp.fromDate(pos.timestamp),
        'isMocked': pos.isMocked,
        'lastUpdate': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      return pos;
    } catch (e) {
      debugPrint('publishFreshFix failed: $e');
      return null;
    }
  }

  /// Asks for a single-use code for the student's own QR screen.
  static Future<Map<String, dynamic>> issueToken(String tripId) =>
      _call('issueAttendanceToken', {'tripId': tripId});

  /// Redeems a scanned code. The facilitator's own position is sent for the
  /// record; the decision rests on the student's.
  static Future<Map<String, dynamic>> recordScan({
    required String tripId,
    required String tokenId,
    String? jti,
    Position? facilitatorPosition,
  }) =>
      _call('recordAttendanceScan', {
        'tripId': tripId,
        'tokenId': tokenId,
        'jti': jti,
        'teacherLat': facilitatorPosition?.latitude,
        'teacherLng': facilitatorPosition?.longitude,
        'teacherAccuracy': facilitatorPosition?.accuracy,
      });

  static Future<Map<String, dynamic>> recordManual({
    required String tripId,
    required String studentId,
    required int stopIndex,
    required String reason,
  }) =>
      _call('recordManualAttendance', {
        'tripId': tripId,
        'studentId': studentId,
        'stopIndex': stopIndex,
        'reason': reason,
        'confirmedPresent': true,
      });

  static Future<Map<String, dynamic>> setSeat({
    required String tripId,
    required String studentId,
    required int? seatNumber,
  }) =>
      _call('setPassengerSeat', {
        'tripId': tripId,
        'studentId': studentId,
        'seatNumber': seatNumber,
      });

  static Future<Map<String, dynamic>> setGeofenceExemption({
    required String tripId,
    required String studentId,
    required bool warningsEnabled,
    String? reason,
  }) =>
      _call('setGeofenceExemption', {
        'tripId': tripId,
        'studentId': studentId,
        'warningsEnabled': warningsEnabled,
        'reason': reason,
      });

  /// Live exemptions for a trip, keyed by student id. Used to grey out a
  /// student on the roster and to keep the alarm quiet for them.
  static Stream<Map<String, Map<String, dynamic>>> exemptions(String tripId) {
    return FirebaseFirestore.instance
        .collection('trips')
        .doc(tripId)
        .collection('geofenceExemptions')
        .snapshots()
        .map((snap) => {
              for (final d in snap.docs) d.id: d.data(),
            });
  }

  /// Turns a callable failure into something a facilitator can act on.
  ///
  /// "Not in the vicinity" and "cannot be verified" are different problems: one
  /// means the student is elsewhere, the other means we do not know. They must
  /// not collapse into one message.
  static AttendanceFailure describeError(Object error) {
    if (error is FirebaseFunctionsException) {
      final message = error.message ?? 'That did not work.';
      final details = error.details is Map
          ? Map<String, dynamic>.from(error.details as Map)
          : const <String, dynamic>{};
      final kindTag = (details['kind'] ?? '').toString();

      final kind = switch (kindTag) {
        'outside_geofence' => AttendanceFailureKind.outsideGeofence,
        'location_unverifiable' => AttendanceFailureKind.unverifiable,
        _ => message.toLowerCase().contains('not in the vicinity')
            ? AttendanceFailureKind.outsideGeofence
            : AttendanceFailureKind.rejected,
      };

      return AttendanceFailure(
        message: message,
        kind: kind,
        detail: _detailLine(details),
      );
    }
    return const AttendanceFailure(
      message: 'The scan could not be completed. Check your connection and try again.',
      kind: AttendanceFailureKind.rejected,
    );
  }

  /// The supporting numbers, phrased so a facilitator can judge for themselves.
  ///
  /// "1.4 km away, last updated 18 minutes ago" tells a very different story
  /// from "1.4 km away, updated 20 seconds ago", and only the person standing
  /// there can tell which one they are looking at.
  static String? _detailLine(Map<String, dynamic> details) {
    final parts = <String>[];

    final distance = details['distanceM'];
    final radius = details['radiusM'];
    if (distance is num) {
      final where = distance >= 1000
          ? '${(distance / 1000).toStringAsFixed(1)} km'
          : '${distance.round()} m';
      parts.add(radius is num
          ? 'Their device reports $where from ${details['stopName'] ?? 'this destination'} '
              '(the zone is ${radius.round()} m)'
          : 'Their device reports $where away');
    }

    final age = details['lastObservedAgoSeconds'];
    if (age is num) {
      final ago = age < 90
          ? '${age.round()} seconds ago'
          : age < 5400
              ? '${(age / 60).round()} minutes ago'
              : '${(age / 3600).round()} hours ago';
      parts.add('Last updated $ago');
    } else if (details.containsKey('lastObservedAgoSeconds')) {
      parts.add('Their device has never reported a position');
    }

    final accuracy = details['accuracyM'];
    if (accuracy is num) parts.add('accurate to about ${accuracy.round()} m');

    return parts.isEmpty ? null : '${parts.join(' · ')}.';
  }
}

enum AttendanceFailureKind { outsideGeofence, unverifiable, rejected }

class AttendanceFailure {
  final String message;
  final AttendanceFailureKind kind;

  /// The supporting numbers — distance, how old the fix is, how accurate.
  final String? detail;

  const AttendanceFailure({
    required this.message,
    required this.kind,
    this.detail,
  });

  /// Manual attendance is always reachable from a failed scan.
  ///
  /// Every refusal leaves the facilitator with the same problem: a student in
  /// front of them who is not marked present. Withholding the manual path would
  /// only send them hunting for the button on the stop card, which is one tap
  /// away regardless — and every manual mark still needs a confirmation, a
  /// reason, and carries a `Manual` tag into the report.
  bool get offerManual => true;

  String get title => switch (kind) {
        AttendanceFailureKind.outsideGeofence => 'Not in the vicinity',
        AttendanceFailureKind.unverifiable => 'Location unavailable',
        AttendanceFailureKind.rejected => 'Scan refused',
      };
}
