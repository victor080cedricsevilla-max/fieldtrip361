import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../config/theme.dart';
import '../../widgets/glass_nav_scaffold.dart';
import '../../utils/document_service.dart';

/// Read-only view of pre-trip paperwork for the buses this teacher runs.
///
/// Shows who has not uploaded yet and what the reviewer decided, so a teacher
/// can chase up missing waivers. The school admin makes the final call, so there
/// are no approve/reject controls here.
class TeacherDocumentsTab extends StatefulWidget {
  const TeacherDocumentsTab({super.key});

  @override
  State<TeacherDocumentsTab> createState() => _TeacherDocumentsTabState();
}

class _TeacherDocumentsTabState extends State<TeacherDocumentsTab> {
  String? get _uid => FirebaseAuth.instance.currentUser?.uid;

  /// Opens a student's upload in the browser or device viewer.
  ///
  /// Handing over the download URL avoids reading bytes through Storage's
  /// `getData()`, which on web needs a bucket CORS policy and otherwise fails
  /// with an opaque ClientException.
  Future<void> _viewFile(Map<String, dynamic> m, String title) async {
    try {
      await DocumentService.open((m['downloadUrl'] ?? '').toString());
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not open $title. $e'),
          backgroundColor: AppTheme.errorColor,
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final uid = _uid;
    return Scaffold(
      backgroundColor: const Color(0xFFF5F6FA),
      appBar: AppBar(
        title: const Text("Trip Forms",
            style: TextStyle(
                fontWeight: FontWeight.bold, fontSize: 18, color: AppTheme.secondaryColor)),
        backgroundColor: Colors.white,
        elevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      body: uid == null
          ? const SizedBox.shrink()
          : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('trips')
                  .where('allMemberIds', arrayContains: uid)
                  .snapshots(),
              builder: (context, tripSnap) {
                if (!tripSnap.hasData) {
                  return Center(
                      child: CircularProgressIndicator(color: AppTheme.effectivePrimary));
                }

                // Only trips I run a bus on, that still need paperwork.
                final trips = tripSnap.data!.docs.where((d) {
                  final data = d.data();
                  if ((data['status'] ?? '') == 'completed') return false;
                  if (DocumentService.requiredTypes(data).isEmpty) return false;
                  for (final bus in (data['buses'] as List?) ?? const []) {
                    if (bus is! Map) continue;
                    if (bus['mainTeacher']?['id'] == uid || bus['coTeacher']?['id'] == uid) {
                      return true;
                    }
                  }
                  return false;
                }).toList()
                  ..sort((a, b) => (b.data()['date'] ?? '')
                      .toString()
                      .compareTo((a.data()['date'] ?? '').toString()));

                if (trips.isEmpty) return _empty();

                return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                  // Scoped by school, not by trip: the security rule keys off
                  // schoolId, and Firestore refuses a query it cannot prove
                  // safe. The trips are narrowed just below.
                  stream: DocumentService.submissionsForFacilitator(),
                  builder: (context, subSnap) {
                    // A refused read used to fall through as an empty list, so
                    // every student read "Not uploaded" whether they had
                    // uploaded or not. Say which it is.
                    if (subSnap.hasError) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Text(
                            "Form statuses could not be loaded. Your account may not be "
                            "linked to a school yet — ask your administrator.",
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                          ),
                        ),
                      );
                    }
                    final tripIds = trips.map((t) => t.id).toSet();
                    final mine = (subSnap.data?.docs ?? const [])
                        .where((d) => tripIds.contains(d.data()['tripId']))
                        .toList();
                    final latest = DocumentService.latestByKey(
                      mine,
                      (d) => '${d['tripId']}_${d['studentId']}_${d['type']}',
                    );
                    return ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, GlassNavScaffold.bottomInset),
                      itemCount: trips.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 14),
                      itemBuilder: (context, i) => _tripCard(trips[i], uid, latest),
                    );
                  },
                );
              },
            ),
    );
  }

  Widget _empty() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.assignment_outlined, size: 52, color: Colors.grey.shade300),
          const SizedBox(height: 14),
          const Text('No forms to track',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            'None of your active trips require waivers. When an admin attaches forms to '
            'a trip you run, each student’s progress shows up here.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade600, height: 1.55),
          ),
        ]),
      ),
    );
  }

  Widget _tripCard(
    QueryDocumentSnapshot<Map<String, dynamic>> trip,
    String uid,
    Map<String, QueryDocumentSnapshot<Map<String, dynamic>>> latest,
  ) {
    final data = trip.data();
    final tripId = trip.id;
    final required = DocumentService.requiredTypes(data);

    // Only the passengers on buses this teacher is assigned to.
    final passengers = <Map<String, String>>[];
    for (final bus in (data['buses'] as List?) ?? const []) {
      if (bus is! Map) continue;
      if (bus['mainTeacher']?['id'] != uid && bus['coTeacher']?['id'] != uid) continue;
      final label = (bus['busLabel'] ?? bus['busNo'] ?? '?').toString();
      for (final p in (bus['passengers'] as List?) ?? const []) {
        if (p is! Map || p['id'] == null) continue;
        passengers.add({
          'id': p['id'].toString(),
          'name': (p['name'] ?? 'Student').toString(),
          'bus': label,
        });
      }
    }
    passengers.sort((a, b) => a['name']!.toLowerCase().compareTo(b['name']!.toLowerCase()));

    String statusOf(String sid, String type) =>
        (latest['${tripId}_${sid}_$type']?.data()['status'] ?? '').toString();
    bool cleared(String sid) => required.every((t) => statusOf(sid, t) == 'approved');

    final clearedCount = passengers.where((p) => cleared(p['id']!)).length;
    final waiting = passengers.length - clearedCount;

    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: waiting > 0,
          tilePadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          leading: Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: (waiting == 0 ? const Color(0xFF16A34A) : AppTheme.accentColor)
                  .withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(
              waiting == 0 ? Icons.verified_rounded : Icons.pending_actions_rounded,
              size: 20,
              color: waiting == 0 ? const Color(0xFF16A34A) : AppTheme.accentColor,
            ),
          ),
          title: Text((data['title'] ?? 'Field Trip').toString(),
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14.5)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              waiting == 0
                  ? 'All ${passengers.length} students cleared'
                  : '$waiting of ${passengers.length} still waiting on forms',
              style: TextStyle(
                fontSize: 12,
                color: waiting == 0 ? const Color(0xFF16A34A) : Colors.orange.shade900,
              ),
            ),
          ),
          children: [
            if (passengers.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text('No students assigned to your bus yet.',
                    style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600)),
              )
            else
              for (final p in passengers)
                _studentRow(tripId, p, required, latest, cleared(p['id']!)),
          ],
        ),
      ),
    );
  }

  Widget _studentRow(
    String tripId,
    Map<String, String> p,
    List<String> required,
    Map<String, QueryDocumentSnapshot<Map<String, dynamic>>> latest,
    bool cleared,
  ) {
    final sid = p['id']!;

    // Collapsed by default once cleared, so a long bus list stays scannable and
    // the students still missing forms are the ones already open.
    final summary = required
        .map((t) => (latest['${tripId}_${sid}_$t']?.data()['status'] ?? '').toString())
        .map((s) => switch (s) {
              'approved' => 'approved',
              'rejected' => 'rejected',
              'pending' => 'in review',
              _ => 'not uploaded',
            })
        .join(' · ');

    return Container(
      margin: const EdgeInsets.only(top: 9),
      decoration: BoxDecoration(
        color: const Color(0xFFFAFAFA),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFEFEFEF)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: !cleared,
          dense: true,
          tilePadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
          leading: CircleAvatar(
            radius: 14,
            backgroundColor: AppTheme.effectivePrimary.withValues(alpha: 0.12),
            child: Text(
              p['name']!.isNotEmpty ? p['name']![0].toUpperCase() : '?',
              style: TextStyle(
                  fontSize: 12, fontWeight: FontWeight.bold,
                  color: AppTheme.effectivePrimary),
            ),
          ),
          title: Text(p['name']!,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(summary,
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ),
          trailing: Icon(
              cleared ? Icons.chat_bubble_rounded : Icons.chat_bubble_outline_rounded,
              size: 15,
              color: cleared ? const Color(0xFF16A34A) : Colors.grey.shade400),
          children: [
            for (final type in required)
              _line(tripId, sid, p['name']!, type, latest['${tripId}_${sid}_$type']),
          ],
        ),
      ),
    );
  }

  Widget _line(
    String tripId,
    String sid,
    String name,
    String type,
    QueryDocumentSnapshot<Map<String, dynamic>>? submission,
  ) {
    final m = submission?.data();
    final status = (m?['status'] ?? '').toString();
    final aiError = m?['aiError']?.toString();

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
        label = aiError != null ? 'With the school' : 'Reviewing…';
      default:
        color = Colors.grey.shade500;
        label = 'Not uploaded';
    }

    final title = '$name — ${DocType.short(type)}';

    return Padding(
      padding: const EdgeInsets.only(top: 7, left: 34),
      child: Row(children: [
        Icon(DocType.icon(type), size: 14, color: Colors.grey.shade500),
        const SizedBox(width: 7),
        Expanded(
          child: Text(DocType.short(type),
              style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
        ),
        if (submission != null)
          IconButton(
            onPressed: () => _viewFile(m!, title),
            icon: const Icon(Icons.visibility_outlined, size: 16),
            color: Colors.grey.shade500,
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(),
            padding: const EdgeInsets.only(right: 8),
            tooltip: 'View upload',
          ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(label,
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: color)),
        ),
      ]),
    );
  }
}
