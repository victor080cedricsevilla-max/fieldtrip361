import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

/// Client side of the school subscription application.
///
/// Every state change goes through a Cloud Function: the applicant's browser
/// never writes an application document, a status, a reference number or a
/// review deadline. Uploads go to a folder keyed to the applicant's own uid,
/// which Storage rules restrict to them and the reviewer.
class ApplicationService {
  ApplicationService._();

  static final _fns = FirebaseFunctions.instance;
  static final _db = FirebaseFirestore.instance;
  static final _storage = FirebaseStorage.instance;

  static Future<Map<String, dynamic>> _call(
    String name,
    Map<String, dynamic> payload,
  ) async {
    final res = await _fns.httpsCallable(name).call<Map<String, dynamic>>(payload);
    return Map<String, dynamic>.from(res.data);
  }

  /// Creates the applicant account. The role is assigned by the server on the
  /// first save — this only establishes the sign-in and sends the verification
  /// email that the rest of the flow depends on.
  static Future<void> registerApplicant({
    required String email,
    required String password,
  }) async {
    final cred = await FirebaseAuth.instance.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    await cred.user?.sendEmailVerification();
  }

  static Future<void> signIn({required String email, required String password}) async {
    await FirebaseAuth.instance.signInWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
  }

  static Future<void> resendVerification() async {
    await FirebaseAuth.instance.currentUser?.sendEmailVerification();
  }

  /// Firebase caches `emailVerified`; a reload is the only way to see that the
  /// applicant has clicked the link in another tab.
  static Future<bool> refreshEmailVerified() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return false;
    await user.reload();
    return FirebaseAuth.instance.currentUser?.emailVerified ?? false;
  }

  static Future<Map<String, dynamic>> saveApplication({
    required String schoolName,
    required String legalName,
    required String institutionType,
    required String address,
    required String repName,
    required String repPosition,
    required String repEmail,
    required String repPhone,
    required String tier,
    required String billingCycle,
  }) =>
      _call('saveSchoolApplication', {
        'schoolName': schoolName,
        'legalName': legalName,
        'institutionType': institutionType,
        'address': address,
        'representative': {
          'name': repName,
          'position': repPosition,
          'email': repEmail,
          'phone': repPhone,
        },
        'tier': tier,
        'billingCycle': billingCycle,
      });

  /// Uploads one verification document and registers it against the
  /// application. The upload happens first so the server can confirm the object
  /// exists before it records anything.
  static Future<Map<String, dynamic>> uploadDocument({
    required String applicationId,
    required String type,
    required Uint8List bytes,
    required String fileName,
    required String contentType,
    void Function(double progress)? onProgress,
  }) async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) throw StateError('Sign in before uploading.');

    final ext = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : 'pdf';
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final path = 'school_applications/$applicationId/$uid/${type}_$stamp.$ext';

    final task = _storage.ref(path).putData(
          bytes,
          SettableMetadata(contentType: contentType),
        );
    if (onProgress != null) {
      task.snapshotEvents.listen((s) {
        if (s.totalBytes > 0) onProgress(s.bytesTransferred / s.totalBytes);
      });
    }
    await task;

    return _call('attachApplicationDocument', {
      'applicationId': applicationId,
      'type': type,
      'storagePath': path,
      'fileName': fileName,
      'contentType': contentType,
      'size': bytes.length,
    });
  }

  static Future<void> removeDocument({
    required String applicationId,
    required String documentId,
  }) =>
      _call('removeApplicationDocument', {
        'applicationId': applicationId,
        'documentId': documentId,
      }).then((_) {});

  static Future<Map<String, dynamic>> submit(String applicationId) =>
      _call('submitSchoolApplication', {'applicationId': applicationId});

  /// The applicant's own application, live. Security rules scope this to the
  /// owner, so a guessed id returns nothing.
  static Stream<QuerySnapshot<Map<String, dynamic>>> myApplications() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const Stream.empty();
    return _db
        .collection('schoolApplications')
        .where('applicantUid', isEqualTo: uid)
        .snapshots();
  }

  static Stream<QuerySnapshot<Map<String, dynamic>>> documents(String applicationId) => _db
      .collection('schoolApplications')
      .doc(applicationId)
      .collection('documents')
      .orderBy('uploadedAt')
      .snapshots();
}
