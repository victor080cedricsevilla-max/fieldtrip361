import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';

/// Client side of the school subscription application.
///
/// Applying does not create a login. The browser signs in anonymously, which is
/// only ever used to tie an upload to the session that made it — a registrar is
/// not asked to invent a password for an account they would use once. The
/// account they receive is provisioned on approval, with its own credentials.
///
/// Every state change goes through a Cloud Function: the browser never writes an
/// application document, a status, a reference number or a review deadline.
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

  /// Ensures there is a session to attach uploads to.
  ///
  /// Reuses whatever is already signed in — including a real account, which the
  /// server refuses with a clear message rather than silently applying on
  /// someone else's behalf.
  static Future<User?> ensureSession() async {
    final existing = FirebaseAuth.instance.currentUser;
    if (existing != null) return existing;
    try {
      final cred = await FirebaseAuth.instance.signInAnonymously();
      return cred.user;
    } catch (e) {
      debugPrint('anonymous sign-in failed: $e');
      return null;
    }
  }

  static bool get isSchoolAccount {
    final u = FirebaseAuth.instance.currentUser;
    return u != null && !u.isAnonymous;
  }

  /// Creates or updates the draft. Returns the application id.
  static Future<Map<String, dynamic>> save({
    required String schoolName,
    required String legalName,
    required String institutionType,
    required String address,
    required String email,
    required String repName,
    required String repPosition,
    required String repPhone,
    required String tier,
    required String billingCycle,
  }) =>
      _call('saveSchoolApplication', {
        'schoolName': schoolName,
        'legalName': legalName,
        'institutionType': institutionType,
        'address': address,
        'email': email,
        'representative': {
          'name': repName,
          'position': repPosition,
          'email': email,
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
    if (uid == null) throw StateError('No session. Reload the page and try again.');

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

  /// Reopens an application from the link in our email, on any device.
  static Future<Map<String, dynamic>> openWithKey({
    required String applicationId,
    required String accessKey,
  }) =>
      _call('openApplicationWithKey', {
        'applicationId': applicationId,
        'accessKey': accessKey,
      });

  /// The application belonging to this session, live.
  static Stream<QuerySnapshot<Map<String, dynamic>>> mine() {
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

  /// Turns a callable failure into the sentence the server wrote, rather than
  /// the SDK's wrapper around it.
  static String describeError(Object e) {
    if (e is FirebaseFunctionsException) {
      return e.message ?? 'That did not work. Please try again.';
    }
    final s = e.toString();
    final m = RegExp(r'\[firebase_\w+/[a-z-]+\]\s*(.+)$').firstMatch(s);
    return m?.group(1) ?? 'That did not work. Please try again.';
  }
}
