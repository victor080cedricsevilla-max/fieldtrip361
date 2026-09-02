import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../../config/theme.dart';
import '../../utils/document_service.dart';

/// Pre-trip paperwork, listed per trip: print the blank form the admin attached
/// to that trip, sign it on paper, photograph it, and upload. Until every form
/// for a trip is approved the student stays out of that trip's bus group chat.
class StudentDocumentsTab extends StatefulWidget {
  const StudentDocumentsTab({super.key});

  @override
  State<StudentDocumentsTab> createState() => _StudentDocumentsTabState();
}

class _StudentDocumentsTabState extends State<StudentDocumentsTab> {
  String _studentName = '';
  String? _schoolId;
  bool _loading = true;
  String? _busyKey; // "<tripId>_<type>" while uploading or printing

  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final uid = _uid;
    if (uid == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final doc = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      if (!mounted) return;
      setState(() {
        _studentName = (doc.data()?['name'] ?? '').toString();
        _schoolId = (doc.data()?['schoolId'] as String?)?.trim();
        if (_schoolId != null && _schoolId!.isEmpty) _schoolId = null;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  /// Hands the blank form to the browser or device viewer, which offers download
  /// and print. Fetching the bytes ourselves would need a bucket CORS policy.
  Future<void> _openTemplate(String tripId, String type, Map<String, dynamic> template) async {
    setState(() => _busyKey = '${tripId}_$type');
    try {
      await DocumentService.open((template['downloadUrl'] ?? '').toString());
    } catch (e) {
      if (mounted) _toast('Could not open the form. $e', isError: true);
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  Future<void> _upload(String tripId, String tripTitle, String type) async {
    final source = await showModalBottomSheet<String>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(height: 10),
          Container(
            width: 40, height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.shade300,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'Upload your signed ${DocType.short(type).toLowerCase()}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
            ),
          ),
          const SizedBox(height: 6),
          ListTile(
            leading: Icon(Icons.photo_camera_rounded, color: AppTheme.effectivePrimary),
            title: const Text('Take a photo'),
            subtitle: const Text('Photograph the signed paper form'),
            onTap: () => Navigator.pop(ctx, 'camera'),
          ),
          ListTile(
            leading: Icon(Icons.folder_open_rounded, color: AppTheme.effectivePrimary),
            title: const Text('Choose a file'),
            subtitle: const Text('PDF or image already on your device'),
            onTap: () => Navigator.pop(ctx, 'file'),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 6, 20, 0),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.auto_awesome_rounded, size: 13, color: Colors.grey.shade500),
              const SizedBox(width: 7),
              Expanded(
                child: Text(
                  'An AI assistant checks your upload for the right form, a signature, '
                  'and readable writing before your teacher sees it.',
                  style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600, height: 1.4),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 10),
        ]),
      ),
    );
    if (source == null) return;

    Uint8List? bytes;
    String fileName = 'submission.jpg';
    String contentType = 'image/jpeg';

    try {
      if (source == 'camera') {
        final shot = await ImagePicker().pickImage(
          source: ImageSource.camera,
          imageQuality: 85,
          maxWidth: 2000,
        );
        if (shot == null) return;
        bytes = await shot.readAsBytes();
        fileName = shot.name.isNotEmpty ? shot.name : 'photo.jpg';
        contentType = shot.mimeType ?? 'image/jpeg';
      } else {
        final picked = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'],
          withData: true,
        );
        if (picked == null || picked.files.isEmpty) return;
        bytes = picked.files.first.bytes;
        fileName = picked.files.first.name;
        final ext = fileName.split('.').last.toLowerCase();
        contentType = ext == 'pdf'
            ? 'application/pdf'
            : (ext == 'png' ? 'image/png' : 'image/jpeg');
      }
    } catch (_) {
      if (mounted) _toast('Could not read that file.', isError: true);
      return;
    }

    if (bytes == null) {
      if (mounted) _toast('Could not read that file.', isError: true);
      return;
    }
    if (bytes.lengthInBytes > 15 * 1024 * 1024) {
      if (mounted) _toast('That file is larger than 15 MB. Use a smaller photo.', isError: true);
      return;
    }

    setState(() => _busyKey = '${tripId}_$type');
    try {
      await DocumentService.submit(
        schoolId: _schoolId ?? 'unassigned',
        tripId: tripId,
        tripTitle: tripTitle,
        type: type,
        studentName: _studentName,
        bytes: bytes,
        fileName: fileName,
        contentType: contentType,
      );
      if (mounted) _toast('Uploaded. Your form is being reviewed…');
    } catch (_) {
      if (mounted) _toast('Upload failed. Please try again.', isError: true);
    } finally {
      if (mounted) setState(() => _busyKey = null);
    }
  }

  void _toast(String msg, {bool isError = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: isError ? AppTheme.errorColor : AppTheme.secondaryColor,
      behavior: SnackBarBehavior.floating,
    ));
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary));
    }
    final uid = _uid;
    if (uid == null) return const SizedBox.shrink();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('trips')
          .where('allMemberIds', arrayContains: uid)
          .snapshots(),
      builder: (context, tripSnap) {
        if (tripSnap.hasError) {
          return _centeredNote('Could not load your trips.\n${tripSnap.error}');
        }
        if (!tripSnap.hasData) {
          return Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary));
        }

        // Only trips that actually ask for paperwork, newest first.
        final trips = tripSnap.data!.docs
            .where((d) => (d.data()['status'] ?? '') != 'completed')
            .where((d) => DocumentService.requiredTypes(d.data()).isNotEmpty)
            .toList()
          ..sort((a, b) => (b.data()['date'] ?? '')
              .toString()
              .compareTo((a.data()['date'] ?? '').toString()));

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: DocumentService.submissionsOfStudent(uid),
          builder: (context, subSnap) {
            // Newest submission per trip + document type.
            final latest = DocumentService.latestByKey(
              subSnap.data?.docs ?? const [],
              (d) => '${d['tripId']}_${d['type']}',
            );

            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 28),
              children: [
                _howItWorks(),
                const SizedBox(height: 18),
                if (trips.isEmpty)
                  _emptyState()
                else
                  for (final trip in trips) ...[
                    _tripCard(trip, latest),
                    const SizedBox(height: 14),
                  ],
              ],
            );
          },
        );
      },
    );
  }

  Widget _centeredNote(String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Text(text,
              textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade600)),
        ),
      );

  Widget _emptyState() {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
      child: Column(children: [
        Icon(Icons.task_alt_rounded, size: 48, color: Colors.grey.shade300),
        const SizedBox(height: 14),
        const Text('Nothing to submit',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        Text(
          'None of your trips need forms right now. When a teacher assigns you to a '
          'trip that requires a waiver, it will appear here.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: Colors.grey.shade600, height: 1.55),
        ),
      ]),
    );
  }

  Widget _howItWorks() {
    Widget step(int n, String text) => Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 20, height: 20,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppTheme.effectivePrimary.withValues(alpha: 0.14),
                shape: BoxShape.circle,
              ),
              child: Text('$n',
                  style: TextStyle(
                      fontSize: 11, fontWeight: FontWeight.bold,
                      color: AppTheme.effectivePrimary)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(text,
                  style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700, height: 1.45)),
            ),
          ]),
        );

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.effectivePrimary.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.effectivePrimary.withValues(alpha: 0.2)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.assignment_turned_in_rounded, size: 20, color: AppTheme.effectivePrimary),
          const SizedBox(width: 10),
          const Text('Before you can join a trip',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5)),
        ]),
        const SizedBox(height: 14),
        step(1, 'Download and print the form your school attached to the trip.'),
        step(2, 'Fill it in and have your parent or guardian sign it by hand.'),
        step(3, 'Take a clear photo of the signed page and upload it.'),
        step(4, 'Once approved you are added to your bus group chat.'),
      ]),
    );
  }

  Widget _tripCard(
    QueryDocumentSnapshot<Map<String, dynamic>> trip,
    Map<String, QueryDocumentSnapshot<Map<String, dynamic>>> latest,
  ) {
    final data = trip.data();
    final tripId = trip.id;
    final title = (data['title'] ?? 'Field Trip').toString();
    final date = (data['date'] ?? '').toString();
    final templates = DocumentService.templatesOfTrip(data);
    final required = DocumentService.requiredTypes(data);

    final approvedCount = required
        .where((t) => latest['${tripId}_$t']?.data()['status'] == 'approved')
        .length;
    final allClear = approvedCount == required.length;

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      padding: const EdgeInsets.all(18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 42, height: 42,
            decoration: BoxDecoration(
              color: (allClear ? const Color(0xFF16A34A) : AppTheme.accentColor)
                  .withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(
              allClear ? Icons.lock_open_rounded : Icons.lock_outline_rounded,
              size: 20,
              color: allClear ? const Color(0xFF16A34A) : AppTheme.accentColor,
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
              if (date.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(date,
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                ),
            ]),
          ),
          Text('$approvedCount/${required.length}',
              style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.bold,
                color: allClear ? const Color(0xFF16A34A) : AppTheme.accentColor,
              )),
        ]),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: (allClear ? const Color(0xFF16A34A) : AppTheme.accentColor)
                .withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(children: [
            Icon(allClear ? Icons.chat_bubble_rounded : Icons.chat_bubble_outline_rounded,
                size: 15,
                color: allClear ? const Color(0xFF16A34A) : AppTheme.accentColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                allClear
                    ? 'All forms approved — you are in the bus group chat.'
                    : 'Bus group chat unlocks once every form is approved.',
                style: TextStyle(
                  fontSize: 11.5,
                  height: 1.35,
                  color: allClear ? const Color(0xFF15803D) : Colors.orange.shade900,
                ),
              ),
            ),
          ]),
        ),
        for (final type in required) ...[
          const SizedBox(height: 14),
          _docRow(tripId, title, type, templates[type], latest['${tripId}_$type']),
        ],
      ]),
    );
  }

  Widget _docRow(
    String tripId,
    String tripTitle,
    String type,
    Map<String, dynamic>? template,
    QueryDocumentSnapshot<Map<String, dynamic>>? submission,
  ) {
    final busy = _busyKey == '${tripId}_$type';
    final sub = submission?.data();
    final status = (sub?['status'] ?? '').toString();
    final aiError = sub?['aiError']?.toString();

    return Container(
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFA),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: const Color(0xFFEFEFEF)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(DocType.icon(type), size: 17, color: AppTheme.effectivePrimary),
          const SizedBox(width: 9),
          Expanded(
            child: Text(DocType.label(type),
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          ),
          _statusChip(status, aiError),
        ]),
        if (status == 'rejected') ...[
          const SizedBox(height: 9),
          _rejectionReasons(sub),
        ],
        const SizedBox(height: 11),
        if (template == null)
          Text('The form is missing — ask your teacher.',
              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600))
        else
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy ? null : () => _openTemplate(tripId, type, template),
                icon: const Icon(Icons.download_rounded, size: 16),
                label: const Text('Download form', style: TextStyle(fontSize: 12.5)),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 38),
                  foregroundColor: AppTheme.effectivePrimary,
                  side: BorderSide(color: AppTheme.effectivePrimary),
                ),
              ),
            ),
            const SizedBox(width: 9),
            Expanded(
              child: FilledButton.icon(
                onPressed: busy ? null : () => _upload(tripId, tripTitle, type),
                icon: busy
                    ? const SizedBox(
                        width: 14, height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.upload_rounded, size: 16),
                label: Text(
                  status == 'approved' ? 'Replace' : (status.isEmpty ? 'Upload' : 'Re-upload'),
                  style: const TextStyle(fontSize: 12.5),
                ),
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 38),
                  backgroundColor: AppTheme.effectivePrimary,
                ),
              ),
            ),
          ]),
        if (template != null && status != 'approved') ...[
          const SizedBox(height: 10),
          _aiReviewNotice(),
        ],
      ]),
    );
  }

  /// Tells the student an automated check reads the upload before a person does.
  ///
  /// Without this the first rejection reads as the school accusing them of a
  /// mistake. Saying an AI checks it — and that staff can still be asked —
  /// makes a rejection something to fix rather than something to argue with.
  Widget _aiReviewNotice() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppTheme.effectivePrimary.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: AppTheme.effectivePrimary.withValues(alpha: 0.18)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.auto_awesome_rounded, size: 15, color: AppTheme.effectivePrimary),
        const SizedBox(width: 8),
        Expanded(
          child: RichText(
            text: TextSpan(
              style: TextStyle(fontSize: 11, color: Colors.grey.shade700, height: 1.45),
              children: [
                TextSpan(
                  text: 'Checked automatically. ',
                  style: TextStyle(
                      fontWeight: FontWeight.w700, color: AppTheme.effectivePrimary),
                ),
                const TextSpan(
                  text: 'An AI assistant reads your upload to confirm it is the right '
                      'form, that it is signed, and that the writing is readable. Make '
                      'sure the whole page is in frame, in focus, and well lit.\n'
                      'If it is rejected you can upload again — and your teacher can '
                      'always review it themselves.',
                ),
              ],
            ),
          ),
        ),
      ]),
    );
  }

  Widget _statusChip(String status, String? aiError) {
    late final Color color;
    late final String label;
    if (status == 'approved') {
      color = const Color(0xFF16A34A);
      label = 'Approved';
    } else if (status == 'rejected') {
      color = AppTheme.errorColor;
      label = 'Needs fixing';
    } else if (status == 'pending') {
      color = AppTheme.accentColor;
      label = aiError != null ? 'With the school' : 'Reviewing…';
    } else {
      color = Colors.grey.shade500;
      label = 'Not submitted';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color)),
    );
  }

  Widget _rejectionReasons(Map<String, dynamic>? sub) {
    final note = sub?['reviewNote']?.toString();
    final verdict = sub?['aiVerdict'] as Map<String, dynamic>?;
    final reasons = (verdict?['reasons'] as List?) ?? const [];
    if ((note == null || note.isEmpty) && reasons.isEmpty) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(11),
      decoration: BoxDecoration(
        color: AppTheme.errorColor.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: AppTheme.errorColor.withValues(alpha: 0.2)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('What to fix',
            style: TextStyle(
                fontSize: 11.5, fontWeight: FontWeight.bold, color: AppTheme.errorColor)),
        const SizedBox(height: 5),
        if (note != null && note.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Text(note,
                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade800, height: 1.4)),
          ),
        ...reasons.take(4).map((r) => Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text('• $r',
                  style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700, height: 1.4)),
            )),
      ]),
    );
  }
}
