import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../../config/theme.dart';
import '../../utils/document_service.dart';
import '../../utils/school_context.dart';

/// Admin review of pre-trip paperwork, grouped by trip.
///
/// Blank forms are attached when the trip is created, so this page is where the
/// admin sees what was attached, who has submitted, and what the AI decided —
/// with the final say via an override.
class DocumentsView extends StatefulWidget {
  const DocumentsView({super.key});

  @override
  State<DocumentsView> createState() => _DocumentsViewState();
}

class _DocumentsViewState extends State<DocumentsView> {
  String? _schoolId;
  bool _loading = true;
  String? _busy;
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = await SchoolContext.schoolId(forceRefresh: true);
    if (!mounted) return;
    setState(() {
      _schoolId = id;
      _loading = false;
    });
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  Future<void> _override(String submissionId, String decision, String studentName) async {
    final noteCtrl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(decision == 'approved' ? 'Approve document?' : 'Reject document?'),
        content: SizedBox(
          width: 400,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(
              decision == 'approved'
                  ? "This marks $studentName's document as accepted and adds them to the "
                      "bus group chat once their other forms are cleared too."
                  : "This marks $studentName's document as rejected. They will be asked to "
                      "upload a corrected copy and stay out of the bus chat until then.",
              style: const TextStyle(fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: noteCtrl,
              maxLines: 2,
              decoration: InputDecoration(
                labelText: decision == 'approved' ? 'Note (optional)' : 'What needs fixing?',
                isDense: true,
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor:
                  decision == 'approved' ? const Color(0xFF16A34A) : AppTheme.errorColor,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(decision == 'approved' ? 'Approve' : 'Reject'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _busy = submissionId);
    try {
      await FirebaseFunctions.instance
          .httpsCallable('reviewDocumentSubmission')
          .call(<String, dynamic>{
        'submissionId': submissionId,
        'decision': decision,
        'note': noteCtrl.text.trim(),
      });
      if (mounted) _toast('Decision saved.');
    } on FirebaseFunctionsException catch (e) {
      if (mounted) _toast(e.message ?? 'Could not save that decision.', isError: true);
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  /// Opens a stored document in the browser or the device's viewer.
  ///
  /// Handing the download URL to the platform avoids reading the bytes through
  /// Storage's `getData()`, which on web is an XHR requiring a bucket CORS
  /// policy — without one it fails with an opaque ClientException.
  Future<void> _viewFile(String downloadUrl, String title) async {
    try {
      await DocumentService.open(downloadUrl);
    } catch (e) {
      if (mounted) _toast('Could not open $title. $e', isError: true);
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
    if (_schoolId == null) return _noSchool();

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _filterBar(),
      const SizedBox(height: 14),
      Expanded(child: _tripList()),
    ]);
  }

  Widget _noSchool() {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 440),
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.folder_off_outlined, size: 46, color: Colors.grey.shade300),
          const SizedBox(height: 14),
          const Text('No school linked to this account',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('Trip documents are scoped per school.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade600)),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            onPressed: _load,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Check again'),
          ),
        ]),
      ),
    );
  }

  Widget _filterBar() {
    Widget chip(String value, String label) {
      final on = _filter == value;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(label),
          selected: on,
          onSelected: (_) => setState(() => _filter = value),
          labelStyle: TextStyle(
            fontSize: 12.5,
            fontWeight: on ? FontWeight.w600 : FontWeight.normal,
            color: on ? Colors.white : Colors.grey.shade700,
          ),
          selectedColor: AppTheme.effectivePrimary,
          backgroundColor: Colors.white,
          side: BorderSide(color: on ? AppTheme.effectivePrimary : const Color(0xFFE5E7EB)),
          showCheckmark: false,
        ),
      );
    }

    return Row(children: [
      chip('all', 'All students'),
      chip('outstanding', 'Not yet cleared'),
      chip('pending', 'Awaiting review'),
      chip('rejected', 'Rejected'),
    ]);
  }

  Widget _tripList() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('trips')
          .where('schoolId', isEqualTo: _schoolId)
          .snapshots(),
      builder: (context, tripSnap) {
        if (tripSnap.hasError) {
          return _note('Could not load trips.\n${tripSnap.error}');
        }
        if (!tripSnap.hasData) {
          return Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary));
        }

        final trips = tripSnap.data!.docs
            .where((d) => DocumentService.requiredTypes(d.data()).isNotEmpty)
            .toList()
          ..sort((a, b) => (b.data()['date'] ?? '')
              .toString()
              .compareTo((a.data()['date'] ?? '').toString()));

        if (trips.isEmpty) return _emptyState();

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: DocumentService.submissionsOfSchool(_schoolId!),
          builder: (context, subSnap) {
            final latest = DocumentService.latestByKey(
              subSnap.data?.docs ?? const [],
              (d) => '${d['tripId']}_${d['studentId']}_${d['type']}',
            );
            return ListView.separated(
              itemCount: trips.length,
              separatorBuilder: (_, __) => const SizedBox(height: 14),
              itemBuilder: (context, i) => _tripCard(trips[i], latest),
            );
          },
        );
      },
    );
  }

  Widget _note(String text) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(text,
              textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade600)),
        ),
      );

  Widget _emptyState() {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 480),
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.inbox_outlined, size: 48, color: Colors.grey.shade300),
          const SizedBox(height: 14),
          const Text('No trip documents yet',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            'Blank forms are attached when you create a trip. Open Create Trip, fill in '
            'the Trip Documents section, and the waivers will show up here along with '
            'each student’s submission.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade600, height: 1.55),
          ),
        ]),
      ),
    );
  }

  /// All students assigned to a trip, flattened across its buses.
  List<Map<String, String>> _passengersOf(Map<String, dynamic> trip) {
    final out = <Map<String, String>>[];
    for (final bus in (trip['buses'] as List?) ?? const []) {
      if (bus is! Map) continue;
      final label = (bus['busLabel'] ?? bus['busNo'] ?? '?').toString();
      for (final p in (bus['passengers'] as List?) ?? const []) {
        if (p is! Map || p['id'] == null) continue;
        out.add({
          'id': p['id'].toString(),
          'name': (p['name'] ?? 'Student').toString(),
          'bus': label,
        });
      }
    }
    out.sort((a, b) => a['name']!.toLowerCase().compareTo(b['name']!.toLowerCase()));
    return out;
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
    final passengers = _passengersOf(data);

    String statusOf(String uid, String type) =>
        (latest['${tripId}_${uid}_$type']?.data()['status'] ?? '').toString();

    bool cleared(String uid) => required.every((t) => statusOf(uid, t) == 'approved');

    final clearedCount = passengers.where((p) => cleared(p['id']!)).length;

    // Filter students by the selected review state.
    final shown = passengers.where((p) {
      final uid = p['id']!;
      switch (_filter) {
        case 'outstanding':
          return !cleared(uid);
        case 'pending':
          return required.any((t) => statusOf(uid, t) == 'pending');
        case 'rejected':
          return required.any((t) => statusOf(uid, t) == 'rejected');
        default:
          return true;
      }
    }).toList();

    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: passengers.isNotEmpty && clearedCount < passengers.length,
          tilePadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
          childrenPadding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          leading: Container(
            width: 42, height: 42,
            decoration: BoxDecoration(
              color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(Icons.assignment_outlined,
                size: 21, color: AppTheme.effectivePrimary),
          ),
          title: Text(title,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              [
                if (date.isNotEmpty) date,
                '${required.length} ${required.length == 1 ? "form" : "forms"} required',
                '$clearedCount of ${passengers.length} cleared',
              ].join(' · '),
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ),
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: (clearedCount == passengers.length && passengers.isNotEmpty
                      ? const Color(0xFF16A34A)
                      : AppTheme.accentColor)
                  .withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              passengers.isEmpty
                  ? 'No students'
                  : (clearedCount == passengers.length ? 'All cleared' : 'Pending'),
              style: TextStyle(
                fontSize: 11, fontWeight: FontWeight.w600,
                color: clearedCount == passengers.length && passengers.isNotEmpty
                    ? const Color(0xFF16A34A)
                    : Colors.orange.shade900,
              ),
            ),
          ),
          children: [
            // The blank forms attached to this trip.
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(spacing: 8, runSpacing: 8, children: [
                for (final type in required)
                  OutlinedButton.icon(
                    onPressed: () => _viewFile(
                      (templates[type]!['downloadUrl'] ?? '').toString(),
                      '${DocType.label(type)} template',
                    ),
                    icon: Icon(DocType.icon(type), size: 16),
                    label: Text('${DocType.short(type)} template',
                        style: const TextStyle(fontSize: 12)),
                    style: OutlinedButton.styleFrom(minimumSize: const Size(0, 34)),
                  ),
              ]),
            ),
            const SizedBox(height: 6),
            const Divider(),
            if (passengers.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Text('No students are assigned to this trip yet.',
                    style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600)),
              )
            else if (shown.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Text('No students match this filter.',
                    style: TextStyle(fontSize: 12.5, color: Colors.grey.shade500)),
              )
            else
              for (final p in shown)
                _studentRow(tripId, p, required, latest, cleared(p['id']!)),
          ],
        ),
      ),
    );
  }

  Widget _studentRow(
    String tripId,
    Map<String, String> passenger,
    List<String> required,
    Map<String, QueryDocumentSnapshot<Map<String, dynamic>>> latest,
    bool cleared,
  ) {
    final uid = passenger['id']!;
    final name = passenger['name']!;

    // One collapsed row per student — a class of 200 would otherwise render as
    // an unusable wall of text. Rows needing attention open by themselves.
    final summary = required
        .map((t) => (latest['${tripId}_${uid}_$t']?.data()['status'] ?? '').toString())
        .map((s) => switch (s) {
              'approved' => 'approved',
              'rejected' => 'rejected',
              'pending' => 'in review',
              _ => 'not submitted',
            })
        .toList();

    return Container(
      margin: const EdgeInsets.only(top: 10),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFA),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: const Color(0xFFEFEFEF)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: !cleared,
          dense: true,
          tilePadding: const EdgeInsets.symmetric(horizontal: 13, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(13, 0, 13, 10),
          leading: Icon(cleared ? Icons.lock_open_rounded : Icons.lock_outline_rounded,
              size: 17,
              color: cleared ? const Color(0xFF16A34A) : AppTheme.accentColor),
          title: Text('$name  ·  Bus ${passenger['bus']}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              summary.join(' · '),
              style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
            ),
          ),
          trailing: Text(cleared ? 'In bus chat' : 'Held out of chat',
              style: TextStyle(
                fontSize: 10.5,
                fontWeight: FontWeight.w600,
                color: cleared ? const Color(0xFF16A34A) : Colors.orange.shade900,
              )),
          children: [
            for (final type in required)
              _submissionLine(tripId, uid, name, type, latest['${tripId}_${uid}_$type']),
          ],
        ),
      ),
    );
  }

  Widget _submissionLine(
    String tripId,
    String uid,
    String studentName,
    String type,
    QueryDocumentSnapshot<Map<String, dynamic>>? submission,
  ) {
    final m = submission?.data();
    final status = (m?['status'] ?? '').toString();
    final aiError = m?['aiError']?.toString();
    final verdict = m?['aiVerdict'] as Map<String, dynamic>?;
    final reasons = (verdict?['reasons'] as List?) ?? const [];
    final confidence = verdict?['confidence'];
    final decidedBy = (m?['decidedBy'] ?? '').toString();
    final busy = submission != null && _busy == submission.id;

    Color color;
    String label;
    switch (status) {
      case 'approved':
        color = const Color(0xFF16A34A);
        label = 'Approved';
      case 'rejected':
        color = AppTheme.errorColor;
        label = 'Rejected';
      case 'pending':
        color = AppTheme.accentColor;
        label = aiError != null ? 'Needs manual review' : 'Reviewing…';
      default:
        color = Colors.grey.shade500;
        label = 'Not submitted';
    }

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const SizedBox(width: 25),
          Icon(DocType.icon(type), size: 15, color: Colors.grey.shade500),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              DocType.short(type) +
                  (confidence != null ? '  ·  $confidence% confidence' : '') +
                  (decidedBy == 'admin' ? '  ·  admin decision' : ''),
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(label,
                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color)),
          ),
        ]),
        if (reasons.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 48, top: 4),
            child: Text('• ${reasons.first}',
                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600, height: 1.4)),
          ),
        if (aiError != null)
          Padding(
            padding: const EdgeInsets.only(left: 48, top: 4),
            child: Text(aiError,
                style: TextStyle(fontSize: 11.5, color: Colors.orange.shade900, height: 1.4)),
          ),
        if (submission != null)
          Padding(
            padding: const EdgeInsets.only(left: 45, top: 6),
            child: Row(children: [
              TextButton.icon(
                onPressed: busy
                    ? null
                    : () => _viewFile(
                          (m!['downloadUrl'] ?? '').toString(),
                          "$studentName's ${DocType.short(type)}",
                        ),
                icon: const Icon(Icons.visibility_outlined, size: 15),
                label: const Text('View', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 30),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
              ),
              if (status != 'rejected')
                TextButton.icon(
                  onPressed: busy ? null : () => _override(submission.id, 'rejected', studentName),
                  icon: const Icon(Icons.close_rounded, size: 15),
                  label: const Text('Reject', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.errorColor,
                    minimumSize: const Size(0, 30),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
              if (status != 'approved')
                TextButton.icon(
                  onPressed: busy ? null : () => _override(submission.id, 'approved', studentName),
                  icon: const Icon(Icons.check_rounded, size: 15),
                  label: const Text('Approve', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF16A34A),
                    minimumSize: const Size(0, 30),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
            ]),
          ),
      ]),
    );
  }
}
