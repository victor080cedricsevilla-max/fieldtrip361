import 'dart:convert';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../config/theme.dart';
import '../../utils/file_download.dart';
import '../../utils/roster_csv.dart';

/// Guided bulk student import: upload → map columns → validate → review → confirm.
///
/// Nothing is written until the final step, and the mapping is the admin's to
/// set — header auto-detection only pre-fills it, so any school's export works
/// without the file having to match a fixed layout.
class BulkImportView extends StatefulWidget {
  final String schoolId;

  /// Student IDs and emails already on the roster, for duplicate detection.
  final Set<String> existingStudentNumbers;
  final Set<String> existingEmails;

  const BulkImportView({
    super.key,
    required this.schoolId,
    this.existingStudentNumbers = const {},
    this.existingEmails = const {},
  });

  @override
  State<BulkImportView> createState() => _BulkImportViewState();
}

class _BulkImportViewState extends State<BulkImportView> {
  int _step = 0;
  bool _busy = false;

  String? _fileName;
  CsvTable? _table;
  Map<String, int?> _mapping = {};
  DateOrder _dateOrder = DateOrder.monthFirst;
  ValidationReport? _report;
  String? _error;

  // ── Step 1: upload ────────────────────────────────────────────────────────

  Future<void> _pickFile() async {
    FilePickerResult? picked;
    try {
      picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['csv'],
        withData: true,
      );
    } catch (_) {
      picked = await FilePicker.platform.pickFiles(withData: true);
    }
    if (picked == null || picked.files.isEmpty) return;

    final bytes = picked.files.first.bytes;
    if (bytes == null) {
      setState(() => _error = 'That file could not be read.');
      return;
    }

    try {
      final table = readCsvTable(utf8.decode(bytes, allowMalformed: true));
      setState(() {
        _fileName = picked!.files.first.name;
        _table = table;
        // A suggestion, not a decision — the admin confirms it on the next step.
        _mapping = suggestMapping(table.headers);
        _report = null;
        _error = null;
        _step = 1;
      });
    } on CsvFormatException catch (e) {
      setState(() => _error = e.message);
    } catch (_) {
      setState(() => _error = 'That file could not be parsed as CSV.');
    }
  }

  // ── Step 3: validate ──────────────────────────────────────────────────────

  void _validate() {
    final table = _table;
    if (table == null) return;
    setState(() {
      _report = validateMappedRows(
        table,
        _mapping,
        existingStudentNumbers: widget.existingStudentNumbers,
        existingEmails: widget.existingEmails,
        dateOrder: _dateOrder,
      );
      _step = 3;
    });
  }

  // ── Step 5: commit ────────────────────────────────────────────────────────

  Future<void> _import() async {
    final report = _report;
    if (report == null || report.validRows.isEmpty) return;

    setState(() => _busy = true);
    try {
      final res = await FirebaseFunctions.instance
          .httpsCallable('importRoster')
          .call(<String, dynamic>{'rows': report.validRows, 'source': 'csv'});
      if (!mounted) return;
      Navigator.pop(context, Map<String, dynamic>.from(res.data as Map));
    } on FirebaseFunctionsException catch (e) {
      if (mounted) setState(() => _error = e.message ?? 'The import failed.');
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  static const _stepTitles = [
    'Upload CSV',
    'Map Columns',
    'Date Format',
    'Review',
    'Confirm',
  ];

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 720),
        padding: const EdgeInsets.all(22),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Row(children: [
            Icon(Icons.upload_file_rounded, color: AppTheme.effectivePrimary),
            const SizedBox(width: 10),
            const Expanded(
              child: Text('Bulk Student Import',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            ),
            IconButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              icon: const Icon(Icons.close_rounded),
            ),
          ]),
          const SizedBox(height: 14),
          _stepper(),
          const SizedBox(height: 16),
          if (_error != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.errorColor.withValues(alpha: 0.07),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.errorColor.withValues(alpha: 0.25)),
              ),
              child: Text(_error!,
                  style: TextStyle(fontSize: 12.5, color: AppTheme.errorColor, height: 1.45)),
            ),
            const SizedBox(height: 14),
          ],
          Flexible(child: SingleChildScrollView(child: _stepBody())),
          const SizedBox(height: 18),
          _actions(),
        ]),
      ),
    );
  }

  Widget _stepper() {
    return Row(children: [
      for (var i = 0; i < _stepTitles.length; i++) ...[
        Container(
          width: 24,
          height: 24,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: i <= _step ? AppTheme.effectivePrimary : const Color(0xFFE5E7EB),
            shape: BoxShape.circle,
          ),
          child: i < _step
              ? const Icon(Icons.check_rounded, size: 14, color: Colors.white)
              : Text('${i + 1}',
                  style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: i <= _step ? Colors.white : Colors.grey.shade600)),
        ),
        const SizedBox(width: 6),
        Text(_stepTitles[i],
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: i == _step ? FontWeight.w700 : FontWeight.normal,
              color: i <= _step ? AppTheme.secondaryColor : Colors.grey.shade500,
            )),
        if (i < _stepTitles.length - 1)
          Expanded(
            child: Container(
              height: 1.5,
              margin: const EdgeInsets.symmetric(horizontal: 8),
              color: i < _step ? AppTheme.effectivePrimary : const Color(0xFFE5E7EB),
            ),
          ),
      ],
    ]);
  }

  Widget _stepBody() {
    switch (_step) {
      case 0:
        return _uploadStep();
      case 1:
        return _mappingStep();
      case 2:
        return _dateStep();
      case 3:
        return _reviewStep();
      default:
        return _confirmStep();
    }
  }

  // ── Step bodies ───────────────────────────────────────────────────────────

  Widget _uploadStep() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
        'Upload your school\'s student list. Any column layout works — you will '
        'match the columns to system fields on the next step.',
        style: TextStyle(fontSize: 13, color: Colors.grey.shade700, height: 1.5),
      ),
      const SizedBox(height: 16),
      InkWell(
        onTap: _pickFile,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 34),
          decoration: BoxDecoration(
            color: AppTheme.effectivePrimary.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: AppTheme.effectivePrimary.withValues(alpha: 0.35)),
          ),
          child: Column(children: [
            Icon(Icons.cloud_upload_outlined, size: 38, color: AppTheme.effectivePrimary),
            const SizedBox(height: 10),
            Text(_fileName ?? 'Choose a .csv file',
                style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('The first row must be the header',
                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500)),
          ]),
        ),
      ),
      const SizedBox(height: 16),
      Row(children: [
        Text('Example layout',
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey.shade700)),
        const Spacer(),
        // Offered before the upload rather than after a failure: the file is
        // easiest to fix while it is still being built.
        OutlinedButton.icon(
          onPressed: _downloadTemplate,
          icon: const Icon(Icons.download_rounded, size: 15),
          label: const Text('Download template', style: TextStyle(fontSize: 12)),
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(0, 32),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            foregroundColor: AppTheme.effectivePrimary,
            side: BorderSide(color: AppTheme.effectivePrimary.withValues(alpha: 0.5)),
          ),
        ),
      ]),
      const SizedBox(height: 6),
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: const Color(0xFFF9FAFB),
          border: Border.all(color: const Color(0xFFE5E7EB)),
          borderRadius: BorderRadius.circular(9),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SelectableText(rosterCsvExample,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 10.5, height: 1.7)),
        ),
      ),
      const SizedBox(height: 8),
      Text(
        'Only Student ID, first name, last name and date of birth are required. '
        'Everything else may be left blank, and extra columns are ignored.',
        style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600, height: 1.45),
      ),
    ]);
  }

  void _downloadTemplate() {
    final saved = downloadTextFile('fieldtrip360_student_template.csv', rosterCsvTemplateFile);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(saved
          ? 'Template downloaded — replace the two sample rows with your students.'
          : 'Downloads are only available on the web console.'),
      backgroundColor: AppTheme.secondaryColor,
      behavior: SnackBarBehavior.floating,
    ));
  }

  Widget _mappingStep() {
    final table = _table!;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
        'Tell us which column holds each field. We have pre-filled what we could '
        'recognise — change anything that looks wrong.',
        style: TextStyle(fontSize: 13, color: Colors.grey.shade700, height: 1.5),
      ),
      const SizedBox(height: 4),
      Text('${table.rowCount} data rows · ${table.headers.length} columns',
          style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500)),
      const SizedBox(height: 14),
      for (final field in RosterField.all) _mappingRow(field, table),
      const SizedBox(height: 6),
      Container(
        padding: const EdgeInsets.all(11),
        decoration: BoxDecoration(
          color: AppTheme.accentColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(9),
        ),
        child: Text(
          'Leave a field as “Not in my file” if your CSV does not have it. '
          'Parent details are always optional — students import fine without them.',
          style: TextStyle(fontSize: 11.5, color: Colors.orange.shade900, height: 1.45),
        ),
      ),
    ]);
  }

  Widget _mappingRow(RosterField field, CsvTable table) {
    // Full Name is an alternative to First/Last, not an extra requirement.
    final satisfiedByFullName =
        (field.key == 'firstName' || field.key == 'lastName') && _mapping['fullName'] != null;
    final missingRequired =
        field.isRequired && _mapping[field.key] == null && !satisfiedByFullName;

    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: Row(children: [
        SizedBox(
          width: 190,
          child: Row(children: [
            Expanded(
              child: Text(field.label,
                  style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
            ),
            if (field.isRequired)
              Text('required',
                  style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.w700,
                      color: missingRequired ? AppTheme.errorColor : Colors.grey.shade400)),
          ]),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: DropdownButtonFormField<int?>(
            initialValue: _mapping[field.key],
            isDense: true,
            decoration: InputDecoration(
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(9)),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(9),
                borderSide: BorderSide(
                    color: missingRequired ? AppTheme.errorColor : const Color(0xFFE5E7EB)),
              ),
            ),
            items: [
              const DropdownMenuItem<int?>(
                value: null,
                child: Text('Not in my file',
                    style: TextStyle(fontSize: 12.5, fontStyle: FontStyle.italic)),
              ),
              for (var i = 0; i < table.headers.length; i++)
                DropdownMenuItem<int?>(
                  value: i,
                  child: Text(
                    table.headers[i].isEmpty ? 'Column ${i + 1}' : table.headers[i],
                    style: const TextStyle(fontSize: 12.5),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) => setState(() {
              // Each column may only feed one field, so steal it from any other.
              if (v != null) {
                for (final k in _mapping.keys.toList()) {
                  if (k != field.key && _mapping[k] == v) _mapping[k] = null;
                }
              }
              _mapping[field.key] = v;
            }),
          ),
        ),
        const SizedBox(width: 10),
        SizedBox(
          width: 120,
          child: Text(
            table.rowCount == 0 ? '' : table.cell(0, _mapping[field.key]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
          ),
        ),
      ]),
    );
  }

  Widget _dateStep() {
    final sample = _table!.rowCount == 0 ? '' : _table!.cell(0, _mapping['dateOfBirth']);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(
        'How should we read dates written with slashes? 2010-05-14 and '
        '"May 14, 2010" are understood automatically — this only affects '
        'ambiguous values like 05/06/2010.',
        style: TextStyle(fontSize: 13, color: Colors.grey.shade700, height: 1.5),
      ),
      if (sample.isNotEmpty) ...[
        const SizedBox(height: 12),
        Text('First date in your file: "$sample"',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
      ],
      const SizedBox(height: 14),
      for (final order in DateOrder.values) _dateOrderOption(order, sample),
    ]);
  }

  Widget _dateOrderOption(DateOrder order, String sample) {
    final selected = _dateOrder == order;
    final reading = sample.isEmpty ? null : normalizeDate(sample, order: order);

    return Padding(
      padding: const EdgeInsets.only(bottom: 9),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => setState(() => _dateOrder = order),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.effectivePrimary.withValues(alpha: 0.06)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? AppTheme.effectivePrimary.withValues(alpha: 0.4)
                  : const Color(0xFFE5E7EB),
            ),
          ),
          child: Row(children: [
            Icon(
              selected ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
              size: 19,
              color: selected ? AppTheme.effectivePrimary : Colors.grey.shade400,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  order == DateOrder.monthFirst
                      ? 'Month first — 05/06/2010 is 6 May 2010'
                      : 'Day first — 05/06/2010 is 5 June 2010',
                  style: const TextStyle(fontSize: 13),
                ),
                if (sample.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      reading == null
                          ? 'Cannot read "$sample" this way'
                          : 'Your sample reads as $reading',
                      style: TextStyle(
                        fontSize: 11,
                        color: reading == null
                            ? AppTheme.errorColor
                            : Colors.grey.shade500,
                      ),
                    ),
                  ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _reviewStep() {
    final r = _report!;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Import Summary',
          style: TextStyle(
              fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.secondaryColor)),
      const SizedBox(height: 10),
      _summaryRow('Total rows in file', '${r.totalRows}', Colors.grey.shade600),
      _summaryRow('Valid students', '${r.validCount}', const Color(0xFF16A34A)),
      if (r.rejectedCount > 0)
        _summaryRow('Rejected rows', '${r.rejectedCount}', AppTheme.errorColor),
      if (r.emptyRows > 0)
        _summaryRow('Empty rows skipped', '${r.emptyRows}', Colors.grey.shade500),
      const SizedBox(height: 14),
      Text('Guardian Information',
          style: TextStyle(
              fontSize: 14, fontWeight: FontWeight.bold, color: AppTheme.secondaryColor)),
      const SizedBox(height: 10),
      _summaryRow('Complete — activation code can be sent', '${r.guardianComplete}',
          const Color(0xFF16A34A)),
      _summaryRow('Partial — needs contact information', '${r.guardianPartial}',
          AppTheme.accentColor),
      _summaryRow('Not provided', '${r.guardianNone}', Colors.grey.shade500),
      if (r.issues.isNotEmpty) ...[
        const Divider(height: 26),
        Text('Issues found',
            style: TextStyle(
                fontSize: 13, fontWeight: FontWeight.bold, color: AppTheme.secondaryColor)),
        const SizedBox(height: 4),
        Text(
          'Rows with a blocking issue are not imported. Fix them in your file and '
          'upload again — nothing is discarded silently.',
          style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600, height: 1.45),
        ),
        const SizedBox(height: 10),
        for (final entry in r.issueBreakdown.entries)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text('• ${entry.value}× ${entry.key}',
                style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700, height: 1.4)),
          ),
        const SizedBox(height: 10),
        Container(
          constraints: const BoxConstraints(maxHeight: 150),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFFF9FAFB),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: const Color(0xFFE5E7EB)),
          ),
          child: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              for (final i in r.issues.take(60))
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Text(
                    'Line ${i.row}: ${i.message}${i.blocking ? "" : "  (warning only)"}',
                    style: TextStyle(
                      fontSize: 11,
                      color: i.blocking ? AppTheme.errorColor : Colors.orange.shade900,
                    ),
                  ),
                ),
              if (r.issues.length > 60)
                Text('…and ${r.issues.length - 60} more',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            ]),
          ),
        ),
      ],
    ]);
  }

  Widget _summaryRow(String label, String value, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.5),
      child: Row(children: [
        Container(width: 7, height: 7,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 9),
        Expanded(child: Text(label, style: const TextStyle(fontSize: 12.5))),
        Text(value,
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: color)),
      ]),
    );
  }

  Widget _confirmStep() {
    final r = _report!;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.effectivePrimary.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: AppTheme.effectivePrimary.withValues(alpha: 0.25)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Ready to import ${r.validCount} '
              '${r.validCount == 1 ? "student" : "students"}',
              style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            '${r.guardianComplete} guardian '
            '${r.guardianComplete == 1 ? "record" : "records"} will be created with an '
            'email on file, so activation codes can be sent right away. '
            '${r.guardianPartial} will need contact details added first.',
            style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700, height: 1.5),
          ),
        ]),
      ),
      const SizedBox(height: 14),
      Text(
        'The server checks your subscription capacity and re-runs these '
        'validations before writing. Students beyond your capacity are reported '
        'rather than imported.',
        style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600, height: 1.45),
      ),
    ]);
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  Widget _actions() {
    final canAdvance = switch (_step) {
      0 => _table != null,
      1 => _requiredMapped(),
      2 => true,
      3 => (_report?.validCount ?? 0) > 0,
      _ => true,
    };

    return Row(children: [
      if (_step > 0)
        TextButton.icon(
          onPressed: _busy ? null : () => setState(() => _step -= 1),
          icon: const Icon(Icons.arrow_back_rounded, size: 17),
          label: const Text('Back'),
        ),
      const Spacer(),
      if (_step == 1 && !_requiredMapped())
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Text('Map every required field to continue',
              style: TextStyle(fontSize: 11.5, color: AppTheme.errorColor)),
        ),
      if (_step == 3 && (_report?.validCount ?? 0) == 0)
        Padding(
          padding: const EdgeInsets.only(right: 12),
          child: Text('No valid rows to import',
              style: TextStyle(fontSize: 11.5, color: AppTheme.errorColor)),
        ),
      FilledButton.icon(
        onPressed: !canAdvance || _busy
            ? null
            : () {
                if (_step == 2) {
                  _validate();
                } else if (_step == 4) {
                  _import();
                } else {
                  setState(() => _step += 1);
                }
              },
        icon: _busy
            ? const SizedBox(
                width: 15, height: 15,
                child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : Icon(_step == 4 ? Icons.check_rounded : Icons.arrow_forward_rounded, size: 17),
        label: Text(_busy
            ? 'Importing…'
            : switch (_step) {
                0 => 'Continue',
                1 => 'Continue',
                2 => 'Validate',
                3 => 'Continue',
                _ => 'Import students',
              }),
        style: FilledButton.styleFrom(
          minimumSize: const Size(0, 42),
          backgroundColor: AppTheme.effectivePrimary,
        ),
      ),
    ]);
  }

  /// First/Last may be satisfied by a single Full Name column instead.
  bool _requiredMapped() {
    final hasFullName = _mapping['fullName'] != null;
    for (final f in RosterField.all.where((f) => f.isRequired)) {
      if (_mapping[f.key] != null) continue;
      if ((f.key == 'firstName' || f.key == 'lastName') && hasFullName) continue;
      return false;
    }
    return true;
  }
}
