import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';

/// Client wrapper for the guardian and activation-code callables.
///
/// Every mutation lives server-side: guardians and activation codes are not
/// client-writable, so a student can never fabricate a parent relationship.
/// Reads are plain Firestore queries, which the rules scope to the caller's
/// school.
class GuardianService {
  static final _db = FirebaseFirestore.instance;
  static final _fns = FirebaseFunctions.instance;

  // Guardian record states, mirroring GUARDIAN_STATUS in functions/index.js.
  static const statusPendingContact = 'pending_contact';
  static const statusActivationReady = 'activation_ready';
  static const statusActivated = 'activated';

  /// Mirrors MAX_GUARDIANS_PER_STUDENT in functions/index.js, which enforces it.
  static const maxPerStudent = 2;

  /// Human label for a guardian's state, as shown in the admin list.
  ///
  /// "Pending" is reserved for a code that is already out and waiting to be
  /// used. A guardian the school gave no way to reach is not pending anything —
  /// it needs the admin to supply a contact, and the label says so.
  static String statusLabel(Map<String, dynamic>? guardian) {
    if (guardian == null) return 'No guardian assigned';
    switch (guardian['status']) {
      case statusActivated:
        return 'Parent linked';
      case statusActivationReady:
        return guardian['activationStatus'] == 'sent' ? 'Pending' : 'Ready to send';
      default:
        return 'No email/phone found';
    }
  }

  /// Whether the guardian has been sent a code that nobody has redeemed yet.
  static bool isPending(Map<String, dynamic> g) =>
      g['status'] == statusActivationReady &&
      g['parentUid'] == null &&
      g['activationStatus'] == 'sent';

  /// Whether the school gave no email and no mobile number for this guardian.
  static bool hasNoContact(Map<String, dynamic> g) => g['status'] == statusPendingContact;

  static bool isLinked(Map<String, dynamic> g) => g['status'] == statusActivated;

  /// Guardians for a school — the admin/teacher view.
  static Stream<QuerySnapshot<Map<String, dynamic>>> ofSchool(String schoolId) =>
      _db.collection('guardians').where('schoolId', isEqualTo: schoolId).snapshots();

  /// Guardians attached to one roster student.
  ///
  /// Use [ofSchool] and group by `studentId` when rendering a list — one
  /// listener per row melts the roster page once an import lands.
  static Stream<QuerySnapshot<Map<String, dynamic>>> ofStudent(String rosterId) =>
      _db.collection('guardians').where('studentId', isEqualTo: rosterId).snapshots();

  /// Guardians for a student who already has an account, keyed by their uid.
  /// This is the teacher-side view: the roster id is an admin concept.
  static Stream<QuerySnapshot<Map<String, dynamic>>> ofStudentUid(String uid) =>
      _db.collection('guardians').where('studentUid', isEqualTo: uid).snapshots();

  /// Creates or updates the guardian for a student, optionally emailing a code.
  static Future<Map<String, dynamic>> assign({
    required String studentId,
    required String name,
    required String relationship,
    String? email,
    String? phone,
    bool sendCode = false,
  }) async {
    final res = await _fns.httpsCallable('assignGuardian').call(<String, dynamic>{
      'studentId': studentId,
      'name': name,
      'relationship': relationship,
      'email': email ?? '',
      'phone': phone ?? '',
      'sendCode': sendCode,
    });
    return Map<String, dynamic>.from(res.data as Map);
  }

  /// Issues a fresh code and emails it, retiring any outstanding one.
  static Future<void> sendActivationCode(String guardianId) =>
      _fns.httpsCallable('sendGuardianActivationCode')
          .call(<String, dynamic>{'guardianId': guardianId});

  /// Sends activation codes, by email or SMS depending on what is on file.
  ///
  /// With [guardianIds] only those guardians are contacted, and one already
  /// holding a live code is resent to — the admin ticking a box is asking for
  /// exactly that. With no ids, every guardian still waiting is contacted and
  /// live codes are left alone. Capped per run by the server.
  static Future<Map<String, dynamic>> sendAllPendingCodes({
    List<String>? guardianIds,
  }) async {
    final res = await _fns.httpsCallable('sendAllPendingActivationCodes').call(
          guardianIds == null ? null : <String, dynamic>{'guardianIds': guardianIds},
        );
    return Map<String, dynamic>.from(res.data as Map);
  }

  /// Guardians that could be emailed a code right now: contactable, not yet
  /// linked to an account, and without a live code already out.
  static bool isAwaitingCode(Map<String, dynamic> g) =>
      g['status'] == statusActivationReady &&
      g['parentUid'] == null &&
      g['activationStatus'] != 'sent';

  static Future<void> revokeActivationCode(String guardianId) =>
      _fns.httpsCallable('revokeGuardianActivationCode')
          .call(<String, dynamic>{'guardianId': guardianId});

  static Future<void> remove(String guardianId) =>
      _fns.httpsCallable('removeGuardian').call(<String, dynamic>{'guardianId': guardianId});

  /// Redeems a code for the signed-in parent. The server resolves the school,
  /// student and guardian from the code alone.
  static Future<Map<String, dynamic>> activate(String code) async {
    final res = await _fns
        .httpsCallable('activateGuardianCode')
        .call(<String, dynamic>{'code': code});
    return Map<String, dynamic>.from(res.data as Map);
  }

  /// Relationship options offered when assigning a guardian.
  static const relationships = <String>[
    'Mother', 'Father', 'Guardian', 'Grandparent', 'Aunt', 'Uncle', 'Sibling', 'Other',
  ];
}
