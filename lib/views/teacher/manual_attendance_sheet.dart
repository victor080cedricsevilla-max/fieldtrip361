import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../config/theme.dart';
import '../../utils/attendance_service.dart';
import '../../utils/firestore_utils.dart';

/// Marking a student present by eye, and pausing their geofence warnings.
///
/// The two are deliberately separate actions on one screen. A flat battery is
/// usually both problems at once — the student cannot be scanned, and their
/// silent phone will keep alarming the group — but marking someone present
/// never mutes them, and muting never marks them present.
Future<void> showManualAttendanceSheet(
  BuildContext context, {
  required String tripId,
  required int stopIndex,
  String? preselectStudentId,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _ManualAttendanceSheet(
      tripId: tripId,
      stopIndex: stopIndex,
      preselectStudentId: preselectStudentId,
    ),
  );
}

class _ManualAttendanceSheet extends StatefulWidget {
  final String tripId;
  final int stopIndex;
  final String? preselectStudentId;

  const _ManualAttendanceSheet({
    required this.tripId,
    required this.stopIndex,
    this.preselectStudentId,
  });

  @override
  State<_ManualAttendanceSheet> createState() => _ManualAttendanceSheetState();
}

class _ManualAttendanceSheetState extends State<_ManualAttendanceSheet> {
  String? _studentId;
  final _reason = TextEditingController();
  final _exemptionReason = TextEditingController();
  bool _confirmedPresent = false;
  bool _warningsEnabled = true;
  bool _busy = false;
  String? _error;
  String? _success;

  static const _commonReasons = [
    'Phone battery is empty',
    'Device is lost or unavailable',
    'GPS is not working',
    'Phone left on the bus',
  ];

  @override
  void initState() {
    super.initState();
    _studentId = widget.preselectStudentId;
  }

  @override
  void dispose() {
    _reason.dispose();
    _exemptionReason.dispose();
    super.dispose();
  }

  Future<void> _markPresent() async {
    final id = _studentId;
    if (id == null) {
      setState(() => _error = 'Choose the student you can see.');
      return;
    }
    if (!_confirmedPresent) {
      setState(() => _error = 'Confirm that the student is with you.');
      return;
    }
    if (_reason.text.trim().length < 3) {
      setState(() => _error = 'Say why this is being recorded by hand.');
      return;
    }
    if (!_warningsEnabled && _exemptionReason.text.trim().length < 3) {
      setState(() => _error = 'Give a reason for pausing their geofence warnings.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _success = null;
    });
    try {
      final res = await AttendanceService.recordManual(
        tripId: widget.tripId,
        studentId: id,
        stopIndex: widget.stopIndex,
        reason: _reason.text.trim(),
      );

      // Applied only when the facilitator actually moved the switch, so marking
      // someone present never silences them as a side effect.
      if (!_warningsEnabled) {
        await AttendanceService.setGeofenceExemption(
          tripId: widget.tripId,
          studentId: id,
          warningsEnabled: false,
          reason: _exemptionReason.text.trim(),
        );
      }

      if (!mounted) return;
      final name = (res['studentName'] ?? 'The student').toString();
      setState(() {
        _success = res['already'] == true
            ? '$name was already marked present for this stop.'
            : '$name marked present.'
                '${_warningsEnabled ? '' : ' Geofence warnings paused for this trip.'}';
        _confirmedPresent = false;
        _reason.clear();
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = AttendanceService.describeError(e).message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _applyWarningsOnly(bool enabled) async {
    final id = _studentId;
    if (id == null) {
      setState(() => _error = 'Choose a student first.');
      return;
    }
    if (!enabled && _exemptionReason.text.trim().length < 3) {
      setState(() => _error = 'Give a reason for pausing their geofence warnings.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
      _success = null;
    });
    try {
      await AttendanceService.setGeofenceExemption(
        tripId: widget.tripId,
        studentId: id,
        warningsEnabled: enabled,
        reason: enabled ? null : _exemptionReason.text.trim(),
      );
      if (mounted) {
        setState(() => _success = enabled
            ? 'Geofence warnings switched back on. Any alert uses their current location.'
            : 'Geofence warnings paused for this trip.');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = AttendanceService.describeError(e).message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.viewInsetsOf(context).bottom;

    return Container(
      margin: EdgeInsets.only(bottom: bottomInset),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.92,
      ),
      child: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: FirebaseFirestore.instance
            .collection('trips')
            .doc(widget.tripId)
            .snapshots(),
        builder: (context, tripSnap) {
          final trip = tripSnap.data?.data();
          final myUid = FirebaseAuth.instance.currentUser?.uid;

          // Only the students on this facilitator's own bus.
          //
          // A Bus 1 teacher knows who is on Bus 1. Vouching for a Bus 2 student
          // would put a name on a roster nobody on that bus checked, and the
          // server refuses it anyway — so the list never offers the choice.
          final students = <Map<String, dynamic>>[];
          String? myBusLabel;
          for (final bus in asList(trip?['buses'])) {
            if (bus is! Map) continue;
            final mine = bus['mainTeacher']?['id'] == myUid ||
                bus['coTeacher']?['id'] == myUid;
            if (!mine) continue;
            myBusLabel = (bus['busLabel'] ?? bus['busNo'] ?? '').toString();
            for (final p in asList(bus['passengers'])) {
              if (p is Map) students.add(Map<String, dynamic>.from(p));
            }
          }
          students.sort((a, b) =>
              (a['name'] ?? '').toString().compareTo((b['name'] ?? '').toString()));

          final stops = asList(trip?['stops']);
          final stopName = widget.stopIndex < stops.length
              ? ((stops[widget.stopIndex] as Map)['name']?.toString() ?? 'this stop')
              : 'this stop';

          return StreamBuilder<Map<String, Map<String, dynamic>>>(
            stream: AttendanceService.exemptions(widget.tripId),
            builder: (context, exSnap) {
              final exemptions = exSnap.data ?? const {};
              final selectedExemption =
                  _studentId == null ? null : exemptions[_studentId!];
              final currentlyPaused = selectedExemption != null &&
                  selectedExemption['warningsEnabled'] == false;

              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade300,
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                    const Text(
                      'Manual attendance',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.secondaryColor,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'For $stopName'
                      '${myBusLabel == null || myBusLabel.isEmpty ? '' : ', Bus $myBusLabel'}. '
                      'Use this when a student is in front of you but their phone '
                      'cannot be scanned.',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.5,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(height: 20),

                    if (_success != null) ...[
                      _Banner(
                        text: _success!,
                        colour: Colors.green.shade700,
                        icon: Icons.check_circle_outline_rounded,
                      ),
                      const SizedBox(height: 14),
                    ],
                    if (_error != null) ...[
                      _Banner(
                        text: _error!,
                        colour: Colors.red.shade700,
                        icon: Icons.error_outline_rounded,
                      ),
                      const SizedBox(height: 14),
                    ],

                    const _Label('Student'),
                    const SizedBox(height: 8),
                    if (students.isEmpty)
                      _Banner(
                        text: tripSnap.hasData
                            ? 'No students are assigned to your bus on this trip. '
                                'Ask your school administrator to assign them.'
                            : 'Loading your bus roster…',
                        colour: Colors.grey.shade700,
                        icon: Icons.people_outline_rounded,
                      )
                    else
                    DropdownButtonFormField<String>(
                      initialValue: _studentId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        prefixIcon: Icon(Icons.person_search_rounded),
                        hintText: 'Choose from the roster',
                      ),
                      items: students.map((s) {
                        final id = (s['id'] ?? '').toString();
                        final paused = exemptions[id]?['warningsEnabled'] == false;
                        final present =
                            (s['attendance'] ?? const {})['stop_${widget.stopIndex}'] == true;
                        return DropdownMenuItem(
                          value: id,
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  (s['name'] ?? 'Student').toString(),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (present)
                                const Icon(Icons.check_circle,
                                    size: 15, color: Colors.green),
                              if (paused)
                                Padding(
                                  padding: const EdgeInsets.only(left: 4),
                                  child: Icon(Icons.notifications_off_rounded,
                                      size: 15, color: Colors.orange.shade700),
                                ),
                            ],
                          ),
                        );
                      }).toList(),
                      onChanged: (v) => setState(() {
                        _studentId = v;
                        _error = null;
                        _success = null;
                        _warningsEnabled = exemptions[v]?['warningsEnabled'] != false;
                      }),
                    ),

                    if (currentlyPaused) ...[
                      const SizedBox(height: 12),
                      _Banner(
                        text: 'Geofence warnings are currently paused for this student'
                            '${(selectedExemption['reason'] ?? '').toString().isEmpty ? '' : ' — ${selectedExemption['reason']}'}.',
                        colour: Colors.orange.shade800,
                        icon: Icons.notifications_off_rounded,
                      ),
                    ],

                    const SizedBox(height: 20),
                    const _Label('Why is this being recorded by hand?'),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: _commonReasons
                          .map((r) => ActionChip(
                                label: Text(r, style: const TextStyle(fontSize: 12)),
                                onPressed: () => setState(() => _reason.text = r),
                              ))
                          .toList(),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _reason,
                      minLines: 2,
                      maxLines: 3,
                      decoration: const InputDecoration(
                        hintText: 'This appears in the attendance report.',
                      ),
                    ),

                    const SizedBox(height: 16),
                    CheckboxListTile(
                      value: _confirmedPresent,
                      onChanged: (v) => setState(() => _confirmedPresent = v ?? false),
                      controlAffinity: ListTileControlAffinity.leading,
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'I can see this student here now',
                        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                      ),
                      subtitle: Text(
                        'Manual attendance records your word for it, so it is marked '
                        'as such in reports.',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                      ),
                    ),

                    const Divider(height: 28),

                    SwitchListTile(
                      value: _warningsEnabled,
                      onChanged: (v) => setState(() {
                        _warningsEnabled = v;
                        _error = null;
                      }),
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Enable geofence warnings for this student',
                        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                      ),
                      subtitle: Text(
                        _warningsEnabled
                            ? 'On — you and their parent are warned if they leave the area, '
                                'as long as the trip setting allows it.'
                            : 'Off — no warning sound or notification for this student, for '
                                'you or their parent, until you switch it back on or the trip ends. '
                                'Their attendance still has to pass the location check when scanned.',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.45,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ),
                    if (!_warningsEnabled) ...[
                      const SizedBox(height: 8),
                      TextField(
                        controller: _exemptionReason,
                        decoration: const InputDecoration(
                          hintText: 'Reason, e.g. Phone battery empty',
                          prefixIcon: Icon(Icons.edit_note_rounded),
                        ),
                      ),
                    ],

                    const SizedBox(height: 22),
                    SizedBox(
                      width: double.infinity,
                      height: 50,
                      child: ElevatedButton.icon(
                        onPressed: _busy ? null : _markPresent,
                        icon: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.how_to_reg_rounded, size: 20),
                        label: const Text('Mark present'),
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      width: double.infinity,
                      height: 46,
                      child: OutlinedButton.icon(
                        onPressed: _busy || _studentId == null
                            ? null
                            : () => _applyWarningsOnly(_warningsEnabled),
                        icon: Icon(
                          _warningsEnabled
                              ? Icons.notifications_active_outlined
                              : Icons.notifications_off_outlined,
                          size: 18,
                        ),
                        label: Text(
                          _warningsEnabled
                              ? 'Only switch warnings back on'
                              : 'Only pause warnings (do not mark present)',
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: AppTheme.secondaryColor,
        ),
      );
}

class _Banner extends StatelessWidget {
  final String text;
  final Color colour;
  final IconData icon;

  const _Banner({required this.text, required this.colour, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: colour.withValues(alpha: 0.08),
          border: Border.all(color: colour.withValues(alpha: 0.35)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: colour),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: TextStyle(fontSize: 13, height: 1.45, color: colour),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
