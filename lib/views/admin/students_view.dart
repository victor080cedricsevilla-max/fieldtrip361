import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../../config/theme.dart';
import '../../utils/file_download.dart';
import '../../utils/guardian_service.dart';
import '../../utils/roster_csv.dart';
import 'bulk_import_view.dart';
import '../../utils/school_context.dart';

/// Where a student sits in the parent-linking process, as one value the roster
/// can be filtered on.
enum RosterFilter {
  all('All students'),
  linked('Parent linked'),
  pending('Pending — code sent'),
  ready('Ready to send'),
  noContact('No email/phone found'),
  noGuardian('No guardian assigned');

  const RosterFilter(this.label);
  final String label;
}

/// School roster management: bulk CSV import, manual entry, and the live
/// capacity meter tied to the school's subscription tier.
class StudentsView extends StatefulWidget {
  const StudentsView({super.key});

  @override
  State<StudentsView> createState() => _StudentsViewState();
}

class _StudentsViewState extends State<StudentsView> {
  String? _schoolId;
  bool _loadingSchool = true;
  bool _busy = false;
  String _search = '';
  RosterFilter _filter = RosterFilter.all;
  final _searchCtrl = TextEditingController();

  /// The stage a student has reached, derived from their guardians.
  ///
  /// Ordered by precedence: one linked parent outranks a second guardian still
  /// waiting, because the child is already reachable.
  static RosterFilter _stageOf(List<Map<String, dynamic>> guardians) {
    if (guardians.isEmpty) return RosterFilter.noGuardian;
    if (guardians.any(GuardianService.isLinked)) return RosterFilter.linked;
    if (guardians.any(GuardianService.isPending)) return RosterFilter.pending;
    if (guardians.any(GuardianService.isAwaitingCode)) return RosterFilter.ready;
    return RosterFilter.noContact;
  }

  @override
  void initState() {
    super.initState();
    _loadSchool();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadSchool() async {
    final id = await SchoolContext.schoolId(forceRefresh: true);
    if (!mounted) return;
    setState(() {
      _schoolId = id;
      _loadingSchool = false;
    });
  }

  // ── Actions ───────────────────────────────────────────────────────────────

  /// Opens the guided import: upload, map columns, validate, review, confirm.
  ///
  /// The roster is read first so the wizard can flag students that already
  /// exist while the admin is still reviewing, rather than after the fact.
  Future<void> _openImportWizard() async {
    setState(() => _busy = true);
    final numbers = <String>{};
    final emails = <String>{};
    try {
      final snap = await FirebaseFirestore.instance
          .collection('roster')
          .where('schoolId', isEqualTo: _schoolId)
          .get();
      for (final d in snap.docs) {
        final n = (d.data()['studentNumber'] ?? '').toString().toUpperCase();
        final e = (d.data()['email'] ?? '').toString().toLowerCase();
        if (n.isNotEmpty) numbers.add(n);
        if (e.isNotEmpty) emails.add(e);
      }
    } catch (_) {
      // Duplicate pre-checking is a convenience; the server enforces it anyway.
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => BulkImportView(
        schoolId: _schoolId!,
        existingStudentNumbers: numbers,
        existingEmails: emails,
      ),
    );
    if (result != null && mounted) _showImportResult(result);
  }

  Future<void> _runImport(List<Map<String, dynamic>> rows, {required String source}) async {
    setState(() => _busy = true);
    try {
      final callable = FirebaseFunctions.instance.httpsCallable('importRoster');
      final res = await callable.call(<String, dynamic>{'rows': rows, 'source': source});
      final data = Map<String, dynamic>.from(res.data as Map);
      if (!mounted) return;
      _showImportResult(data);
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      _showMessageDialog('Import failed', e.message ?? 'Please try again.', isError: true);
    } catch (_) {
      if (!mounted) return;
      _showMessageDialog('Import failed', 'Something went wrong. Please try again.', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addManually() async {
    final formKey = GlobalKey<FormState>();
    final first = TextEditingController();
    final last = TextEditingController();
    final number = TextEditingController();
    final email = TextEditingController();
    final grade = TextEditingController();
    final section = TextEditingController();
    final parentName = TextEditingController();
    final parentEmail = TextEditingController();

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Add student'),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Form(
              key: formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    Expanded(child: _dialogField(first, 'First name', required: true)),
                    const SizedBox(width: 10),
                    Expanded(child: _dialogField(last, 'Last name')),
                  ]),
                  const SizedBox(height: 10),
                  _dialogField(number, 'Student number / LRN'),
                  const SizedBox(height: 10),
                  _dialogField(email, 'Student email', isEmail: true),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(child: _dialogField(grade, 'Grade level')),
                    const SizedBox(width: 10),
                    Expanded(child: _dialogField(section, 'Section')),
                  ]),
                  const SizedBox(height: 10),
                  _dialogField(parentName, 'Parent / guardian name'),
                  const SizedBox(height: 10),
                  _dialogField(parentEmail, 'Parent email', isEmail: true),
                  const SizedBox(height: 8),
                  Text(
                    'The parent is linked to this student automatically once they '
                    'register with this email.',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600, height: 1.4),
                  ),
                ],
              ),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.effectivePrimary),
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) Navigator.pop(ctx, true);
            },
            child: const Text('Add student'),
          ),
        ],
      ),
    );

    if (saved != true) return;
    if (number.text.trim().isEmpty && email.text.trim().isEmpty) {
      _showMessageDialog(
        'Cannot add student',
        'Please provide a student number or an email so the record can be matched later.',
        isError: true,
      );
      return;
    }

    await _runImport([
      {
        '__row': 1,
        'studentNumber': number.text.trim(),
        'firstName': first.text.trim(),
        'lastName': last.text.trim(),
        'email': email.text.trim(),
        'gradeLevel': grade.text.trim(),
        'section': section.text.trim(),
        'parentName': parentName.text.trim(),
        'parentEmail': parentEmail.text.trim(),
      }
    ], source: 'manual');
  }

  /// Links a roster entry to an account that already registered.
  ///
  /// Registration normally claims the roster row automatically; this is the
  /// recovery path when that never happened, so an admin never has to edit
  /// Firestore by hand.
  Future<void> _linkAccount(String rosterId, String name, String email) async {
    setState(() => _busy = true);
    try {
      await FirebaseFunctions.instance
          .httpsCallable('linkRosterAccount')
          .call(<String, dynamic>{'rosterId': rosterId});
      if (mounted) _toast('$name is now linked to their account.');
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      _showMessageDialog(
        'Could not link $name',
        e.message ?? 'Please try again.',
        isError: true,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(String rosterId, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Remove student?'),
        content: Text(
          '$name will be removed from your roster and the subscription slot is freed. '
          'If they already have an account it stays, but they will no longer belong to your school.',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('Remove', style: TextStyle(color: AppTheme.errorColor)),
          ),
        ],
      ),
    );
    if (ok != true) return;

    setState(() => _busy = true);
    try {
      await FirebaseFunctions.instance
          .httpsCallable('removeRosterEntry')
          .call(<String, dynamic>{'rosterId': rosterId});
      if (mounted) _toast('$name removed from the roster.');
    } on FirebaseFunctionsException catch (e) {
      if (mounted) _toast(e.message ?? 'Could not remove that student.', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Dialogs & feedback ────────────────────────────────────────────────────

  Widget _dialogField(
    TextEditingController c,
    String label, {
    bool required = false,
    bool isEmail = false,
  }) {
    return TextFormField(
      controller: c,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
      ),
      validator: (v) {
        final t = (v ?? '').trim();
        if (required && t.isEmpty) return 'Required';
        if (isEmail && t.isNotEmpty && !RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$').hasMatch(t)) {
          return 'Invalid email';
        }
        return null;
      },
    );
  }

  void _showImportResult(Map<String, dynamic> d) {
    // Callable results arrive as JS numbers on web, so every count may be a
    // double — read them as num before converting.
    int asInt(Object? v) => (v as num?)?.toInt() ?? 0;

    final imported = asInt(d['imported']);
    final duplicates = asInt(d['duplicates']);
    final overCapacity = asInt(d['overCapacity']);
    final invalidCount = asInt(d['invalidCount']);
    final remaining = d['remaining'] == null ? null : asInt(d['remaining']);
    final invalid = (d['invalid'] as List?) ?? const [];
    final codesSent = asInt(d['codesSent']);
    final codesByEmail = asInt(d['codesByEmail']);
    final codesBySms = asInt(d['codesBySms']);
    final codesFailed = asInt(d['codesFailed']);
    final codesRemaining = asInt(d['codesRemaining']);

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          Icon(
            imported > 0 ? Icons.check_circle_rounded : Icons.info_rounded,
            color: imported > 0 ? const Color(0xFF22C55E) : AppTheme.accentColor,
          ),
          const SizedBox(width: 10),
          Text(imported > 0 ? 'Import complete' : 'Nothing imported'),
        ]),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                _resultRow('Students added', '$imported', const Color(0xFF22C55E)),
                if (duplicates > 0)
                  _resultRow('Already on your roster', '$duplicates', Colors.grey.shade600),
                if (overCapacity > 0)
                  _resultRow('Skipped — over capacity', '$overCapacity', AppTheme.errorColor),
                if (invalidCount > 0)
                  _resultRow('Skipped — invalid data', '$invalidCount', AppTheme.accentColor),
                if (codesSent > 0 || codesFailed > 0) ...[
                  const Divider(height: 24),
                  Text('Activation codes',
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12.5,
                          color: Colors.grey.shade800)),
                  const SizedBox(height: 6),
                  _resultRow('Sent to guardians', '$codesSent', const Color(0xFF22C55E)),
                  if (codesSent > 0)
                    Padding(
                      padding: const EdgeInsets.only(left: 18, bottom: 4),
                      child: Text('$codesByEmail by email · $codesBySms by SMS',
                          style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
                    ),
                  if (codesFailed > 0)
                    _resultRow('Could not be delivered', '$codesFailed', AppTheme.errorColor),
                  if (codesRemaining > 0)
                    _resultRow('Queued for the next run', '$codesRemaining',
                        AppTheme.accentColor),
                  const SizedBox(height: 6),
                  Text(
                    'Guardians with no email and no mobile number were skipped — add a '
                    'contact from the roster and use "Send codes".',
                    style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600, height: 1.45),
                  ),
                ],
                if (remaining != null) ...[
                  const Divider(height: 24),
                  Text(
                    '$remaining ${remaining == 1 ? "slot" : "slots"} left on your plan.',
                    style: TextStyle(fontSize: 13, color: Colors.grey.shade700),
                  ),
                ],
                if (overCapacity > 0) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.errorColor.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      'Your subscription is full. Upgrade your plan to add the remaining '
                      '$overCapacity ${overCapacity == 1 ? "student" : "students"} — '
                      're-uploading the same file afterwards will only add the new ones.',
                      style: const TextStyle(fontSize: 12, height: 1.5),
                    ),
                  ),
                ],
                if (invalid.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text('Rows that need fixing:',
                      style: TextStyle(fontWeight: FontWeight.w600, fontSize: 12.5, color: Colors.grey.shade800)),
                  const SizedBox(height: 6),
                  ...invalid.take(10).map((e) {
                    final m = Map<String, dynamic>.from(e as Map);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('• Line ${m['row']}: ${m['reason']}',
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                    );
                  }),
                  if (invalid.length > 10)
                    Text('…and ${invalid.length - 10} more',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                ],
              ],
            ),
          ),
        ),
        actions: [
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.effectivePrimary),
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  Widget _resultRow(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(children: [
        Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 10),
        Expanded(child: Text(label, style: const TextStyle(fontSize: 13.5))),
        Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: color)),
      ]),
    );
  }

  void _showFormatHelp() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('CSV format'),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'The first line must be a header row. Column order does not matter, '
                  'and extra columns are ignored.',
                  style: TextStyle(fontSize: 13, height: 1.5),
                ),
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF9FAFB),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: SelectableText(
                    rosterCsvExample,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.7),
                  ),
                ),
                const SizedBox(height: 14),
                const Text(
                  'Each student needs a name, plus a student number or an email so the '
                  'record can be matched when they register.\n\n'
                  'Students already on your roster are skipped on re-upload, so you can '
                  'safely upload the same file again after upgrading your plan.',
                  style: TextStyle(fontSize: 12.5, height: 1.55),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  void _showMessageDialog(String title, String body, {bool isError = false}) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          Icon(isError ? Icons.error_outline_rounded : Icons.info_outline_rounded,
              color: isError ? AppTheme.errorColor : AppTheme.effectivePrimary),
          const SizedBox(width: 10),
          Expanded(child: Text(title)),
        ]),
        content: SizedBox(width: 420, child: SingleChildScrollView(child: Text(body))),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
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
    if (_loadingSchool) {
      return Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary));
    }
    if (_schoolId == null) return _noSchoolState();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _capacityHeader(),
        const SizedBox(height: 16),
        _toolbar(),
        const SizedBox(height: 16),
        Expanded(child: _rosterList()),
      ],
    );
  }

  Widget _noSchoolState() {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 460),
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.school_outlined, size: 48, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          const Text('No school linked to this account',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 10),
          Text(
            'Student registration is scoped per school. This admin account was created '
            'before schools existed, so it has no roster yet.\n\n'
            'Subscribe from the website to create a school, or ask the platform owner to '
            'attach a schoolId to your account.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade600, height: 1.6),
          ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: _loadSchool,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Check again'),
          ),
        ]),
      ),
    );
  }

  Widget _capacityHeader() {
    final stream = SchoolContext.schoolStream(_schoolId);
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: stream,
      builder: (context, snap) {
        final data = snap.data?.data() ?? const <String, dynamic>{};
        final name = (data['name'] ?? 'Your school').toString();
        final tierLabel = (data['tierLabel'] ?? '—').toString();
        final capacity = (data['capacity'] as num?)?.toInt() ?? 0;
        final used = (data['studentCount'] as num?)?.toInt() ?? 0;
        final unlimited = capacity == 0;
        final ratio = unlimited || capacity == 0 ? 0.0 : (used / capacity).clamp(0.0, 1.0);
        final nearFull = !unlimited && ratio >= 0.9;

        return Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppTheme.effectivePrimary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.school_rounded, color: AppTheme.effectivePrimary, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(name,
                      style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold, color: Color(0xFF1F2937))),
                  const SizedBox(height: 2),
                  Text('$tierLabel plan', style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600)),
                ]),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(
                  unlimited ? '$used' : '$used / $capacity',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: nearFull ? AppTheme.errorColor : AppTheme.effectivePrimary,
                  ),
                ),
                Text(unlimited ? 'students (custom plan)' : 'students registered',
                    style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500)),
              ]),
            ]),
            if (!unlimited) ...[
              const SizedBox(height: 16),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: ratio,
                  minHeight: 8,
                  backgroundColor: const Color(0xFFE5E7EB),
                  valueColor: AlwaysStoppedAnimation(
                    nearFull ? AppTheme.errorColor : AppTheme.effectivePrimary,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                used >= capacity
                    ? 'Your plan is full — upgrade to register more students.'
                    : '${capacity - used} ${capacity - used == 1 ? "slot" : "slots"} remaining',
                style: TextStyle(
                  fontSize: 12,
                  color: used >= capacity ? AppTheme.errorColor : Colors.grey.shade600,
                  fontWeight: used >= capacity ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ]),
        );
      },
    );
  }

  Widget _toolbar() {
    return Row(children: [
      Expanded(
        child: SizedBox(
          height: 42,
          child: TextField(
            controller: _searchCtrl,
            onChanged: (v) => setState(() => _search = v.toLowerCase().trim()),
            decoration: InputDecoration(
              hintText: 'Search by name, student number or email…',
              prefixIcon: const Icon(Icons.search_rounded, size: 20),
              isDense: true,
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: Color(0xFFE5E7EB)),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(width: 10),
      _filterDropdown(),
      const SizedBox(width: 10),
      IconButton(
        onPressed: _showFormatHelp,
        icon: const Icon(Icons.help_outline_rounded),
        tooltip: 'CSV format',
        color: Colors.grey.shade600,
      ),
      const SizedBox(width: 4),
      OutlinedButton.icon(
        onPressed: _busy ? null : _addManually,
        icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
        label: const Text('Add student'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 42),
          foregroundColor: AppTheme.effectivePrimary,
          side: BorderSide(color: AppTheme.effectivePrimary),
        ),
      ),
      const SizedBox(width: 10),
      _sendCodesButton(),
      OutlinedButton.icon(
        onPressed: _downloadTemplate,
        icon: const Icon(Icons.download_rounded, size: 18),
        label: const Text('Template'),
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 42),
          foregroundColor: Colors.grey.shade700,
          side: BorderSide(color: Colors.grey.shade300),
        ),
      ),
      const SizedBox(width: 10),
      FilledButton.icon(
        onPressed: _busy ? null : _openImportWizard,
        icon: _busy
            ? const SizedBox(
                width: 16, height: 16,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Icon(Icons.upload_file_rounded, size: 18),
        label: Text(_busy ? 'Working…' : 'Import CSV'),
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 42),
          backgroundColor: AppTheme.effectivePrimary,
        ),
      ),
    ]);
  }

  Widget _filterDropdown() {
    return Container(
      height: 42,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _filter == RosterFilter.all
              ? const Color(0xFFE5E7EB)
              : AppTheme.effectivePrimary,
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<RosterFilter>(
          value: _filter,
          isDense: true,
          icon: Icon(Icons.filter_list_rounded,
              size: 18,
              color: _filter == RosterFilter.all
                  ? Colors.grey.shade600
                  : AppTheme.effectivePrimary),
          style: TextStyle(
            fontSize: 13,
            color: _filter == RosterFilter.all ? Colors.grey.shade800 : AppTheme.effectivePrimary,
            fontWeight: _filter == RosterFilter.all ? FontWeight.normal : FontWeight.w600,
          ),
          items: [
            for (final f in RosterFilter.values)
              DropdownMenuItem(value: f, child: Text(f.label)),
          ],
          onChanged: (v) => setState(() => _filter = v ?? RosterFilter.all),
        ),
      ),
    );
  }

  /// Offers the exact file the importer expects, headers and all.
  ///
  /// Schools build their roster in Excel; handing them a starting file removes
  /// the guesswork about column names and the date format in one step.
  void _downloadTemplate() {
    final saved = downloadTextFile('fieldtrip360_student_template.csv', rosterCsvTemplateFile);
    if (saved) {
      _toast('Template downloaded — open it in Excel and replace the sample rows.');
      return;
    }
    // Mobile has no download tray; show the text so it can still be copied out.
    _showMessageDialog('CSV template', rosterCsvTemplateFile);
  }

  /// Appears only when guardians can actually be contacted — a permanently
  /// visible button invites clicking with nothing to send.
  Widget _sendCodesButton() {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: GuardianService.ofSchool(_schoolId!),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
        final contactable = docs.where((d) {
          final g = d.data();
          return g['status'] == GuardianService.statusActivationReady && g['parentUid'] == null;
        }).toList();
        if (contactable.isEmpty) return const SizedBox.shrink();

        final waiting = contactable.where((d) => GuardianService.isAwaitingCode(d.data())).length;

        return Padding(
          padding: const EdgeInsets.only(right: 10),
          child: OutlinedButton.icon(
            onPressed: _busy ? null : () => _openSendCodesPicker(contactable),
            icon: const Icon(Icons.forward_to_inbox_rounded, size: 18),
            label: Text(waiting > 0 ? 'Send codes ($waiting)' : 'Send codes'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(0, 42),
              foregroundColor: AppTheme.accentColor,
              side: BorderSide(color: AppTheme.accentColor),
            ),
          ),
        );
      },
    );
  }

  /// Lets the admin choose exactly who gets a code.
  ///
  /// Sending is not free — SMS costs a credit each and a resend invalidates a
  /// code the parent may already be holding — so the recipients are picked
  /// rather than implied. Guardians still waiting start ticked, which keeps the
  /// common case a single click.
  Future<void> _openSendCodesPicker(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> contactable,
  ) async {
    final selected = <String>{
      for (final d in contactable)
        if (GuardianService.isAwaitingCode(d.data())) d.id,
    };
    var query = '';

    final ids = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setLocal) {
        final visible = query.isEmpty
            ? contactable
            : contactable.where((d) {
                final g = d.data();
                return [g['name'], g['studentName'], g['email'], g['phone']]
                    .any((v) => (v ?? '').toString().toLowerCase().contains(query));
              }).toList();

        final visibleIds = visible.map((d) => d.id).toSet();
        final allVisibleChecked =
            visibleIds.isNotEmpty && visibleIds.every(selected.contains);

        return AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text('Send activation codes'),
          content: SizedBox(
            width: 560,
            height: 460,
            child: Column(children: [
              Text(
                'Each guardian is sent one code — by email when there is an address '
                'on file, otherwise by SMS. A code sent to the wrong person cannot '
                'be recalled, so check the list before sending.',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600, height: 1.5),
              ),
              const SizedBox(height: 12),
              TextField(
                autofocus: true,
                onChanged: (v) => setLocal(() => query = v.toLowerCase().trim()),
                decoration: InputDecoration(
                  hintText: 'Search guardian, student, email or number…',
                  prefixIcon: const Icon(Icons.search_rounded, size: 20),
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
              const SizedBox(height: 8),
              Row(children: [
                Checkbox(
                  value: allVisibleChecked,
                  tristate: false,
                  activeColor: AppTheme.effectivePrimary,
                  onChanged: (v) => setLocal(() {
                    // Scoped to what is on screen: with a search active,
                    // "select all" that silently ticked hidden rows would send
                    // codes the admin never saw.
                    if (v == true) {
                      selected.addAll(visibleIds);
                    } else {
                      selected.removeAll(visibleIds);
                    }
                  }),
                ),
                Text(
                  query.isEmpty ? 'Select all' : 'Select all ${visible.length} matching',
                  style: const TextStyle(fontSize: 13),
                ),
                const Spacer(),
                Text('${selected.length} selected',
                    style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: AppTheme.effectivePrimary)),
              ]),
              const Divider(height: 1),
              Expanded(
                child: visible.isEmpty
                    ? Center(
                        child: Text('No guardians match "$query".',
                            style: TextStyle(fontSize: 12.5, color: Colors.grey.shade500)),
                      )
                    : ListView.builder(
                        itemCount: visible.length,
                        itemBuilder: (_, i) {
                          final d = visible[i];
                          final g = d.data();
                          final already = g['activationStatus'] == 'sent';
                          final email = (g['email'] ?? '').toString();
                          final phone = (g['phone'] ?? '').toString();
                          final via = email.isNotEmpty ? email : phone;
                          return CheckboxListTile(
                            value: selected.contains(d.id),
                            onChanged: (v) => setLocal(() {
                              if (v == true) {
                                selected.add(d.id);
                              } else {
                                selected.remove(d.id);
                              }
                            }),
                            dense: true,
                            activeColor: AppTheme.effectivePrimary,
                            controlAffinity: ListTileControlAffinity.leading,
                            title: Text('${g['name']} — ${g['studentName'] ?? 'Student'}',
                                style: const TextStyle(fontSize: 13)),
                            subtitle: Row(children: [
                              Icon(email.isNotEmpty ? Icons.email_outlined : Icons.sms_outlined,
                                  size: 12, color: Colors.grey.shade500),
                              const SizedBox(width: 5),
                              Expanded(
                                child: Text(via,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
                              ),
                              if (already)
                                Container(
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: AppTheme.accentColor.withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Text('Already sent — will resend',
                                      style: TextStyle(
                                          fontSize: 9.5,
                                          fontWeight: FontWeight.w600,
                                          color: AppTheme.accentColor)),
                                ),
                            ]),
                          );
                        },
                      ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.effectivePrimary),
              onPressed: selected.isEmpty
                  ? null
                  : () => Navigator.pop(ctx, selected.toList()),
              child: Text(selected.isEmpty
                  ? 'Send codes'
                  : 'Send ${selected.length} ${selected.length == 1 ? "code" : "codes"}'),
            ),
          ],
        );
      }),
    );

    if (ids == null || ids.isEmpty) return;
    await _sendCodesTo(ids);
  }

  Future<void> _sendCodesTo(List<String> guardianIds) async {
    setState(() => _busy = true);
    try {
      final r = await GuardianService.sendAllPendingCodes(guardianIds: guardianIds);
      if (!mounted) return;
      int n(Object? v) => (v as num?)?.toInt() ?? 0;
      final sent = n(r['sent']);
      final byEmail = n(r['byEmail']);
      final bySms = n(r['bySms']);
      final failed = n(r['failed']);
      final remaining = n(r['remaining']);
      final failures = (r['failures'] as List?) ?? const [];

      _showMessageDialog(
        sent > 0 ? 'Codes sent' : 'Nothing was sent',
        [
          '$sent ${sent == 1 ? "code was" : "codes were"} sent.',
          if (byEmail > 0 || bySms > 0)
            '  $byEmail by email, $bySms by SMS.',
          if (failed > 0) '$failed could not be sent.',
          if (remaining > 0)
            '\n$remaining were not attempted — sending is capped per run so the '
                'mail account stays within its daily limit. Run this again to continue.',
          if (failures.isNotEmpty) ...[
            '\nCould not send to:',
            ...failures.take(10).map((f) {
              final m = Map<String, dynamic>.from(f as Map);
              return '• ${m['name']} — ${m['reason']}';
            }),
          ],
        ].join('\n'),
        isError: sent == 0 && failed > 0,
      );
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        _showMessageDialog('Could not send codes', e.message ?? 'Please try again.',
            isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _rosterList() {
    return Container(
      decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16)),
      clipBehavior: Clip.antiAlias,
      // One listener for every guardian in the school, grouped in memory.
      //
      // This used to be a StreamBuilder inside each roster row, which opened a
      // separate Firestore listener per student. Importing a few hundred
      // students opened a few hundred listeners at once and the whole console
      // stopped responding until the page was reloaded.
      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: GuardianService.ofSchool(_schoolId!),
        builder: (context, gSnap) {
          final byStudent = <String, List<QueryDocumentSnapshot<Map<String, dynamic>>>>{};
          for (final g in gSnap.data?.docs ?? const []) {
            final sid = (g.data()['studentId'] ?? '').toString();
            if (sid.isNotEmpty) (byStudent[sid] ??= []).add(g);
          }
          return _rosterTable(byStudent, guardiansLoaded: gSnap.hasData);
        },
      ),
    );
  }

  Widget _rosterTable(
    Map<String, List<QueryDocumentSnapshot<Map<String, dynamic>>>> byStudent, {
    required bool guardiansLoaded,
  }) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('roster')
          .where('schoolId', isEqualTo: _schoolId)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('Could not load the roster.\n${snap.error}',
                  textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade600)),
            ),
          );
        }
        if (!snap.hasData) {
          return Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary));
        }

        final docs = snap.data!.docs.toList()
          ..sort((a, b) => (a.data()['name'] ?? '')
              .toString()
              .toLowerCase()
              .compareTo((b.data()['name'] ?? '').toString().toLowerCase()));

        final filtered = docs.where((d) {
          final m = d.data();
          final guardians = byStudent[d.id] ?? const [];

          if (_search.isNotEmpty) {
            final haystack = <Object?>[
              m['name'], m['studentNumber'], m['email'], m['section'], m['parentEmail'],
              for (final g in guardians) ...[g.data()['name'], g.data()['email'], g.data()['phone']],
            ];
            if (!haystack.any((v) => (v ?? '').toString().toLowerCase().contains(_search))) {
              return false;
            }
          }

          // While guardians are still loading every student would look like it
          // has none, so the stage filter waits rather than showing a wrong list.
          if (_filter != RosterFilter.all) {
            if (!guardiansLoaded) return false;
            if (_stageOf(guardians.map((g) => g.data()).toList()) != _filter) return false;
          }
          return true;
        }).toList();

        if (docs.isEmpty) return _emptyRoster();
        if (filtered.isEmpty) return _noMatchState();

        return Column(children: [
          _tableHeader(filtered.length, docs.length),
          const Divider(height: 1),
          Expanded(
            child: ListView.separated(
              itemCount: filtered.length,
              separatorBuilder: (_, __) => const Divider(height: 1),
              itemBuilder: (context, i) => _rosterRow(
                filtered[i],
                byStudent[filtered[i].id] ?? const [],
                guardiansLoaded: guardiansLoaded,
              ),
            ),
          ),
        ]);
      },
    );
  }

  Widget _noMatchState() {
    final what = [
      if (_search.isNotEmpty) '"$_search"',
      if (_filter != RosterFilter.all) '"${_filter.label}"',
    ].join(' and ');
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.filter_alt_off_rounded, size: 40, color: Colors.grey.shade300),
          const SizedBox(height: 12),
          Text('No students match $what.',
              textAlign: TextAlign.center, style: TextStyle(color: Colors.grey.shade500)),
          if (_filter != RosterFilter.all) ...[
            const SizedBox(height: 10),
            TextButton(
              onPressed: () => setState(() => _filter = RosterFilter.all),
              child: const Text('Clear filter'),
            ),
          ],
        ]),
      ),
    );
  }

  Widget _tableHeader(int shown, int total) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      color: const Color(0xFFFAFAFA),
      child: Row(children: [
        Text(
          _search.isEmpty ? '$total students' : '$shown of $total students',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13.5, color: Color(0xFF1F2937)),
        ),
        const Spacer(),
        Text('Registered = the student has created their account',
            style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500)),
      ]),
    );
  }

  Widget _emptyRoster() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.groups_outlined, size: 52, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          const Text('No students yet', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            'Import a CSV to register your students in bulk, or add them one at a time.\n'
            'Only students on this roster can be assigned to your field trips.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: Colors.grey.shade600, height: 1.6),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _busy ? null : _openImportWizard,
            icon: const Icon(Icons.upload_file_rounded, size: 18),
            label: const Text('Import CSV'),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.effectivePrimary),
          ),
        ]),
      ),
    );
  }

  Widget _rosterRow(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> guardians, {
    required bool guardiansLoaded,
  }) {
    final m = doc.data();
    final name = (m['name'] ?? 'Unknown').toString();
    final number = (m['studentNumber'] ?? '').toString();
    final email = (m['email'] ?? '').toString();
    final grade = (m['gradeLevel'] ?? '').toString();
    final section = (m['section'] ?? '').toString();
    final parentEmail = (m['parentEmail'] ?? '').toString();
    final claimed = m['status'] == 'claimed';
    final gradeSection = [grade, section].where((s) => s.isNotEmpty).join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Column(children: [
        Row(children: [
        CircleAvatar(
          radius: 18,
          backgroundColor: AppTheme.effectivePrimary.withValues(alpha: 0.12),
          child: Text(
            name.isNotEmpty ? name[0].toUpperCase() : '?',
            style: TextStyle(color: AppTheme.effectivePrimary, fontWeight: FontWeight.bold, fontSize: 14),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          flex: 3,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(name, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
            if (number.isNotEmpty || gradeSection.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  [if (number.isNotEmpty) number, if (gradeSection.isNotEmpty) gradeSection].join(' • '),
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ),
          ]),
        ),
        Expanded(
          flex: 3,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (email.isNotEmpty)
              Text(email,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700)),
            if (parentEmail.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text('Parent: $parentEmail',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500)),
              ),
          ]),
        ),
        const SizedBox(width: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: claimed
                ? const Color(0xFF22C55E).withValues(alpha: 0.12)
                : Colors.grey.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            claimed ? 'Registered' : 'Pending',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: claimed ? const Color(0xFF16A34A) : Colors.grey.shade600,
            ),
          ),
        ),
        // Recovery path when the automatic claim at registration never landed.
        if (!claimed && email.isNotEmpty)
          IconButton(
            onPressed: _busy ? null : () => _linkAccount(doc.id, name, email),
            icon: const Icon(Icons.link_rounded, size: 20),
            color: AppTheme.effectivePrimary,
            tooltip: 'Link to an account already registered with $email',
          ),
        IconButton(
          onPressed: _busy ? null : () => _remove(doc.id, name),
          icon: const Icon(Icons.delete_outline_rounded, size: 20),
          color: Colors.grey.shade400,
          tooltip: 'Remove from roster',
        ),
        ]),
        _guardianPanel(doc.id, name, guardians, guardiansLoaded: guardiansLoaded),
      ]),
    );
  }

  /// Guardian state and the actions available for it.
  ///
  /// The guardian record is deliberately separate from the parent's login: it
  /// exists as soon as the school provides a name, long before (or without) an
  /// account. Only staff can create or change it.
  Widget _guardianPanel(
    String rosterId,
    String studentName,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> guardians, {
    required bool guardiansLoaded,
  }) {
    if (!guardiansLoaded) {
      return Padding(
        padding: const EdgeInsets.only(top: 8, left: 46),
        child: Row(children: [
          SizedBox(
            width: 11,
            height: 11,
            child: CircularProgressIndicator(strokeWidth: 1.6, color: Colors.grey.shade300),
          ),
          const SizedBox(width: 8),
          Text('Loading guardians…',
              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade400)),
        ]),
      );
    }

    if (guardians.isEmpty) {
      return Padding(
        padding: const EdgeInsets.only(top: 8, left: 46),
        child: Row(children: [
          Icon(Icons.person_off_outlined, size: 14, color: Colors.grey.shade400),
          const SizedBox(width: 7),
          Text('No guardian assigned',
              style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500)),
          const SizedBox(width: 10),
          TextButton.icon(
            onPressed: _busy ? null : () => _assignGuardian(rosterId, studentName),
            icon: const Icon(Icons.person_add_alt_rounded, size: 14),
            label: const Text('Assign guardian', style: TextStyle(fontSize: 11.5)),
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 28),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              foregroundColor: AppTheme.effectivePrimary,
            ),
          ),
        ]),
      );
    }

    // Sorted so a linked parent is always the first line of the student's row —
    // that is the state an admin scans for.
    final sorted = guardians.toList()
      ..sort((a, b) {
        final al = GuardianService.isLinked(a.data()) ? 0 : 1;
        final bl = GuardianService.isLinked(b.data()) ? 0 : 1;
        return al.compareTo(bl);
      });

    return Column(children: [
      for (final g in sorted) _guardianRow(rosterId, studentName, g),
      if (sorted.length < GuardianService.maxPerStudent)
        Padding(
          padding: const EdgeInsets.only(top: 4, left: 40),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _busy ? null : () => _assignGuardian(rosterId, studentName),
              icon: const Icon(Icons.add_rounded, size: 14),
              label: Text(
                'Add second guardian',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 26),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                foregroundColor: Colors.grey.shade500,
              ),
            ),
          ),
        ),
    ]);
  }

  Widget _guardianRow(
    String rosterId,
    String studentName,
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) {
    final g = doc.data();
    final status = (g['status'] ?? '').toString();
    final email = (g['email'] ?? '').toString();
    final phone = (g['phone'] ?? '').toString();
    final activated = status == GuardianService.statusActivated;
    final canSend = status == GuardianService.statusActivationReady;
    final noContact = GuardianService.hasNoContact(g);
    final pending = GuardianService.isPending(g);

    final color = activated
        ? const Color(0xFF16A34A)
        : noContact
            ? AppTheme.errorColor
            : (pending ? AppTheme.accentColor : AppTheme.effectivePrimary);

    // Whichever channel the code would actually travel on, so the admin can see
    // at a glance why a guardian is reachable.
    final contact = [
      if (email.isNotEmpty) email,
      if (phone.isNotEmpty) phone,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.only(top: 8, left: 46),
      child: Row(children: [
        Icon(activated ? Icons.verified_user_rounded : Icons.person_outline_rounded,
            size: 14, color: color),
        const SizedBox(width: 7),
        Expanded(
          child: Text(
            '${g['name']} · ${g['relationship'] ?? 'Guardian'}'
            '${contact.isEmpty ? '' : ' · $contact'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              color: Colors.grey.shade700,
              fontWeight: activated ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(GuardianService.statusLabel(g),
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
        ),
        if (!activated) ...[
          IconButton(
            onPressed: _busy ? null : () => _assignGuardian(rosterId, studentName, existing: doc),
            icon: const Icon(Icons.edit_outlined, size: 16),
            color: Colors.grey.shade500,
            visualDensity: VisualDensity.compact,
            tooltip: 'Edit guardian',
          ),
          if (canSend)
            IconButton(
              onPressed: _busy ? null : () => _guardianAction(doc.id, 'send'),
              icon: const Icon(Icons.mark_email_read_outlined, size: 16),
              color: AppTheme.effectivePrimary,
              visualDensity: VisualDensity.compact,
              tooltip: g['activationStatus'] == 'sent'
                  ? 'Resend activation code'
                  : 'Send activation code',
            ),
          if (g['activationStatus'] == 'sent')
            IconButton(
              onPressed: _busy ? null : () => _guardianAction(doc.id, 'revoke'),
              icon: const Icon(Icons.block_rounded, size: 16),
              color: AppTheme.errorColor,
              visualDensity: VisualDensity.compact,
              tooltip: 'Revoke activation code',
            ),
        ],
        IconButton(
          onPressed: _busy ? null : () => _guardianAction(doc.id, 'remove'),
          icon: const Icon(Icons.close_rounded, size: 16),
          color: Colors.grey.shade400,
          visualDensity: VisualDensity.compact,
          tooltip: 'Remove guardian',
        ),
      ]),
    );
  }

  Future<void> _guardianAction(String guardianId, String action) async {
    setState(() => _busy = true);
    try {
      switch (action) {
        case 'send':
          await GuardianService.sendActivationCode(guardianId);
          if (mounted) _toast('Activation code emailed to the guardian.');
        case 'revoke':
          await GuardianService.revokeActivationCode(guardianId);
          if (mounted) _toast('Activation code revoked.');
        case 'remove':
          await GuardianService.remove(guardianId);
          if (mounted) _toast('Guardian removed.');
      }
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        _showMessageDialog('Could not complete that', e.message ?? 'Please try again.',
            isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Creates or edits a guardian by hand — the path for CSVs with no parent data.
  Future<void> _assignGuardian(
    String rosterId,
    String studentName, {
    QueryDocumentSnapshot<Map<String, dynamic>>? existing,
  }) async {
    final prev = existing?.data();
    final formKey = GlobalKey<FormState>();
    final name = TextEditingController(text: (prev?['name'] ?? '').toString());
    final email = TextEditingController(text: (prev?['email'] ?? '').toString());
    final phone = TextEditingController(text: (prev?['phone'] ?? '').toString());
    var relationship = (prev?['relationship'] ?? 'Guardian').toString();
    var sendCode = true;

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: Text(existing == null ? 'Assign guardian' : 'Edit guardian'),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Form(
                key: formKey,
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text('For $studentName',
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                  ),
                  const SizedBox(height: 12),
                  _dialogField(name, 'Guardian name', required: true),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: relationship,
                    decoration: InputDecoration(
                      labelText: 'Relationship',
                      isDense: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    items: [
                      for (final r in GuardianService.relationships)
                        DropdownMenuItem(value: r, child: Text(r)),
                    ],
                    onChanged: (v) => setLocal(() => relationship = v ?? relationship),
                  ),
                  const SizedBox(height: 10),
                  _dialogField(email, 'Guardian email', isEmail: true),
                  const SizedBox(height: 10),
                  _dialogField(phone, 'Contact number (optional)'),
                  const SizedBox(height: 6),
                  CheckboxListTile(
                    value: sendCode,
                    onChanged: (v) => setLocal(() => sendCode = v ?? true),
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    activeColor: AppTheme.effectivePrimary,
                    title: const Text('Email an activation code now',
                        style: TextStyle(fontSize: 12.5)),
                    subtitle: Text(
                      'Only possible once a valid email is on file. Without one the '
                      'guardian stays at "Pending Contact Information".',
                      style: TextStyle(fontSize: 10.5, color: Colors.grey.shade600, height: 1.4),
                    ),
                  ),
                ]),
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.effectivePrimary),
              onPressed: () {
                if (formKey.currentState?.validate() ?? false) Navigator.pop(ctx, true);
              },
              child: const Text('Save guardian'),
            ),
          ],
        ),
      ),
    );
    if (saved != true) return;

    setState(() => _busy = true);
    try {
      final res = await GuardianService.assign(
        studentId: rosterId,
        name: name.text.trim(),
        relationship: relationship,
        email: email.text.trim(),
        phone: phone.text.trim(),
        sendCode: sendCode,
      );
      if (!mounted) return;
      final delivered = res['delivery'] == 'email';
      _toast(delivered
          ? 'Guardian saved and activation code emailed.'
          : 'Guardian saved. Add an email to send an activation code.');
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        _showMessageDialog('Could not save guardian', e.message ?? 'Please try again.',
            isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
