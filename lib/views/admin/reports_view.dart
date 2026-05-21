import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../config/theme.dart';
import '../../utils/firestore_utils.dart';

/// Admin Reports View — shows aggregated statistics for trips, students and
/// attendance derived from Firestore in real-time.
class ReportsView extends StatelessWidget {
  const ReportsView({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('trips')
          .orderBy('createdAt', descending: true)
          .snapshots(),
      builder: (context, tripSnap) {
        if (!tripSnap.hasData) {
          return const Center(
              child: CircularProgressIndicator(color: AppTheme.primaryColor));
        }
        final trips = tripSnap.data!.docs;

        // ── Aggregate stats ──────────────────────────────────────────────────
        final int totalTrips = trips.length;
        final int completedTrips =
            trips.where((d) => d.data()['status'] == 'completed').length;
        final int ongoingTrips =
            trips.where((d) => d.data()['status'] == 'in_progress').length;
        final int pendingTrips =
            trips.where((d) => d.data()['status'] == 'pending').length;

        int totalStudents = 0;
        int totalBuses = 0;
        int totalAttendance = 0;

        for (final doc in trips) {
          final data = doc.data();
          final buses = asList(data['buses']);
          totalBuses += buses.length;
          for (final bus in buses) {
            final passengers = asList(bus['passengers']);
            totalStudents += passengers.length;
            // Count attendance marks across all stops
            for (final passenger in passengers) {
              final att = (passenger['attendance'] as Map?) ?? {};
              totalAttendance +=
                  att.values.where((v) => v == true).length as int;
            }
          }
        }

        // ── Per-month trip count (last 6 months) ────────────────────────────
        final now = DateTime.now();
        final List<_MonthStat> monthStats = List.generate(6, (i) {
          final month = DateTime(now.year, now.month - (5 - i));
          final count = trips.where((d) {
            final ts = d.data()['createdAt'] as Timestamp?;
            if (ts == null) return false;
            final dt = ts.toDate();
            return dt.year == month.year && dt.month == month.month;
          }).length;
          return _MonthStat(month: month, count: count);
        });

        final maxMonthCount =
            monthStats.map((s) => s.count).fold(0, (a, b) => a > b ? a : b);

        return SingleChildScrollView(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // ── Summary stat cards ────────────────────────────────────────
              Wrap(
                spacing: 16,
                runSpacing: 16,
                children: [
                  _StatCard(
                    label: 'Total Trips',
                    value: '$totalTrips',
                    icon: Icons.map_rounded,
                    color: AppTheme.primaryColor,
                  ),
                  _StatCard(
                    label: 'Completed',
                    value: '$completedTrips',
                    icon: Icons.check_circle_rounded,
                    color: Colors.green,
                  ),
                  _StatCard(
                    label: 'Ongoing',
                    value: '$ongoingTrips',
                    icon: Icons.directions_bus_rounded,
                    color: Colors.orange,
                  ),
                  _StatCard(
                    label: 'Pending',
                    value: '$pendingTrips',
                    icon: Icons.hourglass_empty_rounded,
                    color: Colors.blueGrey,
                  ),
                  _StatCard(
                    label: 'Total Buses Used',
                    value: '$totalBuses',
                    icon: Icons.airport_shuttle_rounded,
                    color: AppTheme.secondaryColor,
                  ),
                  _StatCard(
                    label: 'Student Slots',
                    value: '$totalStudents',
                    icon: Icons.people_rounded,
                    color: Colors.purple,
                  ),
                  _StatCard(
                    label: 'Attendance Marks',
                    value: '$totalAttendance',
                    icon: Icons.how_to_reg_rounded,
                    color: Colors.teal,
                  ),
                ],
              ),

              const SizedBox(height: 28),

              // ── Monthly trips bar chart ───────────────────────────────────
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Trips per Month (last 6 months)',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: AppTheme.secondaryColor,
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      height: 180,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: monthStats.map((stat) {
                          final barHeight = maxMonthCount == 0
                              ? 0.0
                              : (stat.count / maxMonthCount) * 140.0;
                          return _BarColumn(stat: stat, barHeight: barHeight);
                        }).toList(),
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 28),

              // ── Status breakdown ─────────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Trip Status Breakdown',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: AppTheme.secondaryColor,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (totalTrips == 0)
                      const Center(child: Text('No trips yet.'))
                    else ...[
                      _StatusBar(
                          label: 'Completed',
                          count: completedTrips,
                          total: totalTrips,
                          color: Colors.green),
                      const SizedBox(height: 10),
                      _StatusBar(
                          label: 'Ongoing',
                          count: ongoingTrips,
                          total: totalTrips,
                          color: Colors.orange),
                      const SizedBox(height: 10),
                      _StatusBar(
                          label: 'Pending',
                          count: pendingTrips,
                          total: totalTrips,
                          color: Colors.blueGrey),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 28),

              // ── Recent trips list ─────────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Recent Trips',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: AppTheme.secondaryColor,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...trips.take(10).map((doc) {
                      final data = doc.data();
                      final String title = data['title'] ?? 'Untitled';
                      final String date = data['date'] ?? '';
                      final String status =
                          (data['status'] ?? 'pending').toString();
                      final Color statusColor = status == 'completed'
                          ? Colors.green
                          : status == 'in_progress'
                              ? Colors.orange
                              : Colors.blueGrey;

                      return Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                  color: statusColor, shape: BoxShape.circle),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                title,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w500,
                                  color: AppTheme.secondaryColor,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              date,
                              style: TextStyle(
                                  fontSize: 12, color: Colors.grey.shade500),
                            ),
                            const SizedBox(width: 10),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: statusColor.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                status == 'in_progress'
                                    ? 'Ongoing'
                                    : status[0].toUpperCase() +
                                        status.substring(1),
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  color: statusColor,
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }),
                  ],
                ),
              ),

              const SizedBox(height: 16),
            ],
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper widgets
// ─────────────────────────────────────────────────────────────────────────────

class _MonthStat {
  final DateTime month;
  final int count;
  const _MonthStat({required this.month, required this.count});
}

class _StatCard extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  const _StatCard({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 160,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 20),
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              color: Colors.grey.shade600,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }
}

class _BarColumn extends StatelessWidget {
  final _MonthStat stat;
  final double barHeight;

  const _BarColumn({required this.stat, required this.barHeight});

  static const _monthNames = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        if (stat.count > 0)
          Text(
            '${stat.count}',
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: AppTheme.primaryColor,
            ),
          ),
        const SizedBox(height: 4),
        AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          width: 36,
          height: barHeight == 0 ? 4 : barHeight,
          decoration: BoxDecoration(
            color: barHeight == 0
                ? Colors.grey.shade200
                : AppTheme.primaryColor.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(6),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          _monthNames[stat.month.month - 1],
          style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
        ),
      ],
    );
  }
}

class _StatusBar extends StatelessWidget {
  final String label;
  final int count;
  final int total;
  final Color color;

  const _StatusBar({
    required this.label,
    required this.count,
    required this.total,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final fraction = total == 0 ? 0.0 : count / total;
    return Row(
      children: [
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Colors.grey.shade700,
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: LinearProgressIndicator(
              value: fraction,
              minHeight: 10,
              backgroundColor: Colors.grey.shade100,
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 40,
          child: Text(
            '$count',
            textAlign: TextAlign.end,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ),
      ],
    );
  }
}
