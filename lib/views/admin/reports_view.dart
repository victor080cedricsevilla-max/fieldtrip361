import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import '../../config/theme.dart';
import '../../utils/firestore_utils.dart';
import '../../utils/trip_queries.dart';

enum _ReportType { tripSummary, attendance, monthlyActivity }

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
    if (_fromDate == null && _toDate == null) return trips;
    return trips.where((doc) {
      final data = doc.data();
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
      final doc = pw.Document();
      final title = _reportType == _ReportType.tripSummary
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
                          final label = type == _ReportType.tripSummary
                              ? 'Trip Summary'
                              : type == _ReportType.attendance
                                  ? 'Attendance'
                                  : 'Monthly Activity';
                          final icon = type == _ReportType.tripSummary
                              ? Icons.summarize_rounded
                              : type == _ReportType.attendance
                                  ? Icons.how_to_reg_rounded
                                  : Icons.bar_chart_rounded;
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
