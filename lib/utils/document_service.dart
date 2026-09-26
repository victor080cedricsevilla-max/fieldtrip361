import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';

import 'school_context.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// The pre-trip documents a school can require before a field trip.
class DocType {
  static const waiver = 'waiver';
  static const medical = 'medical';
  static const all = <String>[waiver, medical];

  static String label(String type) =>
      type == waiver ? 'Parental Consent Waiver' : 'Medical Clearance';

  static String short(String type) => type == waiver ? 'Waiver' : 'Medical Clearance';

  static IconData icon(String type) =>
      type == waiver ? Icons.fact_check_outlined : Icons.medical_information_outlined;

  static String blurb(String type) => type == waiver
      ? 'Parent or guardian permission for this trip.'
      : 'Confirmation that the student is fit to travel.';
}

/// Storage + Firestore plumbing for per-trip paperwork.
///
/// Blank templates are attached to the trip document itself
/// (`trips/{id}.documents.{type}`), so each trip carries its own forms and the
/// requirement follows whatever the admin uploaded for that trip.
class DocumentService {
  static final _db = FirebaseFirestore.instance;
  static final _storage = FirebaseStorage.instance;

  static String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  // ── Templates attached to a trip ──────────────────────────────────────────

  /// Uploads a blank form for a trip and returns the descriptor to store under
  /// `trips/{tripId}.documents.{type}`.
  static Future<Map<String, dynamic>> uploadTripTemplate({
    required String schoolId,
    required String tripId,
    required String type,
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) async {
    final ext = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : 'pdf';
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final path = 'trip_documents/$schoolId/$tripId/${type}_$stamp.$ext';

    final ref = _storage.ref(path);
    await ref.putData(bytes, SettableMetadata(contentType: contentType));
    final url = await ref.getDownloadURL();

    return {
      'type': type,
      'fileName': fileName,
      'contentType': contentType,
      'storagePath': path,
      'downloadUrl': url,
      'uploadedBy': _uid,
      'uploadedAt': DateTime.now().toIso8601String(),
    };
  }

  /// Best-effort removal of a template file that has been replaced.
  static Future<void> deleteFile(String storagePath) async {
    try {
      await _storage.ref(storagePath).delete();
    } catch (_) {/* already gone — nothing to clean up */}
  }

  /// Reads the `documents` map off a trip, keyed by document type.
  static Map<String, Map<String, dynamic>> templatesOfTrip(Map<String, dynamic> trip) {
    final raw = trip['documents'];
    if (raw is! Map) return {};
    final out = <String, Map<String, dynamic>>{};
    for (final type in DocType.all) {
      final entry = raw[type];
      if (entry is Map && entry['storagePath'] != null) {
        out[type] = Map<String, dynamic>.from(entry);
      }
    }
    return out;
  }

  /// Document types this trip requires, in display order.
  static List<String> requiredTypes(Map<String, dynamic> trip) =>
      DocType.all.where(templatesOfTrip(trip).containsKey).toList();

  // ── Submissions ───────────────────────────────────────────────────────────

  static Stream<QuerySnapshot<Map<String, dynamic>>> submissionsOfSchool(String schoolId) =>
      _db.collection('documentSubmissions').where('schoolId', isEqualTo: schoolId).snapshots();

  static Stream<QuerySnapshot<Map<String, dynamic>>> submissionsOfTrip(String tripId) =>
      _db.collection('documentSubmissions').where('tripId', isEqualTo: tripId).snapshots();

  /// Submissions a facilitator may see: their own school's.
  ///
  /// The filter has to be schoolId even though the caller wants a few trips,
  /// because Firestore checks a query against the rule rather than against the
  /// documents it would return. The rule allows a read when schoolId matches,
  /// so a query keyed on tripId is refused outright — and a refused stream
  /// arrives as an empty list, which on screen is indistinguishable from every
  /// student having uploaded nothing. Narrow to the wanted trips in the widget.
  static Stream<QuerySnapshot<Map<String, dynamic>>> submissionsForFacilitator() {
    return Stream.fromFuture(SchoolContext.schoolId()).asyncExpand((id) {
      if (id == null) {
        return const Stream<QuerySnapshot<Map<String, dynamic>>>.empty();
      }
      return submissionsOfSchool(id);
    });
  }

  static Stream<QuerySnapshot<Map<String, dynamic>>> submissionsOfStudent(String uid) =>
      _db.collection('documentSubmissions').where('studentId', isEqualTo: uid).snapshots();

  /// Uploads a filled-in form for a trip. `onDocumentSubmissionCreated` picks it
  /// up and writes the verdict, so nothing here sets a status but 'pending'.
  static Future<void> submit({
    required String schoolId,
    required String tripId,
    required String tripTitle,
    required String type,
    required String studentName,
    required Uint8List bytes,
    required String fileName,
    required String contentType,
  }) async {
    final uid = _uid;
    if (uid == null) throw Exception('You are not signed in.');

    final ext = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : 'jpg';
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final path = 'document_submissions/$schoolId/$uid/${tripId}_${type}_$stamp.$ext';

    final ref = _storage.ref(path);
    await ref.putData(bytes, SettableMetadata(contentType: contentType));
    final url = await ref.getDownloadURL();

    await _db.collection('documentSubmissions').add({
      'schoolId': schoolId,
      'tripId': tripId,
      'tripTitle': tripTitle,
      'studentId': uid,
      'studentName': studentName,
      'type': type,
      'fileName': fileName,
      'contentType': contentType,
      'storagePath': path,
      'downloadUrl': url,
      'status': 'pending',
      'submittedAt': FieldValue.serverTimestamp(),
    });
  }

  /// Keeps only the newest submission per (trip, student, type).
  static Map<String, QueryDocumentSnapshot<Map<String, dynamic>>> latestByKey(
    Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> docs,
    String Function(Map<String, dynamic> data) keyOf,
  ) {
    final out = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
    for (final d in docs) {
      final key = keyOf(d.data());
      final cur = out[key];
      if (cur == null || submittedAt(d).isAfter(submittedAt(cur))) out[key] = d;
    }
    return out;
  }

  static DateTime submittedAt(QueryDocumentSnapshot<Map<String, dynamic>> d) {
    final ts = d.data()['submittedAt'];
    return ts is Timestamp ? ts.toDate() : DateTime.fromMillisecondsSinceEpoch(0);
  }

  // ── Files ─────────────────────────────────────────────────────────────────

  /// Opens a stored document in the browser or the device's viewer.
  ///
  /// This deliberately hands the download URL to the platform instead of
  /// fetching the bytes ourselves: on web, Storage's `getData()` is an XHR that
  /// needs a CORS policy on the bucket, and without one it fails with an opaque
  /// `ClientException`. A plain navigation needs no CORS, and the browser's own
  /// PDF viewer already offers download and print.
  static Future<void> open(String downloadUrl) async {
    if (downloadUrl.isEmpty) {
      throw Exception('This document has no download link.');
    }
    final uri = Uri.parse(downloadUrl);
    final opened = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
      webOnlyWindowName: '_blank',
    );
    if (!opened) throw Exception('The device refused to open this document.');
  }
}
