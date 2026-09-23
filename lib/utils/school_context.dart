import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Resolves which school the signed-in user belongs to.
///
/// Every roster/trip-assignment query is scoped by this id, so it is read once
/// per session and cached — otherwise each rebuild would re-read the user doc.
class SchoolContext {
  static String? _cachedUid;
  static String? _cachedSchoolId;

  /// The current user's `schoolId`, or null if their account isn't linked to a
  /// school yet (e.g. accounts created before schools existed).
  static Future<String?> schoolId({bool forceRefresh = false}) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      clear();
      return null;
    }
    if (!forceRefresh && _cachedUid == uid) return _cachedSchoolId;

    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      _cachedUid = uid;
      _cachedSchoolId = (doc.data()?['schoolId'] as String?)?.trim();
      if (_cachedSchoolId != null && _cachedSchoolId!.isEmpty) _cachedSchoolId = null;
      return _cachedSchoolId;
    } catch (_) {
      return _cachedSchoolId;
    }
  }

  /// Live view of the school document — capacity and studentCount change as the
  /// admin imports students, so the capacity meter listens rather than polls.
  static Stream<DocumentSnapshot<Map<String, dynamic>>>? schoolStream(String? schoolId) {
    if (schoolId == null || schoolId.isEmpty) return null;
    return FirebaseFirestore.instance.collection('schools').doc(schoolId).snapshots();
  }

  /// Students registered to the signed-in user's school.
  ///
  /// Scoped by school *and* role. The admin dashboard asks "how many students
  /// do we have", which is not the same question as "how many accounts exist on
  /// the platform" — an unscoped read of users answers the second one and puts
  /// every other school's people into this school's headline number.
  ///
  /// The (schoolId, role) composite index exists for exactly this pair.
  /// Accounts predating schools have no schoolId, so those fall back to the
  /// role filter alone rather than returning nothing.
  static Stream<QuerySnapshot<Map<String, dynamic>>> studentsOfMySchool() {
    final byRole = FirebaseFirestore.instance
        .collection('users')
        .where('role', isEqualTo: 'student');
    return Stream.fromFuture(schoolId()).asyncExpand((id) {
      if (id == null) return byRole.snapshots();
      return byRole.where('schoolId', isEqualTo: id).snapshots();
    });
  }

  /// Clears the cache — call on logout so the next user doesn't inherit it.
  static void clear() {
    _cachedUid = null;
    _cachedSchoolId = null;
  }
}
