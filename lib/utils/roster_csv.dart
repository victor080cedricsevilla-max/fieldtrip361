/// Flexible CSV import for bulk student registration.
///
/// Schools export wildly different files, so nothing here assumes a fixed
/// layout: the CSV is read as a header row plus data rows, the admin maps each
/// system field to whichever column holds it, and validation runs before
/// anything is written. Header auto-detection is only a starting suggestion —
/// the admin always has the final say.
library;

class CsvFormatException implements Exception {
  final String message;
  CsvFormatException(this.message);
  @override
  String toString() => message;
}

// ─── Raw reading ─────────────────────────────────────────────────────────────

/// Splits raw CSV text into rows of fields (RFC 4180: `""` escapes a quote).
///
/// Blank lines are dropped by default. Pass [keepEmptyRows] to retain them —
/// the importer needs them so it can report "empty rows" in its summary rather
/// than pretending the file was shorter than it is.
List<List<String>> parseCsv(String input, {bool keepEmptyRows = false}) {
  final rows = <List<String>>[];
  final field = StringBuffer();
  var row = <String>[];
  var inQuotes = false;
  var sawAnything = false;

  for (var i = 0; i < input.length; i++) {
    final c = input[i];
    if (inQuotes) {
      if (c == '"') {
        if (i + 1 < input.length && input[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(c);
      }
    } else {
      switch (c) {
        case '"':
          inQuotes = true;
          sawAnything = true;
        case ',':
          row.add(field.toString().trim());
          field.clear();
          sawAnything = true;
        case '\n':
          row.add(field.toString().trim());
          field.clear();
          rows.add(row);
          row = <String>[];
          sawAnything = false;
        case '\r':
          break; // handled by the \n case
        default:
          field.write(c);
          sawAnything = true;
      }
    }
  }
  if (sawAnything || field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString().trim());
    rows.add(row);
  }

  if (keepEmptyRows) return rows;
  return rows.where((r) => r.any((f) => f.trim().isNotEmpty)).toList();
}

/// A parsed CSV: its header labels and the data rows beneath them.
class CsvTable {
  final List<String> headers;
  final List<List<String>> rows;
  const CsvTable(this.headers, this.rows);

  int get rowCount => rows.length;

  /// Value at [rowIndex] for column [col], or '' when the row is short.
  String cell(int rowIndex, int? col) {
    if (col == null || col < 0) return '';
    final row = rows[rowIndex];
    return col < row.length ? row[col].trim() : '';
  }
}

/// Reads CSV text into a header + rows table.
CsvTable readCsvTable(String csvText) {
  var text = csvText;
  if (text.startsWith('﻿')) text = text.substring(1); // Excel BOM
  final table = parseCsv(text, keepEmptyRows: true);
  if (table.isEmpty) throw CsvFormatException('That file is empty.');
  final headers = table.first.map((h) => h.trim()).toList();
  if (headers.every((h) => h.isEmpty)) {
    throw CsvFormatException('The first line must be a header row.');
  }
  return CsvTable(headers, table.skip(1).toList());
}

// ─── System fields ───────────────────────────────────────────────────────────

/// A field the importer can fill from a CSV column.
class RosterField {
  final String key;
  final String label;
  final bool isRequired;

  /// Header spellings that auto-detect to this field, already normalised.
  final List<String> aliases;

  const RosterField(this.key, this.label, {this.isRequired = false, this.aliases = const []});

  static const studentNumber = RosterField(
    'studentNumber', 'Student ID',
    isRequired: true,
    aliases: ['studentnumber', 'studentno', 'studentid', 'lrn', 'id', 'idnumber'],
  );
  static const firstName = RosterField(
    'firstName', 'First Name',
    isRequired: true,
    aliases: ['firstname', 'givenname', 'fname'],
  );
  static const lastName = RosterField(
    'lastName', 'Last Name',
    isRequired: true,
    aliases: ['lastname', 'surname', 'familyname', 'lname'],
  );
  static const fullName = RosterField(
    'fullName', 'Full Name',
    aliases: ['name', 'fullname', 'studentname', 'completename'],
  );
  static const dateOfBirth = RosterField(
    'dateOfBirth', 'Date of Birth',
    isRequired: true,
    aliases: ['dateofbirth', 'dob', 'birthdate', 'birthday', 'bdate'],
  );
  static const gradeLevel = RosterField(
    'gradeLevel', 'Grade Level',
    aliases: ['gradelevel', 'grade', 'yearlevel', 'year'],
  );
  static const section = RosterField(
    'section', 'Section',
    aliases: ['section', 'class', 'classsection'],
  );
  static const email = RosterField(
    'email', 'Student Email',
    aliases: ['email', 'studentemail', 'emailaddress'],
  );
  static const parentName = RosterField(
    'parentName', 'Parent / Guardian Name',
    aliases: ['parentname', 'guardian', 'guardianname', 'parent', 'motherfather'],
  );
  static const relationship = RosterField(
    'relationship', 'Relationship',
    aliases: ['relationship', 'relation', 'guardianrelationship'],
  );
  static const parentEmail = RosterField(
    'parentEmail', 'Parent Email',
    aliases: ['parentemail', 'guardianemail', 'parentemailaddress'],
  );
  static const parentPhone = RosterField(
    'parentPhone', 'Parent Contact Number',
    aliases: ['parentphone', 'parentcontact', 'guardiancontact', 'contactnumber',
      'parentmobile', 'guardianphone', 'mobile'],
  );

  /// Every mappable field, in the order the mapping screen lists them.
  static const all = <RosterField>[
    studentNumber, firstName, lastName, fullName, dateOfBirth,
    gradeLevel, section, email,
    parentName, relationship, parentEmail, parentPhone,
  ];

  /// Guardian fields — all optional, so a school can import students alone.
  static const guardianKeys = <String>['parentName', 'relationship', 'parentEmail', 'parentPhone'];

  static RosterField byKey(String key) =>
      all.firstWhere((f) => f.key == key, orElse: () => fullName);
}

String normalizeHeader(String raw) =>
    raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

/// Best-guess mapping of system field → column index, for the admin to adjust.
///
/// A file with a single "Name" column maps to [RosterField.fullName]; one with
/// separate columns maps to first/last. Nothing is assumed beyond the header text.
Map<String, int?> suggestMapping(List<String> headers) {
  final normalized = headers.map(normalizeHeader).toList();
  final taken = <int>{};
  final mapping = <String, int?>{};

  for (final field in RosterField.all) {
    int? found;
    for (var i = 0; i < normalized.length; i++) {
      if (taken.contains(i)) continue;
      if (field.aliases.contains(normalized[i])) {
        found = i;
        break;
      }
    }
    if (found != null) taken.add(found);
    mapping[field.key] = found;
  }
  return mapping;
}

// ─── Dates ───────────────────────────────────────────────────────────────────

/// How to read ambiguous slash dates such as 05/06/2010.
enum DateOrder { monthFirst, dayFirst }

const _monthNames = <String, int>{
  'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
  'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
};

/// Parses the date formats schools actually export, returning ISO `yyyy-MM-dd`,
/// or null when the value cannot be read as a real calendar date.
String? normalizeDate(String raw, {DateOrder order = DateOrder.monthFirst}) {
  final value = raw.trim();
  if (value.isEmpty) return null;

  int? y, m, d;

  // 2010-05-14 / 2010/5/14
  final iso = RegExp(r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})$').firstMatch(value);
  if (iso != null) {
    y = int.parse(iso.group(1)!);
    m = int.parse(iso.group(2)!);
    d = int.parse(iso.group(3)!);
  }

  // 14/05/2010, 5-14-2010, 14.05.2010
  final slash = RegExp(r'^(\d{1,2})[-/.](\d{1,2})[-/.](\d{2,4})$').firstMatch(value);
  if (y == null && slash != null) {
    final a = int.parse(slash.group(1)!);
    final b = int.parse(slash.group(2)!);
    var year = int.parse(slash.group(3)!);
    if (year < 100) year += year > 50 ? 1900 : 2000;
    // A value above 12 can only be a day, whichever order was configured.
    if (a > 12 && b <= 12) {
      d = a;
      m = b;
    } else if (b > 12 && a <= 12) {
      m = a;
      d = b;
    } else {
      d = order == DateOrder.dayFirst ? a : b;
      m = order == DateOrder.dayFirst ? b : a;
    }
    y = year;
  }

  // May 14, 2010 / 14 May 2010
  if (y == null) {
    final words = RegExp(r'^([A-Za-z]{3,})\s+(\d{1,2}),?\s+(\d{4})$').firstMatch(value);
    final wordsAlt = RegExp(r'^(\d{1,2})\s+([A-Za-z]{3,})\s+(\d{4})$').firstMatch(value);
    if (words != null) {
      m = _monthNames[words.group(1)!.toLowerCase().substring(0, 3)];
      d = int.parse(words.group(2)!);
      y = int.parse(words.group(3)!);
    } else if (wordsAlt != null) {
      d = int.parse(wordsAlt.group(1)!);
      m = _monthNames[wordsAlt.group(2)!.toLowerCase().substring(0, 3)];
      y = int.parse(wordsAlt.group(3)!);
    }
  }

  if (y == null || m == null || d == null) return null;
  if (m < 1 || m > 12 || d < 1 || d > 31) return null;
  if (y < 1900 || y > DateTime.now().year) return null;

  // Rejects impossible days like 31 February, which DateTime would roll over.
  final parsed = DateTime(y, m, d);
  if (parsed.month != m || parsed.day != d) return null;

  final mm = m.toString().padLeft(2, '0');
  final dd = d.toString().padLeft(2, '0');
  return '$y-$mm-$dd';
}

final _emailPattern = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$');
bool isValidEmailAddress(String v) => _emailPattern.hasMatch(v.trim());

/// Whether [v] is a plausible Philippine mobile number.
///
/// Accepts every way a school types them — 0917 123 4567, +63 917-123-4567,
/// 9171234567 — because rejecting all but one format would strand most rows.
bool isPhMobile(String v) {
  final digits = v.replaceAll(RegExp(r'[^0-9]'), '');
  String local;
  if (digits.startsWith('63') && digits.length == 12) {
    local = digits.substring(2);
  } else if (digits.startsWith('0') && digits.length == 11) {
    local = digits.substring(1);
  } else if (digits.length == 10) {
    local = digits;
  } else {
    return false;
  }
  return local.startsWith('9') && local.length == 10;
}

// ─── Validation ──────────────────────────────────────────────────────────────

/// Why a single row cannot be imported, or needs the admin's attention.
class RowIssue {
  final int row; // 1-based line number in the file
  final String field;
  final String message;
  final bool blocking; // true = row will not be imported
  const RowIssue(this.row, this.field, this.message, {this.blocking = true});
}

/// How complete the guardian information on a row is.
enum GuardianCompleteness { complete, partial, none }

/// The outcome of validating a mapped CSV, ready to show as an import preview.
class ValidationReport {
  final int totalRows;
  final List<Map<String, dynamic>> validRows;
  final List<RowIssue> issues;
  final int emptyRows;
  final int duplicateInFile;
  final int alreadyRegistered;
  final int guardianComplete;
  final int guardianPartial;
  final int guardianNone;

  const ValidationReport({
    required this.totalRows,
    required this.validRows,
    required this.issues,
    required this.emptyRows,
    required this.duplicateInFile,
    required this.alreadyRegistered,
    required this.guardianComplete,
    required this.guardianPartial,
    required this.guardianNone,
  });

  int get validCount => validRows.length;
  int get rejectedCount => issues.where((i) => i.blocking).map((i) => i.row).toSet().length;
  bool get hasBlockingIssues => rejectedCount > 0;

  /// Issue counts grouped by message, for a compact summary.
  Map<String, int> get issueBreakdown {
    final out = <String, int>{};
    for (final i in issues) {
      out[i.message] = (out[i.message] ?? 0) + 1;
    }
    return out;
  }
}

/// Validates mapped rows against the required fields and the existing roster.
///
/// Nothing is silently dropped: every rejected row appears in [ValidationReport.issues]
/// with its line number so the admin can fix the file and re-upload.
ValidationReport validateMappedRows(
  CsvTable table,
  Map<String, int?> mapping, {
  Set<String> existingStudentNumbers = const {},
  Set<String> existingEmails = const {},
  DateOrder dateOrder = DateOrder.monthFirst,
}) {
  final valid = <Map<String, dynamic>>[];
  final issues = <RowIssue>[];
  final seenNumbers = <String>{};
  final seenEmails = <String>{};

  var emptyRows = 0;
  var duplicateInFile = 0;
  var alreadyRegistered = 0;
  var gComplete = 0, gPartial = 0, gNone = 0;

  String at(int r, String key) => table.cell(r, mapping[key]);

  for (var r = 0; r < table.rowCount; r++) {
    final lineNo = r + 2; // header occupies line 1

    // Split full name on the last space so multi-word given names survive.
    var first = at(r, 'firstName');
    var last = at(r, 'lastName');
    if (first.isEmpty && last.isEmpty) {
      final full = at(r, 'fullName');
      if (full.isNotEmpty) {
        final cut = full.lastIndexOf(' ');
        if (cut > 0) {
          first = full.substring(0, cut).trim();
          last = full.substring(cut + 1).trim();
        } else {
          first = full;
        }
      }
    }

    final studentNumber = at(r, 'studentNumber').toUpperCase();
    final dobRaw = at(r, 'dateOfBirth');
    final email = at(r, 'email').toLowerCase();
    final parentName = at(r, 'parentName');
    final parentEmail = at(r, 'parentEmail').toLowerCase();
    final parentPhone = at(r, 'parentPhone');

    final everythingBlank = [
      studentNumber, first, last, dobRaw, email,
      parentName, parentEmail, parentPhone,
      at(r, 'gradeLevel'), at(r, 'section'),
    ].every((v) => v.isEmpty);
    if (everythingBlank) {
      emptyRows++;
      continue;
    }

    final rowIssues = <RowIssue>[];

    if (studentNumber.isEmpty) {
      rowIssues.add(RowIssue(lineNo, 'studentNumber', 'Missing Student ID'));
    }
    if (first.isEmpty) {
      rowIssues.add(RowIssue(lineNo, 'firstName', 'Missing first name'));
    }
    if (last.isEmpty) {
      rowIssues.add(RowIssue(lineNo, 'lastName', 'Missing last name'));
    }

    String? dob;
    if (dobRaw.isEmpty) {
      rowIssues.add(RowIssue(lineNo, 'dateOfBirth', 'Missing date of birth'));
    } else {
      dob = normalizeDate(dobRaw, order: dateOrder);
      if (dob == null) {
        rowIssues.add(RowIssue(lineNo, 'dateOfBirth', 'Invalid date "$dobRaw"'));
      }
    }

    if (email.isNotEmpty && !isValidEmailAddress(email)) {
      rowIssues.add(RowIssue(lineNo, 'email', 'Invalid student email "$email"'));
    }

    // Duplicates inside the file, and against students already on the roster.
    if (studentNumber.isNotEmpty) {
      if (seenNumbers.contains(studentNumber)) {
        duplicateInFile++;
        rowIssues.add(RowIssue(lineNo, 'studentNumber',
            'Duplicate Student ID "$studentNumber" appears earlier in this file'));
      } else if (existingStudentNumbers.contains(studentNumber)) {
        alreadyRegistered++;
        rowIssues.add(RowIssue(lineNo, 'studentNumber',
            'Student ID "$studentNumber" is already registered'));
      }
    }
    if (email.isNotEmpty && isValidEmailAddress(email)) {
      if (seenEmails.contains(email)) {
        duplicateInFile++;
        rowIssues.add(RowIssue(lineNo, 'email',
            'Duplicate email "$email" appears earlier in this file'));
      } else if (existingEmails.contains(email)) {
        alreadyRegistered++;
        rowIssues.add(RowIssue(lineNo, 'email', 'Email "$email" is already registered'));
      }
    }

    // Guardian problems never block a student — they are reported so the admin
    // knows which parents cannot be invited yet.
    GuardianCompleteness completeness;
    if (parentName.isEmpty) {
      completeness = GuardianCompleteness.none;
      if (parentEmail.isNotEmpty || parentPhone.isNotEmpty) {
        rowIssues.add(RowIssue(lineNo, 'parentName',
            'Guardian contact details given without a name', blocking: false));
      }
    } else if ((parentEmail.isNotEmpty && isValidEmailAddress(parentEmail)) ||
        isPhMobile(parentPhone)) {
      // Either channel makes the guardian contactable. Most Philippine rosters
      // carry a mobile number and no email at all, so treating "no email" as
      // incomplete would mark almost every guardian unreachable.
      completeness = GuardianCompleteness.complete;
      if (parentEmail.isNotEmpty && !isValidEmailAddress(parentEmail)) {
        rowIssues.add(RowIssue(lineNo, 'parentEmail',
            'Invalid parent email "$parentEmail" — the code will go by SMS instead',
            blocking: false));
      }
    } else {
      completeness = GuardianCompleteness.partial;
      if (parentEmail.isNotEmpty) {
        rowIssues.add(RowIssue(lineNo, 'parentEmail',
            'Invalid parent email "$parentEmail"', blocking: false));
      } else if (parentPhone.isNotEmpty) {
        rowIssues.add(RowIssue(lineNo, 'parentPhone',
            'Contact number "$parentPhone" is not a valid PH mobile number',
            blocking: false));
      } else {
        rowIssues.add(RowIssue(lineNo, 'parentEmail',
            'Guardian has no email or mobile number — no way to send a code',
            blocking: false));
      }
    }

    issues.addAll(rowIssues);
    if (rowIssues.any((i) => i.blocking)) continue;

    if (studentNumber.isNotEmpty) seenNumbers.add(studentNumber);
    if (email.isNotEmpty) seenEmails.add(email);

    switch (completeness) {
      case GuardianCompleteness.complete:
        gComplete++;
      case GuardianCompleteness.partial:
        gPartial++;
      case GuardianCompleteness.none:
        gNone++;
    }

    valid.add({
      '__row': lineNo,
      'studentNumber': studentNumber,
      'firstName': first,
      'lastName': last,
      'dateOfBirth': dob,
      'email': email,
      'gradeLevel': at(r, 'gradeLevel'),
      'section': at(r, 'section'),
      'parentName': parentName,
      'relationship': at(r, 'relationship'),
      'parentEmail': isValidEmailAddress(parentEmail) ? parentEmail : '',
      'parentPhone': parentPhone,
    });
  }

  return ValidationReport(
    totalRows: table.rowCount,
    validRows: valid,
    issues: issues,
    emptyRows: emptyRows,
    duplicateInFile: duplicateInFile,
    alreadyRegistered: alreadyRegistered,
    guardianComplete: gComplete,
    guardianPartial: gPartial,
    guardianNone: gNone,
  );
}

/// Header line shown to admins in the format help dialog.
const rosterCsvTemplate =
    'student_number,first_name,last_name,date_of_birth,grade_level,section,'
    'parent_name,relationship,parent_email';

const rosterCsvExample =
    '$rosterCsvTemplate\n'
    '2024-0001,Juan,Dela Cruz,2010-05-14,Grade 10,St. Peter,Pedro Dela Cruz,Father,pedro@email.com\n'
    '2024-0002,Ana,Reyes,2010-11-02,Grade 10,St. Peter,Rosa Reyes,Mother,rosa@email.com';
