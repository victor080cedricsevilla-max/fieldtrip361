import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../../config/theme.dart';
import '../../utils/firestore_utils.dart';
import '../../utils/trip_queries.dart';

enum _ReportType { tripSummary, tripDetail, attendance, monthlyActivity }

class ReportsView extends StatefulWidget {
  const ReportsView({super.key});

  @override
  State<ReportsView> createState() => _ReportsViewState();
}

class _ReportsViewState extends State<ReportsView> {
  _ReportType _reportType = _ReportType.tripSummary;
  DateTime? _fromDate;
  DateTime? _toDate;
  bool _exporting = false;

  /// Free-text search over the trip title. Filters the list the same way the
  /// date range does, so a search and a range narrow together.
  final _searchCtrl = TextEditingController();
  String _search = '';

  /// The one trip a detail report is about. A detail report of forty trips is
  /// not a detail report, so this mode asks for a single choice.
  String? _selectedTripId;

  /// Geofence alerts for the selected trip, fetched just before the PDF is
  /// built. They live in a sub-collection, so they cannot be read from the
  /// trip snapshot the rest of this screen already has.
  List<Map<String, dynamic>> _detailAlerts = const [];

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  static const _monthNames = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  String get _dateRangeLabel {
    if (_fromDate == null && _toDate == null) return 'All time';
    final f = _fromDate == null ? '' : '${_fromDate!.month}/${_fromDate!.day}/${_fromDate!.year}';
    final t = _toDate == null ? '' : '${_toDate!.month}/${_toDate!.day}/${_toDate!.year}';
    if (_fromDate != null && _toDate != null) return '$f -- $t';
    if (_fromDate != null) return 'From $f';
    return 'Until $t';
  }

  List<QueryDocumentSnapshot<Map<String, dynamic>>> _filterTrips(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> trips,
  ) {
    final q = _search.trim().toLowerCase();
    if (_fromDate == null && _toDate == null && q.isEmpty) return trips;
    return trips.where((doc) {
      final data = doc.data();
      if (q.isNotEmpty) {
        final title = (data['title'] ?? '').toString().toLowerCase();
        if (!title.contains(q)) return false;
      }
      DateTime? tripDate;
      final dateStr = data['date'] as String?;
      if (dateStr != null && dateStr.isNotEmpty) {
        tripDate = DateTime.tryParse(dateStr) ?? _parseSlashDate(dateStr);
      }
      tripDate ??= (data['createdAt'] as Timestamp?)?.toDate();
      if (tripDate == null) return true;
      if (_fromDate != null && tripDate.isBefore(_fromDate!)) return false;
      if (_toDate != null && tripDate.isAfter(_toDate!.add(const Duration(days: 1)))) return false;
      return true;
    }).toList();
  }

  DateTime? _parseSlashDate(String s) {
    final parts = s.split('/');
    if (parts.length == 3) {
      final m = int.tryParse(parts[0]);
      final d = int.tryParse(parts[1]);
      final y = int.tryParse(parts[2]);
      if (m != null && d != null && y != null) return DateTime(y, m, d);
    }
    return null;
  }

  Future<void> _pickDate({required bool isFrom}) async {
    final initial = isFrom
        ? (_fromDate ?? DateTime.now().subtract(const Duration(days: 30)))
        : (_toDate ?? DateTime.now());
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
      builder: (ctx, child) => Theme(
        data: Theme.of(ctx).copyWith(
          colorScheme: ColorScheme.light(primary: AppTheme.effectivePrimary),
        ),
        child: child!,
      ),
    );
    if (picked == null) return;
    setState(() {
      if (isFrom) {
        _fromDate = picked;
        if (_toDate != null && _toDate!.isBefore(picked)) _toDate = null;
      } else {
        _toDate = picked;
        if (_fromDate != null && _fromDate!.isAfter(picked)) _fromDate = null;
      }
    });
  }

  Future<void> _exportPdf(List<QueryDocumentSnapshot<Map<String, dynamic>>> trips) async {
    setState(() => _exporting = true);
    try {
      if (_reportType == _ReportType.tripDetail) {
        final id = _selectedTripId ?? (trips.isNotEmpty ? trips.first.id : null);
        if (id == null) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
              content: Text('Choose a trip to report on first.'),
            ));
          }
          return;
        }
        final alerts = await FirebaseFirestore.instance
            .collection('trips')
            .doc(id)
            .collection('alerts')
            .get();
        final list = alerts.docs.map((a) => a.data()).toList()
          ..sort((a, b) {
            final at = a['createdAt'] as Timestamp?;
            final bt = b['createdAt'] as Timestamp?;
            return (at?.millisecondsSinceEpoch ?? 0)
                .compareTo(bt?.millisecondsSinceEpoch ?? 0);
          });
        _detailAlerts = list;
      }
      final doc = pw.Document();
      final title = _reportType == _ReportType.tripDetail
          ? 'Trip Detail Report'
          : _reportType == _ReportType.tripSummary
          ? 'Trip Summary Report'
          : _reportType == _ReportType.attendance
              ? 'Attendance Report'
              : 'Monthly Activity Report';

      doc.addPage(pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        header: (ctx) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Text('FieldTrip 360',
                style: pw.TextStyle(
                    fontSize: 10,
                    color: PdfColors.grey600,
                    fontWeight: pw.FontWeight.bold)),
            pw.SizedBox(height: 4),
            pw.Text(title,
                style: pw.TextStyle(
                    fontSize: 20,
                    fontWeight: pw.FontWeight.bold,
                    color: PdfColors.blueGrey800)),
            pw.Text('Date range: $_dateRangeLabel',
                style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700)),
            pw.Text(
              'Generated: ${DateTime.now().day}/${DateTime.now().month}/${DateTime.now().year}',
              style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey600),
            ),
            pw.Divider(color: PdfColors.grey400),
            pw.SizedBox(height: 8),
          ],
        ),
        build: (ctx) => _buildPdfContent(trips),
      ));

      final bytes = await doc.save();
      final filename = '${title.replaceAll(' ', '_')}_${DateTime.now().millisecondsSinceEpoch}.pdf';
      await Printing.layoutPdf(
        onLayout: (_) async => bytes,
        name: filename,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Export failed: $e'),
          backgroundColor: Colors.red,
        ));
      }
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  List<pw.Widget> _buildPdfContent(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> trips) {
    switch (_reportType) {
      case _ReportType.tripSummary:
        return _buildSummaryPdf(trips);
      case _ReportType.tripDetail:
        return _buildTripDetailPdf(trips);
      case _ReportType.attendance:
        return _buildAttendancePdf(trips);
      case _ReportType.monthlyActivity:
        return _buildMonthlyPdf(trips);
    }
  }

  List<pw.Widget> _buildSummaryPdf(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> trips) {
    final total = trips.length;
    final completed = trips.where((d) => d.data()['status'] == 'completed').length;
    final ongoing = trips.where((d) => d.data()['status'] == 'in_progress').length;
    final pending = trips.where((d) => d.data()['status'] == 'pending').length;
    int buses = 0, students = 0, attendance = 0;
    for (final doc in trips) {
      for (final bus in asList(doc.data()['buses'])) {
        buses++;
        for (final p in asList(bus['passengers'])) {
          students++;
          final att = (p['attendance'] as Map?) ?? {};
          attendance += att.values.where((v) => v == true).length;
        }
      }
    }

    final rows = [
      ['Total Trips', '$total'],
      ['Completed Trips', '$completed'],
      ['Ongoing Trips', '$ongoing'],
      ['Pending Trips', '$pending'],
      ['Total Buses Used', '$buses'],
      ['Student Slots', '$students'],
      ['Attendance Marks', '$attendance'],
    ];

    return [
      pw.TableHelper.fromTextArray(
        headers: ['Metric', 'Value'],
        data: rows,
        headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white),
        headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey700),
        oddRowDecoration: const pw.BoxDecoration(color: PdfColors.grey100),
        cellAlignments: {0: pw.Alignment.centerLeft, 1: pw.Alignment.center},
        columnWidths: {0: const pw.FlexColumnWidth(3), 1: const pw.FlexColumnWidth(1)},
      ),
      pw.SizedBox(height: 20),
      pw.Text('Trip List (${trips.length})',
          style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 13)),
      pw.SizedBox(height: 8),
      pw.TableHelper.fromTextArray(
        headers: ['Trip Name', 'Date', 'Status', 'Buses'],
        data: trips.map((doc) {
          final d = doc.data();
          return [
            d['title'] ?? 'Untitled',
            d['date'] ?? '',
            (d['status'] ?? 'pending').toString(),
            '${asList(d['buses']).length}',
          ];
        }).toList(),
        headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white),
        headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey600),
        oddRowDecoration: const pw.BoxDecoration(color: PdfColors.grey100),
      ),
    ];
  }

  /// Everything that happened on one trip.
  ///
  /// The other reports answer "how did the term go"; this one answers "what
  /// happened on the 25th". That means naming people rather than counting
  /// them: who was present at each stop, whether a scan or a facilitator put
  /// them there and why, and who left the zone.
  List<pw.Widget> _buildTripDetailPdf(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> trips) {
    final doc = trips.firstWhere(
      (t) => t.id == _selectedTripId,
      orElse: () => trips.first,
    );
    final d = doc.data();
    final stops = asList(d['stops']);
    final buses = asList(d['buses']);

    final out = <pw.Widget>[];

    // Heading.
    out.add(pw.Text((d['title'] ?? 'Untitled trip').toString(),
        style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)));
    out.add(pw.SizedBox(height: 2));
    out.add(pw.Text(
      '${d['date'] ?? 'no date'}  -  ${(d['status'] ?? 'pending').toString().replaceAll('_', ' ')}'
      '  -  ${buses.length} bus(es)  -  ${stops.length} stop(s)',
      style: const pw.TextStyle(fontSize: 10, color: PdfColors.grey700),
    ));
    out.add(pw.SizedBox(height: 14));

    // Itinerary.
    if (stops.isNotEmpty) {
      out.add(pw.Text('Itinerary',
          style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)));
      out.add(pw.SizedBox(height: 6));
      out.add(pw.TableHelper.fromTextArray(
        headers: const ['#', 'Destination', 'Time', 'Geofence'],
        data: [
          for (int i = 0; i < stops.length; i++)
            [
              '${i + 1}',
              (stops[i]['name'] ?? '--').toString(),
              (stops[i]['time'] ?? '--').toString(),
              stops[i]['geofenceRadius'] == null
                  ? '--'
                  : '${stops[i]['geofenceRadius']} m',
            ],
        ],
        cellStyle: const pw.TextStyle(fontSize: 9),
        headerStyle: pw.TextStyle(
            fontWeight: pw.FontWeight.bold, color: PdfColors.white, fontSize: 9),
        headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey700),
        oddRowDecoration: const pw.BoxDecoration(color: PdfColors.grey100),
        columnWidths: {
          0: const pw.FlexColumnWidth(0.6),
          1: const pw.FlexColumnWidth(4),
          2: const pw.FlexColumnWidth(1.4),
          3: const pw.FlexColumnWidth(1.4),
        },
      ));
      out.add(pw.SizedBox(height: 16));
    }

    // Attendance, one row per student.
    out.add(pw.Text('Attendance',
        style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)));
    out.add(pw.SizedBox(height: 2));
    out.add(pw.Text(
      'One row per student. A stop shows S when a verified scan recorded it and '
      'M when a facilitator did; a blank means no record was taken at that stop.',
      style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700),
    ));
    out.add(pw.SizedBox(height: 6));

    final stopHeaders = [for (int i = 0; i < stops.length; i++) '${i + 1}'];
    final attRows = <List<String>>[];
    final overrides = <List<String>>[];

    for (int bi = 0; bi < buses.length; bi++) {
      final bus = buses[bi];
      final busLabel = 'Bus ${bus['busLabel'] ?? bus['busNo'] ?? (bi + 1)}';
      for (final p in asList(bus['passengers'])) {
        final att = (p['attendance'] as Map?) ?? {};
        final meta = (p['attendanceMeta'] as Map?) ?? {};
        final marks = <String>[];
        for (int i = 0; i < stops.length; i++) {
          final key = 'stop_$i';
          if (att[key] != true) {
            marks.add('');
            continue;
          }
          final m = meta[key];
          final manual = m is Map && m['source'] == 'manual';
          marks.add(manual ? 'M' : 'S');
          if (manual) {
            overrides.add([
              (p['lrn'] ?? '--').toString(),
              (p['name'] ?? 'Student').toString(),
              busLabel,
              (stops[i]['name'] ?? 'Stop ${i + 1}').toString(),
              (m['reason'] ?? '--').toString(),
            ]);
          }
        }
        final recorded = marks.where((m) => m.isNotEmpty).length;
        attRows.add([
          (p['lrn'] ?? '--').toString(),
          (p['name'] ?? 'Student').toString(),
          busLabel,
          ...marks,
          '$recorded/${stops.length}',
        ]);
      }
    }

    out.add(pw.TableHelper.fromTextArray(
      headers: ['Student ID', 'Name', 'Bus', ...stopHeaders, 'Total'],
      data: attRows.isEmpty
          ? [
              ['--', 'No students assigned', '', ...stopHeaders.map((_) => ''), '']
            ]
          : attRows,
      cellStyle: const pw.TextStyle(fontSize: 8.5),
      cellAlignment: pw.Alignment.centerLeft,
      headerStyle: pw.TextStyle(
          fontWeight: pw.FontWeight.bold, color: PdfColors.white, fontSize: 8.5),
      headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey700),
      oddRowDecoration: const pw.BoxDecoration(color: PdfColors.grey100),
      columnWidths: {
        0: const pw.FlexColumnWidth(1.8),
        1: const pw.FlexColumnWidth(3.4),
        2: const pw.FlexColumnWidth(1.4),
      },
    ));
    out.add(pw.SizedBox(height: 16));

    // What a facilitator vouched for, and why.
    out.add(pw.Text('Recorded by a facilitator',
        style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)));
    out.add(pw.SizedBox(height: 2));
    out.add(pw.Text(
      'A facilitator may vouch for a student whose device could not be verified - '
      'a flat battery, no signal, a phone left on the bus. Each one carries the '
      'reason they gave at the time.',
      style: const pw.TextStyle(fontSize: 8.5, color: PdfColors.grey700),
    ));
    out.add(pw.SizedBox(height: 6));
    out.add(pw.TableHelper.fromTextArray(
      headers: const ['Student ID', 'Name', 'Bus', 'Stop', 'Reason given'],
      data: overrides.isEmpty
          ? [
              ['--', 'No manual entries on this trip', '', '', '']
            ]
          : overrides,
      cellStyle: const pw.TextStyle(fontSize: 8.5),
      headerStyle: pw.TextStyle(
          fontWeight: pw.FontWeight.bold, color: PdfColors.white, fontSize: 8.5),
      headerDecoration: const pw.BoxDecoration(color: PdfColors.orange700),
      oddRowDecoration: const pw.BoxDecoration(color: PdfColors.grey100),
      columnWidths: {
        0: const pw.FlexColumnWidth(1.6),
        1: const pw.FlexColumnWidth(2.6),
        2: const pw.FlexColumnWidth(1.2),
        3: const pw.FlexColumnWidth(2),
        4: const pw.FlexColumnWidth(4),
      },
    ));
    out.add(pw.SizedBox(height: 16));

    // Who left the zone.
    out.add(pw.Text('Left the designated area',
        style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold)));
    out.add(pw.SizedBox(height: 6));
    out.add(pw.TableHelper.fromTextArray(
      headers: const ['Student', 'Stop', 'Distance', 'When', 'Outcome'],
      data: _detailAlerts.isEmpty
          ? [
              ['No geofence alerts were raised on this trip', '', '', '', '']
            ]
          : [
              for (final a in _detailAlerts)
                [
                  (a['studentName'] ?? a['studentId'] ?? '--').toString(),
                  (a['stopIndex'] is int && (a['stopIndex'] as int) < stops.length)
                      ? (stops[a['stopIndex'] as int]['name'] ??
                              'Stop ${(a['stopIndex'] as int) + 1}')
                          .toString()
                      : '--',
                  a['distance'] is num ? '${(a['distance'] as num).round()} m' : '--',
                  _alertWhen(a['createdAt']),
                  (a['status'] ?? 'pending').toString().replaceAll('_', ' '),
                ],
            ],
      cellStyle: const pw.TextStyle(fontSize: 8.5),
      headerStyle: pw.TextStyle(
          fontWeight: pw.FontWeight.bold, color: PdfColors.white, fontSize: 8.5),
      headerDecoration: const pw.BoxDecoration(color: PdfColors.red700),
      oddRowDecoration: const pw.BoxDecoration(color: PdfColors.grey100),
      columnWidths: {
        0: const pw.FlexColumnWidth(3),
        1: const pw.FlexColumnWidth(2.6),
        2: const pw.FlexColumnWidth(1.3),
        3: const pw.FlexColumnWidth(2),
        4: const pw.FlexColumnWidth(1.8),
      },
    ));

    return out;
  }

  String _alertWhen(dynamic ts) {
    if (ts is! Timestamp) return '--';
    final t = ts.toDate();
    final hh = t.hour.toString().padLeft(2, '0');
    final mm = t.minute.toString().padLeft(2, '0');
    return '${_monthNames[t.month - 1]} ${t.day}, $hh:$mm';
  }

  List<pw.Widget> _buildAttendancePdf(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> trips) {
    final rows = <List<String>>[];
    for (final doc in trips) {
      final d = doc.data();
      final buses = asList(d['buses']);
      for (int bi = 0; bi < buses.length; bi++) {
        final bus = buses[bi];
        final passengers = asList(bus['passengers']);
        int present = 0;
        int manual = 0;
        for (final p in passengers) {
          final att = (p['attendance'] as Map?) ?? {};
          if (!att.values.any((v) => v == true)) continue;
          present++;
          // A facilitator's judgement call is not the same evidence as a
          // verified scan, so the report says which it was rather than
          // presenting one total that hides the difference.
          final meta = (p['attendanceMeta'] as Map?) ?? {};
          final markedByHand = att.entries.any((e) {
            if (e.value != true) return false;
            final m = meta[e.key];
            return m is Map && m['source'] == 'manual';
          });
          if (markedByHand) manual++;
        }
        final pct = passengers.isEmpty ? '--' : '${(present / passengers.length * 100).round()}%';
        rows.add([
          d['title'] ?? 'Untitled',
          d['date'] ?? '',
          'Bus ${bus['busLabel'] ?? bus['busNo'] ?? (bi + 1)}',
          '${passengers.length}',
          '$present',
          '${present - manual}',
          '$manual',
          pct,
        ]);
      }
    }
    return [
      pw.TableHelper.fromTextArray(
        headers: ['Trip Name', 'Date', 'Bus', 'Total', 'Present', 'Scanned', 'Manual', 'Rate'],
        data: rows,
        headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white),
        headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey700),
        oddRowDecoration: const pw.BoxDecoration(color: PdfColors.grey100),
        columnWidths: {
          0: const pw.FlexColumnWidth(3),
          1: const pw.FlexColumnWidth(2),
          2: const pw.FlexColumnWidth(2),
          3: const pw.FlexColumnWidth(1),
          4: const pw.FlexColumnWidth(1),
          5: const pw.FlexColumnWidth(1),
          6: const pw.FlexColumnWidth(1),
          7: const pw.FlexColumnWidth(1),
        },
      ),
      pw.SizedBox(height: 10),
      pw.Text(
        'Scanned: verified by QR against the destination geofence. '
        'Manual: recorded by a facilitator who confirmed the student was present, '
        'with the reason kept in the activity log.',
        style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
      ),
    ];
  }

  List<pw.Widget> _buildMonthlyPdf(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> trips) {
    final Map<String, int> counts = {};
    for (final doc in trips) {
      final d = doc.data();
      DateTime? dt;
      final dateStr = d['date'] as String?;
      if (dateStr != null) dt = DateTime.tryParse(dateStr) ?? _parseSlashDate(dateStr);
      dt ??= (d['createdAt'] as Timestamp?)?.toDate();
      if (dt == null) continue;
      final key = '${_monthNames[dt.month - 1]} ${dt.year}';
      counts[key] = (counts[key] ?? 0) + 1;
    }
    final rows = counts.entries.map((e) => [e.key, '${e.value}']).toList();
    return [
      pw.TableHelper.fromTextArray(
        headers: ['Month', 'Trips'],
        data: rows,
        headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.white),
        headerDecoration: const pw.BoxDecoration(color: PdfColors.blueGrey700),
        oddRowDecoration: const pw.BoxDecoration(color: PdfColors.grey100),
        columnWidths: {0: const pw.FlexColumnWidth(3), 1: const pw.FlexColumnWidth(1)},
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: TripQueries.ofMySchool(),
      builder: (context, tripSnap) {
        if (!tripSnap.hasData) {
          return Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary));
        }
        // Sorted client-side — orderBy plus the schoolId filter would need a
        // composite index.
        final allTrips = TripQueries.newestFirst(tripSnap.data!.docs);
        final trips = _filterTrips(allTrips);

        return SingleChildScrollView(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // â"€â"€ Controls row â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 12, offset: const Offset(0, 4))],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Report type chips
                    SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: _ReportType.values.map((type) {
                          final selected = _reportType == type;
                          final label = switch (type) {
                            _ReportType.tripSummary => 'Trip Summary',
                            _ReportType.tripDetail => 'Trip Detail',
                            _ReportType.attendance => 'Attendance',
                            _ReportType.monthlyActivity => 'Monthly Activity',
                          };
                          final icon = switch (type) {
                            _ReportType.tripSummary => Icons.summarize_rounded,
                            _ReportType.tripDetail => Icons.fact_check_outlined,
                            _ReportType.attendance => Icons.how_to_reg_rounded,
                            _ReportType.monthlyActivity => Icons.bar_chart_rounded,
                          };
                          return Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: FilterChip(
                              avatar: Icon(icon, size: 14,
                                  color: selected ? Colors.white : AppTheme.effectivePrimary),
                              label: Text(label),
                              selected: selected,
                              onSelected: (_) => setState(() => _reportType = type),
                              selectedColor: AppTheme.effectivePrimary,
                              labelStyle: TextStyle(
                                  color: selected ? Colors.white : AppTheme.secondaryColor,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 12),
                              checkmarkColor: Colors.white,
                              showCheckmark: false,
                              backgroundColor: AppTheme.effectivePrimary.withValues(alpha: 0.07),
                              side: BorderSide(
                                  color: selected ? AppTheme.effectivePrimary : Colors.transparent),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                    const SizedBox(height: 14),
                    // Search by trip title. Narrows the same list the date
                    // range does, so the two combine rather than compete.
                    TextField(
                      controller: _searchCtrl,
                      onChanged: (v) => setState(() => _search = v),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: 'Search trip title',
                        prefixIcon: const Icon(Icons.search_rounded, size: 19),
                        suffixIcon: _search.isEmpty
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.close_rounded, size: 17),
                                tooltip: 'Clear search',
                                onPressed: () {
                                  _searchCtrl.clear();
                                  setState(() => _search = '');
                                },
                              ),
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(10)),
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Date range row
                    Row(
                      children: [
                        Icon(Icons.date_range_rounded, size: 16, color: AppTheme.effectivePrimary),
                        const SizedBox(width: 8),
                        Expanded(
                          child: InkWell(
                            onTap: () => _pickDate(isFrom: true),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey.shade300),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                _fromDate == null
                                    ? 'From date'
                                    : '${_fromDate!.month}/${_fromDate!.day}/${_fromDate!.year}',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: _fromDate == null ? Colors.grey.shade400 : AppTheme.secondaryColor),
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text('->', style: TextStyle(color: Colors.grey.shade500)),
                        ),
                        Expanded(
                          child: InkWell(
                            onTap: () => _pickDate(isFrom: false),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.grey.shade300),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                _toDate == null
                                    ? 'To date'
                                    : '${_toDate!.month}/${_toDate!.day}/${_toDate!.year}',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: _toDate == null ? Colors.grey.shade400 : AppTheme.secondaryColor),
                              ),
                            ),
                          ),
                        ),
                        if (_fromDate != null || _toDate != null) ...[
                          const SizedBox(width: 8),
                          InkWell(
                            onTap: () => setState(() { _fromDate = null; _toDate = null; }),
                            borderRadius: BorderRadius.circular(20),
                            child: Icon(Icons.close_rounded, size: 18, color: Colors.grey),
                          ),
                        ],
                        const SizedBox(width: 12),
                        ElevatedButton.icon(
                          onPressed: _exporting ? null : () => _exportPdf(trips),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.effectivePrimary,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            elevation: 0,
                          ),
                          icon: _exporting
                              ? const SizedBox(
                                  width: 14, height: 14,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                              : const Icon(Icons.picture_as_pdf_rounded, size: 16),
                          label: const Text('Export PDF', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                        ),
                      ],
                    ),
                    if (_fromDate != null || _toDate != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          'Showing ${trips.length} of ${allTrips.length} trips Â· $_dateRangeLabel',
                          style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              // â"€â"€ Report content â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€
              _buildReportContent(trips),
              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }

  Widget _buildReportContent(
      List<QueryDocumentSnapshot<Map<String, dynamic>>> trips) {
    switch (_reportType) {
      case _ReportType.tripSummary:
        return _TripSummaryReport(trips: trips);
      case _ReportType.tripDetail:
        return _TripDetailReport(
          trips: trips,
          selectedId: _selectedTripId,
          onSelect: (id) => setState(() => _selectedTripId = id),
        );
      case _ReportType.attendance:
        return _AttendanceReport(trips: trips);
      case _ReportType.monthlyActivity:
        return _MonthlyActivityReport(trips: trips, monthNames: _monthNames);
    }
  }
}

// â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€
// Report content widgets
// â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€

class _TripSummaryReport extends StatelessWidget {
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> trips;
  const _TripSummaryReport({required this.trips});

  @override
  Widget build(BuildContext context) {
    final total = trips.length;
    final completed = trips.where((d) => d.data()['status'] == 'completed').length;
    final ongoing = trips.where((d) => d.data()['status'] == 'in_progress').length;
    final pending = trips.where((d) => d.data()['status'] == 'pending').length;
    int buses = 0, students = 0, attendance = 0;
    for (final doc in trips) {
      for (final bus in asList(doc.data()['buses'])) {
        buses++;
        for (final p in asList(bus['passengers'])) {
          students++;
          final att = (p['attendance'] as Map?) ?? {};
          attendance += att.values.where((v) => v == true).length;
        }
      }
    }

    return Column(
      children: [
        Wrap(
          spacing: 16,
          runSpacing: 16,
          children: [
            _StatCard(label: 'Total Trips', value: '$total', icon: Icons.map_rounded, color: AppTheme.effectivePrimary),
            _StatCard(label: 'Completed', value: '$completed', icon: Icons.check_circle_rounded, color: Colors.green),
            _StatCard(label: 'Ongoing', value: '$ongoing', icon: Icons.directions_bus_rounded, color: Colors.orange),
            _StatCard(label: 'Pending', value: '$pending', icon: Icons.hourglass_empty_rounded, color: Colors.blueGrey),
            _StatCard(label: 'Buses Used', value: '$buses', icon: Icons.airport_shuttle_rounded, color: AppTheme.secondaryColor),
            _StatCard(label: 'Student Slots', value: '$students', icon: Icons.people_rounded, color: Colors.purple),
            _StatCard(label: 'Attendance Marks', value: '$attendance', icon: Icons.how_to_reg_rounded, color: Colors.teal),
          ],
        ),
        const SizedBox(height: 20),
        // Status breakdown
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _CardTitle('Trip Status Breakdown'),
              const SizedBox(height: 16),
              if (total == 0)
                const Center(child: Text('No trips in this range.'))
              else ...[
                _StatusBar(label: 'Completed', count: completed, total: total, color: Colors.green),
                const SizedBox(height: 10),
                _StatusBar(label: 'Ongoing', count: ongoing, total: total, color: Colors.orange),
                const SizedBox(height: 10),
                _StatusBar(label: 'Pending', count: pending, total: total, color: Colors.blueGrey),
              ],
            ],
          ),
        ),
        const SizedBox(height: 20),
        // Trip list
        _Card(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const _CardTitle('Trips'),
                  Text('${trips.length} total', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                ],
              ),
              const SizedBox(height: 12),
              if (trips.isEmpty)
                const Center(child: Text('No trips in this range.'))
              else
                ...trips.map((doc) {
                  final d = doc.data();
                  final status = (d['status'] ?? 'pending').toString();
                  final Color sc = status == 'completed'
                      ? Colors.green
                      : status == 'in_progress'
                          ? Colors.orange
                          : Colors.blueGrey;
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      children: [
                        Container(width: 8, height: 8,
                            decoration: BoxDecoration(color: sc, shape: BoxShape.circle)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(d['title'] ?? 'Untitled',
                              style: const TextStyle(fontWeight: FontWeight.w500, color: AppTheme.secondaryColor),
                              overflow: TextOverflow.ellipsis),
                        ),
                        Text(d['date'] ?? '', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                              color: sc.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(20)),
                          child: Text(
                            status == 'in_progress' ? 'Ongoing' : status[0].toUpperCase() + status.substring(1),
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: sc),
                          ),
                        ),
                      ],
                    ),
                  );
                }),
            ],
          ),
        ),
      ],
    );
  }
}

class _AttendanceReport extends StatelessWidget {
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> trips;
  const _AttendanceReport({required this.trips});

  @override
  Widget build(BuildContext context) {
    final rows = <_AttendanceRow>[];
    for (final doc in trips) {
      final d = doc.data();
      final buses = asList(d['buses']);
      for (int bi = 0; bi < buses.length; bi++) {
        final bus = buses[bi];
        final passengers = asList(bus['passengers']);
        int present = 0;
        int manual = 0;
        for (final p in passengers) {
          final att = (p['attendance'] as Map?) ?? {};
          if (!att.values.any((v) => v == true)) continue;
          present++;
          final meta = (p['attendanceMeta'] as Map?) ?? {};
          final markedByHand = att.entries.any((e) {
            if (e.value != true) return false;
            final m = meta[e.key];
            return m is Map && m['source'] == 'manual';
          });
          if (markedByHand) manual++;
        }
        rows.add(_AttendanceRow(
          tripName: d['title'] ?? 'Untitled',
          date: d['date'] ?? '',
          bus: 'Bus ${bus['busLabel'] ?? bus['busNo'] ?? (bi + 1)}',
          total: passengers.length,
          present: present,
          manual: manual,
        ));
      }
    }

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const _CardTitle('Attendance Report'),
              Text('${rows.length} bus(es)', style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
            ],
          ),
          const SizedBox(height: 12),
          if (rows.isEmpty)
            const Center(child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('No data in this range.'),
            ))
          else ...[
            Container(
              decoration: BoxDecoration(
                border: Border.all(color: Colors.grey.shade200),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: AppTheme.effectivePrimary.withValues(alpha: 0.07),
                      borderRadius: const BorderRadius.vertical(top: Radius.circular(10)),
                    ),
                    child: Row(
                      children: const [
                        Expanded(flex: 3, child: Text('Trip', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppTheme.secondaryColor))),
                        SizedBox(width: 8),
                        Expanded(flex: 2, child: Text('Date', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppTheme.secondaryColor))),
                        Expanded(flex: 2, child: Text('Bus', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppTheme.secondaryColor))),
                        SizedBox(width: 8),
                        SizedBox(width: 48, child: Text('Present', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppTheme.secondaryColor))),
                        SizedBox(width: 4),
                        SizedBox(width: 52, child: Text('Manual', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppTheme.secondaryColor))),
                        SizedBox(width: 4),
                        SizedBox(width: 48, child: Text('Rate', textAlign: TextAlign.center, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12, color: AppTheme.secondaryColor))),
                      ],
                    ),
                  ),
                  ...rows.asMap().entries.map((e) {
                    final i = e.key;
                    final row = e.value;
                    final pct = row.total == 0 ? 0.0 : row.present / row.total;
                    final color = pct >= 0.9 ? Colors.green : pct >= 0.7 ? Colors.orange : Colors.red;
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                      color: i.isEven ? Colors.grey.shade50 : Colors.white,
                      child: Row(
                        children: [
                          Expanded(flex: 3, child: Text(row.tripName, style: const TextStyle(fontSize: 12, color: AppTheme.secondaryColor), overflow: TextOverflow.ellipsis)),
                          const SizedBox(width: 8),
                          Expanded(flex: 2, child: Text(row.date, style: TextStyle(fontSize: 11, color: Colors.grey.shade600))),
                          Expanded(flex: 2, child: Text(row.bus, style: TextStyle(fontSize: 11, color: Colors.grey.shade600))),
                          const SizedBox(width: 8),
                          SizedBox(
                            width: 48,
                            child: Text('${row.present}/${row.total}',
                                textAlign: TextAlign.center,
                                style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppTheme.secondaryColor)),
                          ),
                          const SizedBox(width: 4),
                          SizedBox(
                            width: 52,
                            child: row.manual == 0
                                ? Text('--',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(fontSize: 12, color: Colors.grey.shade400))
                                : Text('${row.manual}',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.orange.shade700)),
                          ),
                          const SizedBox(width: 4),
                          SizedBox(
                            width: 48,
                            child: Text(
                              row.total == 0 ? '--' : '${(pct * 100).round()}%',
                              textAlign: TextAlign.center,
                              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Manual counts students a facilitator confirmed in person when their '
              'code could not be verified. The reason for each is in Activity Logs.',
              style: TextStyle(fontSize: 11, height: 1.45, color: Colors.grey.shade600),
            ),
          ],
        ],
      ),
    );
  }
}

class _AttendanceRow {
  final String tripName, date, bus;
  final int total, present;

  /// How many of [present] were recorded by a facilitator rather than verified
  /// by a scan. Kept separate because they are different kinds of evidence.
  final int manual;

  const _AttendanceRow({
    required this.tripName,
    required this.date,
    required this.bus,
    required this.total,
    required this.present,
    this.manual = 0,
  });
}

class _MonthlyActivityReport extends StatelessWidget {
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> trips;
  final List<String> monthNames;
  const _MonthlyActivityReport({required this.trips, required this.monthNames});

  DateTime? _parseDate(String s) {
    if (s.isEmpty) return null;
    final dt = DateTime.tryParse(s);
    if (dt != null) return dt;
    final parts = s.split('/');
    if (parts.length == 3) {
      final m = int.tryParse(parts[0]);
      final d = int.tryParse(parts[1]);
      final y = int.tryParse(parts[2]);
      if (m != null && d != null && y != null) return DateTime(y, m, d);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final Map<String, int> counts = {};
    for (final doc in trips) {
      final d = doc.data();
      DateTime? dt;
      final dateStr = d['date'] as String?;
      if (dateStr != null) dt = _parseDate(dateStr);
      dt ??= (d['createdAt'] as Timestamp?)?.toDate();
      if (dt == null) continue;
      final key = '${monthNames[dt.month - 1]} ${dt.year}';
      counts[key] = (counts[key] ?? 0) + 1;
    }

    final maxCount = counts.values.fold(0, (a, b) => a > b ? a : b);

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _CardTitle('Monthly Activity'),
          const SizedBox(height: 20),
          if (counts.isEmpty)
            const Center(child: Padding(
              padding: EdgeInsets.all(24),
              child: Text('No data in this range.'),
            ))
          else ...[
            SizedBox(
              height: 200,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: counts.entries.map((e) {
                  final barH = maxCount == 0 ? 0.0 : (e.value / maxCount) * 150.0;
                  return Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (e.value > 0)
                        Text('${e.value}',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppTheme.effectivePrimary)),
                      const SizedBox(height: 4),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 400),
                        width: 40,
                        height: barH == 0 ? 4 : barH,
                        decoration: BoxDecoration(
                          color: barH == 0
                              ? Colors.grey.shade200
                              : AppTheme.effectivePrimary.withValues(alpha: 0.75),
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(e.key, style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
                    ],
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 20),
            const Divider(),
            const SizedBox(height: 12),
            ...counts.entries.map((e) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 100,
                    child: Text(e.key, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppTheme.secondaryColor)),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: LinearProgressIndicator(
                        value: maxCount == 0 ? 0 : e.value / maxCount,
                        minHeight: 10,
                        backgroundColor: Colors.grey.shade100,
                        valueColor: AlwaysStoppedAnimation(AppTheme.effectivePrimary),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  SizedBox(
                    width: 30,
                    child: Text('${e.value}',
                        textAlign: TextAlign.end,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: AppTheme.effectivePrimary)),
                  ),
                ],
              ),
            )),
          ],
        ],
      ),
    );
  }
}

// â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€
// Helper widgets
// â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€â"€

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: child,
    );
  }
}

class _CardTitle extends StatelessWidget {
  final String text;
  const _CardTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(text, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15, color: AppTheme.secondaryColor));
  }
}

class _StatCard extends StatelessWidget {
  final String label, value;
  final IconData icon;
  final Color color;
  const _StatCard({required this.label, required this.value, required this.icon, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 160,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(height: 12),
          Text(value, style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: color)),
          const SizedBox(height: 4),
          Text(label, style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }
}

class _StatusBar extends StatelessWidget {
  final String label;
  final int count, total;
  final Color color;
  const _StatusBar({required this.label, required this.count, required this.total, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(label, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: Colors.grey.shade700)),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: total == 0 ? 0 : count / total,
              minHeight: 10,
              backgroundColor: Colors.grey.shade100,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 40,
          child: Text('$count', textAlign: TextAlign.end,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
        ),
      ],
    );
  }
}

/// Picks one trip, then shows what happened on it.
///
/// A detail report is about a single day, so this screen asks which one before
/// it shows anything. Once a trip is chosen it previews the same three things
/// the PDF carries — attendance by name, the facilitator's manual entries, and
/// who left the zone — so an administrator can check the report is the one
/// they meant before exporting it.
class _TripDetailReport extends StatelessWidget {
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> trips;
  final String? selectedId;
  final ValueChanged<String?> onSelect;

  const _TripDetailReport({
    required this.trips,
    required this.selectedId,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    if (trips.isEmpty) {
      return _emptyCard(
        Icons.search_off_rounded,
        'No trips match',
        'Widen the date range, or clear the search.',
      );
    }

    final selected = selectedId == null
        ? null
        : trips.where((t) => t.id == selectedId).firstOrNull;

    if (selected == null) {
      return Container(
        padding: const EdgeInsets.all(18),
        decoration: _cardBox,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Choose a trip',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text('${trips.length} trip${trips.length == 1 ? '' : 's'} to choose from',
                style: TextStyle(fontSize: 12.5, color: Colors.grey.shade500)),
            const Divider(height: 22),
            for (final t in trips.take(40)) _tripRow(t),
          ],
        ),
      );
    }

    return _TripDetailBody(doc: selected, onChange: () => onSelect(null));
  }

  Widget _tripRow(QueryDocumentSnapshot<Map<String, dynamic>> t) {
    final d = t.data();
    final buses = asList(d['buses']);
    int students = 0;
    for (final b in buses) {
      students += asList(b['passengers']).length;
    }
    return InkWell(
      onTap: () => onSelect(t.id),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.route_rounded,
                  size: 18, color: AppTheme.effectivePrimary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text((d['title'] ?? 'Untitled').toString(),
                      style: const TextStyle(
                          fontWeight: FontWeight.w600, fontSize: 14)),
                  Text(
                    '${d['date'] ?? 'no date'} · $students student${students == 1 ? '' : 's'} · '
                    '${(d['status'] ?? 'pending').toString().replaceAll('_', ' ')}',
                    style: TextStyle(fontSize: 12.5, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: Colors.grey.shade400),
          ],
        ),
      ),
    );
  }

  static final _cardBox = BoxDecoration(
    color: Colors.white,
    borderRadius: BorderRadius.circular(16),
    boxShadow: [
      BoxShadow(
          color: Colors.black.withValues(alpha: 0.04),
          blurRadius: 12,
          offset: const Offset(0, 4))
    ],
  );

  Widget _emptyCard(IconData icon, String title, String detail) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 46, horizontal: 20),
      decoration: _cardBox,
      child: Column(
        children: [
          Icon(icon, size: 42, color: Colors.grey.shade300),
          const SizedBox(height: 12),
          Text(title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text(detail,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: Colors.grey.shade500)),
        ],
      ),
    );
  }
}

/// The chosen trip, on screen.
class _TripDetailBody extends StatelessWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  final VoidCallback onChange;

  const _TripDetailBody({required this.doc, required this.onChange});

  @override
  Widget build(BuildContext context) {
    final d = doc.data();
    final stops = asList(d['stops']);
    final buses = asList(d['buses']);

    int total = 0;
    int scanned = 0;
    int manual = 0;
    final overrides = <List<String>>[];

    for (int bi = 0; bi < buses.length; bi++) {
      final bus = buses[bi];
      for (final p in asList(bus['passengers'])) {
        total++;
        final att = (p['attendance'] as Map?) ?? {};
        final meta = (p['attendanceMeta'] as Map?) ?? {};
        for (int i = 0; i < stops.length; i++) {
          final key = 'stop_$i';
          if (att[key] != true) continue;
          final m = meta[key];
          if (m is Map && m['source'] == 'manual') {
            manual++;
            overrides.add([
              (p['name'] ?? 'Student').toString(),
              (stops[i]['name'] ?? 'Stop ${i + 1}').toString(),
              (m['reason'] ?? '--').toString(),
            ]);
          } else {
            scanned++;
          }
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(18),
          decoration: _TripDetailReport._cardBox,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text((d['title'] ?? 'Untitled').toString(),
                            style: const TextStyle(
                                fontSize: 18, fontWeight: FontWeight.bold)),
                        Text(
                          '${d['date'] ?? 'no date'} · '
                          '${(d['status'] ?? 'pending').toString().replaceAll('_', ' ')} · '
                          '${buses.length} bus${buses.length == 1 ? '' : 'es'} · '
                          '${stops.length} stop${stops.length == 1 ? '' : 's'}',
                          style: TextStyle(
                              fontSize: 12.5, color: Colors.grey.shade500),
                        ),
                      ],
                    ),
                  ),
                  TextButton.icon(
                    onPressed: onChange,
                    icon: const Icon(Icons.swap_horiz_rounded, size: 17),
                    label: const Text('Change trip'),
                  ),
                ],
              ),
              const Divider(height: 24),
              Wrap(
                spacing: 28,
                runSpacing: 14,
                children: [
                  _stat('Students', '$total'),
                  _stat('Verified scans', '$scanned'),
                  _stat('Manual entries', '$manual',
                      tone: manual > 0 ? const Color(0xFFB26A00) : null),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (overrides.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(18),
            decoration: _TripDetailReport._cardBox,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Recorded by a facilitator',
                    style:
                        TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                const SizedBox(height: 2),
                Text(
                  'Each of these was vouched for because the device could not be verified.',
                  style: TextStyle(fontSize: 12.5, color: Colors.grey.shade500),
                ),
                const Divider(height: 20),
                for (final o in overrides)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.edit_note_rounded,
                            size: 17, color: Color(0xFFB26A00)),
                        const SizedBox(width: 9),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${o[0]} · ${o[1]}',
                                  style: const TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600)),
                              Text(o[2],
                                  style: TextStyle(
                                      fontSize: 12.5,
                                      color: Colors.grey.shade600)),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        const SizedBox(height: 16),
        _GeofenceBreaches(tripId: doc.id, stops: stops),
      ],
    );
  }

  Widget _stat(String label, String value, {Color? tone}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value,
            style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: tone ?? AppTheme.darkText)),
        Text(label,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
      ],
    );
  }
}

/// Geofence alerts live in a sub-collection, so they are read on their own.
class _GeofenceBreaches extends StatelessWidget {
  final String tripId;
  final List<dynamic> stops;

  const _GeofenceBreaches({required this.tripId, required this.stops});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('trips')
          .doc(tripId)
          .collection('alerts')
          .snapshots(),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? const [];
        return Container(
          padding: const EdgeInsets.all(18),
          decoration: _TripDetailReport._cardBox,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Left the designated area',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
              const Divider(height: 20),
              if (docs.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text('Nobody left the zone on this trip.',
                      style:
                          TextStyle(fontSize: 13, color: Colors.grey.shade500)),
                )
              else
                for (final a in docs) _row(a.data()),
            ],
          ),
        );
      },
    );
  }

  Widget _row(Map<String, dynamic> a) {
    final idx = a['stopIndex'];
    final stopName = (idx is int && idx < stops.length)
        ? (stops[idx]['name'] ?? 'Stop ${idx + 1}').toString()
        : '--';
    final dist = a['distance'] is num ? '${(a['distance'] as num).round()} m' : '--';
    final status = (a['status'] ?? 'pending').toString();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.location_off_rounded,
              size: 17, color: Colors.red.shade400),
          const SizedBox(width: 9),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text((a['studentName'] ?? a['studentId'] ?? 'Student').toString(),
                    style: const TextStyle(
                        fontSize: 13.5, fontWeight: FontWeight.w600)),
                Text('$stopName · $dist away · ${status.replaceAll('_', ' ')}',
                    style:
                        TextStyle(fontSize: 12.5, color: Colors.grey.shade600)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
