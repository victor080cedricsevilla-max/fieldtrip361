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
        return 'No email on file';
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

  /// Issues a fresh registration code and emails it, retiring any outstanding
  /// one. Returns null when it went out, or the reason it did not.
  static Future<String?> sendActivationCode(String guardianId) async {
    final r = await sendAllPendingCodes(guardianIds: [guardianId]);
    if ((r['sent'] as num?)?.toInt() == 1) return null;
    final failures = (r['failures'] as List?) ?? const [];
    if (failures.isNotEmpty) {
      final reason = Map<String, dynamic>.from(failures.first as Map)['reason'];
      return reason?.toString() ?? 'The email could not be sent.';
    }
    return 'There is no email address on file for this guardian, so there is '
        'nowhere to send the code.';
  }

  /// Emails registration codes to guardians who have no account yet.
  ///
  /// Codes go by email alone. A parent cannot create an account without one, so
  /// an address is what a guardian needs in order to get in at all.
  ///
  /// With [guardianIds] only those guardians are contacted, and one already
  /// holding a live code is sent a new one — the admin ticking a box is asking
  /// for exactly that, and the old code is withdrawn. Capped per run by the
  /// server.
  ///
  /// The reply keeps the shape the older SMS-and-email sender returned, so the
  /// dialogs that read it did not have to change.
  static Future<Map<String, dynamic>> sendAllPendingCodes({
    List<String>? guardianIds,
  }) async {
    final res = await _fns.httpsCallable('issueEnrollmentCodes').call(<String, dynamic>{
      'only': 'parent',
      if (guardianIds != null) 'guardianIds': guardianIds,
    });
    final d = Map<String, dynamic>.from(res.data as Map);
    final failed = (d['failed'] as List?) ?? const [];
    return {
      'sent': d['sent'],
      'byEmail': d['sent'],
      'bySms': 0,
      'failed': failed.length,
      'remaining': d['remaining'],
      'failures': [
        for (final f in failed)
          {
            'name': Map<String, dynamic>.from(f as Map)['name'] ?? '',
            'reason': Map<String, dynamic>.from(f)['reason'],
          },
      ],
      'missingEmail': d['missingEmail'],
    };
  }

  /// Emails registration codes to students who have no account yet.
  ///
  /// With [rosterIds] only those students; with none, everyone on the roster
  /// who has an address and has not registered. Returns the server's summary:
  /// how many went out, and who is still waiting for an address.
  static Future<Map<String, dynamic>> sendStudentCodes({List<String>? rosterIds}) async {
    final res = await _fns.httpsCallable('issueEnrollmentCodes').call(<String, dynamic>{
      'only': 'student',
      if (rosterIds != null) 'rosterIds': rosterIds,
    });
    return Map<String, dynamic>.from(res.data as Map);
  }

  /// Sets or corrects a student's email and sends them a code straight away.
  static Future<Map<String, dynamic>> setStudentEmail(
    String rosterId,
    String email, {
    bool sendCode = true,
  }) async {
    final res = await _fns.httpsCallable('setRosterEmail').call(<String, dynamic>{
      'rosterId': rosterId,
      'email': email,
      'sendCode': sendCode,
    });
    return Map<String, dynamic>.from(res.data as Map);
  }

  /// Withdraws a student's outstanding registration code.
  static Future<void> revokeStudentCode(String rosterId) => _fns
      .httpsCallable('revokeEnrollmentCode')
      .call(<String, dynamic>{'rosterId': rosterId});

  /// Guardians that could be emailed a code right now: contactable, not yet
  /// linked to an account, and without a live code already out.
  static bool isAwaitingCode(Map<String, dynamic> g) =>
      g['status'] == statusActivationReady &&
      g['parentUid'] == null &&
      g['activationStatus'] != 'sent';

  static Future<void> revokeActivationCode(String guardianId) =>
      _fns.httpsCallable('revokeEnrollmentCode')
          .call(<String, dynamic>{'guardianId': guardianId});

  static Future<void> remove(String guardianId) =>
      _fns.httpsCallable('removeGuardian').call(<String, dynamic>{'guardianId': guardianId});

  /// Adds another child to the signed-in parent's account from a registration
  /// code. The server resolves the school, student and guardian from the code
  /// alone, and refuses a code that was emailed to a different address.
  static Future<Map<String, dynamic>> activate(String code) async {
    final res = await _fns
        .httpsCallable('addChildByCode')
        .call(<String, dynamic>{'code': code});
    return Map<String, dynamic>.from(res.data as Map);
  }

  /// Relationship options offered when assigning a guardian.
  static const relationships = <String>[
    'Mother', 'Father', 'Guardian', 'Grandparent', 'Aunt', 'Uncle', 'Sibling', 'Other',
  ];
}
