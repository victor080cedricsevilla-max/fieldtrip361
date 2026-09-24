import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

import 'school_context.dart';

/// Client side of staff management.
///
/// Every call here is a request, never a write. Inviting, redeeming and
/// removing all happen in Cloud Functions, because each one decides something
/// a client must not: which school an account belongs to, which address it is
/// created for, and whether a teacher can be released while a bus is still out.
class StaffService {
  StaffService._();

  static final _fns = FirebaseFunctions.instance;
  static final _db = FirebaseFirestore.instance;

  static Future<Map<String, dynamic>> _call(
    String name,
    Map<String, dynamic> payload,
  ) async {
    final res =
        await _fns.httpsCallable(name).call<Map<String, dynamic>>(payload);
    return Map<String, dynamic>.from(res.data);
  }

  /// Invites one teacher. The address given here is the one the account will
  /// be created for — it cannot be changed by whoever receives the code.
  static Future<void> invite({required String name, required String email}) =>
      _call('inviteTeacher', {'name': name, 'email': email});

  static Future<void> revokeInvite(String inviteId) =>
      _call('revokeTeacherInvite', {'inviteId': inviteId});

  /// Ends a teacher's link to this school. The account survives, so past
  /// attendance records still name who took them.
  static Future<void> removeFromSchool({
    required String uid,
    String reason = '',
  }) =>
      _call('removeTeacherFromSchool', {'uid': uid, 'reason': reason});

  /// This school's teachers.
  static Stream<QuerySnapshot<Map<String, dynamic>>> teachers() =>
      SchoolContext.teachersOfMySchool();

  /// Invitations for this school, newest first.
  ///
  /// One filter only: a second `where` would need a composite index this
  /// project does not define, so status is sorted out in the widget.
  static Stream<QuerySnapshot<Map<String, dynamic>>> invites() {
    return Stream.fromFuture(SchoolContext.schoolId()).asyncExpand((id) {
      if (id == null) {
        return const Stream<QuerySnapshot<Map<String, dynamic>>>.empty();
      }
      return _db
          .collection('staffInvites')
          .where('schoolId', isEqualTo: id)
          .snapshots();
    });
  }

  /// Turns a callable failure into something worth showing a person.
  static String describeError(Object e) {
    if (e is FirebaseFunctionsException) {
      final m = e.message;
      if (m != null && m.isNotEmpty) return m;
      switch (e.code) {
        case 'resource-exhausted':
          return 'You have sent several invitations just now. '
              'Please wait a moment before sending another.';
        case 'permission-denied':
          return 'Only a school administrator can manage staff.';
        default:
          return 'That could not be completed. Please try again.';
      }
    }
    return 'That could not be completed. Check your connection and try again.';
  }
}
