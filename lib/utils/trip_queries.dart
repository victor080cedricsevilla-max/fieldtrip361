import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'school_context.dart';

/// School-scoped trip queries.
///
/// Firestore rejects a whole query if it *could* return a document the rules
/// deny, so every trip query must carry the same filter its rule enforces:
/// admins are scoped by `schoolId`, everyone else by `allMemberIds`.
///
/// Each query deliberately uses a single `where` clause and leaves status
/// filtering and sorting to the caller — combining filters would demand
/// composite indexes that this project does not define.
class TripQueries {
  static CollectionReference<Map<String, dynamic>> get _trips =>
      FirebaseFirestore.instance.collection('trips');

  /// Trips owned by the signed-in admin's school.
  ///
  /// Accounts created before schools existed have no `schoolId`; those fall back
  /// to an unscoped read, which the rules still allow for trips that likewise
  /// predate schools.
  static Stream<QuerySnapshot<Map<String, dynamic>>> ofMySchool() {
    return Stream.fromFuture(SchoolContext.schoolId()).asyncExpand((id) {
      if (id == null) return _trips.snapshots();
      return _trips.where('schoolId', isEqualTo: id).snapshots();
    });
  }

  /// Trips the signed-in user is assigned to — teachers, students, and any role
  /// that appears in `allMemberIds`.
  static Stream<QuerySnapshot<Map<String, dynamic>>> mine() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const Stream.empty();
    return _trips.where('allMemberIds', arrayContains: uid).snapshots();
  }

  /// One-shot variant of [mine], for code paths outside a StreamBuilder.
  static Future<QuerySnapshot<Map<String, dynamic>>?> mineOnce() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return Future.value(null);
    return _trips.where('allMemberIds', arrayContains: uid).get();
  }

  /// Trips any of a parent's children are assigned to.
  ///
  /// `arrayContainsAny` accepts at most 30 values; a parent is capped at two
  /// children, so that ceiling is never a concern here.
  static Stream<QuerySnapshot<Map<String, dynamic>>> ofChildren(List<String> childIds) {
    if (childIds.isEmpty) return const Stream.empty();
    return _trips
        .where('allMemberIds', arrayContainsAny: childIds.take(30).toList())
        .snapshots();
  }

  /// Sorts newest-first on `createdAt`, replacing an `orderBy` that would need a
  /// composite index alongside the scoping filter.
  static List<QueryDocumentSnapshot<Map<String, dynamic>>> newestFirst(
    Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
  ) {
    final list = docs.toList();
    list.sort((a, b) {
      final at = a.data()['createdAt'];
      final bt = b.data()['createdAt'];
      if (at is Timestamp && bt is Timestamp) return bt.compareTo(at);
      if (at is Timestamp) return -1;
      if (bt is Timestamp) return 1;
      return 0;
    });
    return list;
  }
}
