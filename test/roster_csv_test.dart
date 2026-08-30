import 'package:flutter_test/flutter_test.dart';
import 'package:fieldtrip361/utils/roster_csv.dart';

/// Header layouts taken from the three example schools in the spec.
const _schoolA =
    'Student Number,First Name,Last Name,Birth Date,Grade,Section,Parent Name,Parent Email\n'
    '2024-0001,Juan,Dela Cruz,2010-05-14,Grade 10,St. Peter,Pedro Dela Cruz,pedro@email.com';

const _schoolB = 'LRN,Full Name,DOB,Grade Level,Section\n'
    '136789012345,Maria Clara Santos,03/22/2011,Grade 9,St. Paul';

const _schoolC = 'Student ID,Name,Grade,Section,Parent Name,Parent Contact\n'
    'S-0042,Jose Rizal,Grade 11,STEM-A,Teodora Alonso,09171234567';

ValidationReport _validate(String csv, {DateOrder order = DateOrder.monthFirst}) {
  final table = readCsvTable(csv);
  return validateMappedRows(table, suggestMapping(table.headers), dateOrder: order);
}

void main() {
  group('parseCsv', () {
    test('handles quoted fields containing commas', () {
      expect(parseCsv('a,"Dela Cruz, Juan",c'), [
        ['a', 'Dela Cruz, Juan', 'c']
      ]);
    });

    test('handles escaped quotes and CRLF endings', () {
      expect(parseCsv('x,y\r\n"say ""hi""",z\r\n'), [
        ['x', 'y'],
        ['say "hi"', 'z'],
      ]);
    });

    test('drops blank lines', () {
      expect(parseCsv('a,b\n\n\nc,d\n').length, 2);
    });
  });

  group('column mapping', () {
    test('auto-detects School A: separate first and last name columns', () {
      final table = readCsvTable(_schoolA);
      final m = suggestMapping(table.headers);
      expect(table.headers[m['studentNumber']!], 'Student Number');
      expect(table.headers[m['firstName']!], 'First Name');
      expect(table.headers[m['lastName']!], 'Last Name');
      expect(table.headers[m['dateOfBirth']!], 'Birth Date');
      expect(table.headers[m['parentEmail']!], 'Parent Email');
      expect(m['fullName'], isNull);
    });

    test('auto-detects School B: LRN and a single full-name column', () {
      final table = readCsvTable(_schoolB);
      final m = suggestMapping(table.headers);
      expect(table.headers[m['studentNumber']!], 'LRN');
      expect(table.headers[m['fullName']!], 'Full Name');
      expect(table.headers[m['dateOfBirth']!], 'DOB');
      // No parent columns at all in this file.
      expect(m['parentName'], isNull);
      expect(m['parentEmail'], isNull);
    });

    test('auto-detects School C: parent contact but no email', () {
      final table = readCsvTable(_schoolC);
      final m = suggestMapping(table.headers);
      expect(table.headers[m['studentNumber']!], 'Student ID');
      expect(table.headers[m['parentName']!], 'Parent Name');
      expect(table.headers[m['parentPhone']!], 'Parent Contact');
      expect(m['parentEmail'], isNull);
    });

    test('never maps two system fields to the same column', () {
      final table = readCsvTable('Name,Name,Grade\nA B,C D,10');
      final m = suggestMapping(table.headers);
      final used = m.values.whereType<int>().toList();
      expect(used.toSet().length, used.length);
    });

    test('an admin override is honoured over the suggestion', () {
      final table = readCsvTable('colA,colB,colC,colD\nX-1,Juan,Cruz,2010-01-05');
      // Nothing auto-detects from these headers.
      expect(suggestMapping(table.headers).values.whereType<int>(), isEmpty);
      final report = validateMappedRows(table, {
        'studentNumber': 0,
        'firstName': 1,
        'lastName': 2,
        'dateOfBirth': 3,
      });
      expect(report.validCount, 1);
      expect(report.validRows.first['studentNumber'], 'X-1');
      expect(report.validRows.first['dateOfBirth'], '2010-01-05');
    });
  });

  group('date normalisation', () {
    test('accepts ISO, slash, dotted and written formats', () {
      expect(normalizeDate('2010-05-14'), '2010-05-14');
      expect(normalizeDate('05/14/2010'), '2010-05-14');
      expect(normalizeDate('14.05.2010'), '2010-05-14');
      expect(normalizeDate('May 14, 2010'), '2010-05-14');
      expect(normalizeDate('14 May 2010'), '2010-05-14');
    });

    test('a value above 12 is read as the day whatever the configured order', () {
      expect(normalizeDate('25/06/2010', order: DateOrder.monthFirst), '2010-06-25');
      expect(normalizeDate('06/25/2010', order: DateOrder.dayFirst), '2010-06-25');
    });

    test('ambiguous dates follow the configured order', () {
      expect(normalizeDate('05/06/2010', order: DateOrder.monthFirst), '2010-05-06');
      expect(normalizeDate('05/06/2010', order: DateOrder.dayFirst), '2010-06-05');
    });

    test('rejects impossible and unparseable dates', () {
      expect(normalizeDate('2010-02-31'), isNull); // would silently roll over
      expect(normalizeDate('2010-13-01'), isNull);
      expect(normalizeDate('not a date'), isNull);
      expect(normalizeDate('3025-01-01'), isNull); // in the future
      expect(normalizeDate(''), isNull);
    });
  });

  group('validation', () {
    test('imports the three example school formats', () {
      expect(_validate(_schoolA).validCount, 1);
      expect(_validate(_schoolB).validCount, 1);
      // School C has no date of birth column, which is required.
      final c = _validate(_schoolC);
      expect(c.validCount, 0);
      expect(c.issues.any((i) => i.message == 'Missing date of birth'), isTrue);
    });

    test('splits a full-name column on the last space', () {
      final rows = _validate(_schoolB).validRows;
      expect(rows.first['firstName'], 'Maria Clara');
      expect(rows.first['lastName'], 'Santos');
    });

    test('reports every required field that is missing', () {
      final r = _validate('Student Number,First Name,Last Name,DOB\n,,,\n,Juan,,2010-01-01');
      // Row 2 is entirely blank; row 3 is missing ID and last name.
      expect(r.emptyRows, 1);
      expect(r.issues.any((i) => i.message == 'Missing Student ID'), isTrue);
      expect(r.issues.any((i) => i.message == 'Missing last name'), isTrue);
      expect(r.validCount, 0);
    });

    test('flags duplicate student IDs inside the file', () {
      final r = _validate(
        'Student Number,First Name,Last Name,DOB\n'
        'A-1,Juan,Cruz,2010-01-01\n'
        'A-1,Ana,Reyes,2011-02-02',
      );
      expect(r.validCount, 1);
      expect(r.duplicateInFile, 1);
      expect(r.issues.any((i) => i.message.contains('Duplicate Student ID')), isTrue);
    });

    test('flags students already on the roster', () {
      final table = readCsvTable(
          'Student Number,First Name,Last Name,DOB\nA-1,Juan,Cruz,2010-01-01');
      final r = validateMappedRows(table, suggestMapping(table.headers),
          existingStudentNumbers: {'A-1'});
      expect(r.validCount, 0);
      expect(r.alreadyRegistered, 1);
    });

    test('flags invalid email addresses', () {
      final r = _validate(
          'Student Number,First Name,Last Name,DOB,Email\nA-1,Juan,Cruz,2010-01-01,not-an-email');
      expect(r.validCount, 0);
      expect(r.issues.any((i) => i.message.contains('Invalid student email')), isTrue);
    });

    test('never silently discards a row — every rejection is reported', () {
      final r = _validate(
        'Student Number,First Name,Last Name,DOB\n'
        ',Juan,Cruz,2010-01-01\n'
        'A-2,Ana,Reyes,32/32/2010\n'
        'A-3,Jose,Rizal,2010-03-03',
      );
      expect(r.validCount, 1);
      expect(r.rejectedCount, 2);
      // Both bad rows are identifiable by line number.
      expect(r.issues.map((i) => i.row).toSet().containsAll({2, 3}), isTrue);
    });

    test('counts empty rows separately from rejected ones', () {
      final r = _validate(
          'Student Number,First Name,Last Name,DOB\nA-1,Juan,Cruz,2010-01-01\n,,,\n');
      expect(r.emptyRows, 1);
      expect(r.validCount, 1);
      expect(r.rejectedCount, 0);
    });
  });

  group('guardian completeness', () {
    test('name plus a valid email counts as complete', () {
      final r = _validate(_schoolA);
      expect(r.guardianComplete, 1);
      expect(r.guardianPartial, 0);
      expect(r.guardianNone, 0);
      expect(r.validRows.first['parentEmail'], 'pedro@email.com');
    });

    test('a mobile number with no email still counts as contactable', () {
      // Most Philippine rosters carry a number and no address; the code goes by
      // SMS, so this guardian is complete rather than waiting on contact details.
      final r = _validate(_schoolC.replaceFirst('Grade,Section', 'DOB,Section')
          .replaceFirst('Grade 11,STEM-A', '2010-04-04,STEM-A'));
      expect(r.validCount, 1, reason: 'the student still imports');
      expect(r.guardianComplete, 1);
      expect(r.guardianPartial, 0);
    });

    test('a name with neither email nor mobile is partial', () {
      final r = _validate(
        'Student Number,First Name,Last Name,DOB,Parent Name\n'
        'A-1,Juan,Cruz,2010-01-01,Pedro Cruz',
      );
      expect(r.validCount, 1, reason: 'the student still imports');
      expect(r.guardianPartial, 1);
      expect(
        r.issues.any((i) => !i.blocking && i.message.contains('no way to send a code')),
        isTrue,
      );
    });

    test('an unusable contact number is reported, not silently accepted', () {
      final r = _validate(
        'Student Number,First Name,Last Name,DOB,Parent Name,Parent Contact\n'
        'A-1,Juan,Cruz,2010-01-01,Pedro Cruz,12345',
      );
      expect(r.guardianPartial, 1);
      expect(
        r.issues.any((i) => !i.blocking && i.message.contains('not a valid PH mobile')),
        isTrue,
      );
    });

    test('accepts the ways a school actually types a mobile number', () {
      for (final n in ['09171234567', '+63 917 123 4567', '63-917-123-4567', '9171234567']) {
        expect(isPhMobile(n), isTrue, reason: n);
      }
      for (final n in ['12345', '0817 123 4567', '', 'not a number']) {
        expect(isPhMobile(n), isFalse, reason: n);
      }
    });

    test('an invalid parent email with no fallback number is partial', () {
      final r = _validate(
        'Student Number,First Name,Last Name,DOB,Parent Name,Parent Email\n'
        'A-1,Juan,Cruz,2010-01-01,Pedro Cruz,bogus-email',
      );
      expect(r.validCount, 1);
      expect(r.guardianPartial, 1);
      // The unusable address is not carried through to the import.
      expect(r.validRows.first['parentEmail'], '');
      expect(r.issues.any((i) => !i.blocking && i.message.contains('Invalid parent email')),
          isTrue);
    });

    test('a file with no parent columns imports with no guardians', () {
      final r = _validate(_schoolB);
      expect(r.validCount, 1);
      expect(r.guardianNone, 1);
      expect(r.validRows.first['parentName'], '');
    });

    test('contact details without a name are reported but not blocking', () {
      final r = _validate(
        'Student Number,First Name,Last Name,DOB,Parent Name,Parent Email\n'
        'A-1,Juan,Cruz,2010-01-01,,pedro@email.com',
      );
      expect(r.validCount, 1);
      expect(r.guardianNone, 1);
      expect(
        r.issues.any((i) => !i.blocking && i.message.contains('without a name')),
        isTrue,
      );
    });
  });

  group('import summary', () {
    test('totals reconcile across valid, rejected and empty rows', () {
      final r = _validate(
        'Student Number,First Name,Last Name,DOB,Parent Name,Parent Email\n'
        'A-1,Juan,Cruz,2010-01-01,Pedro Cruz,pedro@email.com\n'
        'A-2,Ana,Reyes,2011-02-02,Rosa Reyes,\n'
        'A-3,Jose,Rizal,2010-03-03,,\n'
        ',Bad,Row,2010-04-04,,\n'
        ',,,,,\n',
      );
      expect(r.totalRows, 5);
      expect(r.validCount, 3);
      expect(r.rejectedCount, 1);
      expect(r.emptyRows, 1);
      expect(r.validCount + r.rejectedCount + r.emptyRows, r.totalRows);

      expect(r.guardianComplete, 1);
      expect(r.guardianPartial, 1);
      expect(r.guardianNone, 1);
    });

    test('groups issues by message for the preview summary', () {
      final r = _validate(
        'Student Number,First Name,Last Name,DOB\n'
        ',Juan,Cruz,2010-01-01\n'
        ',Ana,Reyes,2011-02-02',
      );
      expect(r.issueBreakdown['Missing Student ID'], 2);
    });
  });
}
