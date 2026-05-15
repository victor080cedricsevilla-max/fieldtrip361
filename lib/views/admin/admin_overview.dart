import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../config/theme.dart';

/// Admin dashboard landing page.
/// Layout (analytics-style, follows the system color theme):
///   - top row: 4 KPI cards (Total Trips, Active, Completed, Total Users)
///   - middle row: bar chart (trips per day, last 7 days) | donut (status breakdown)
///   - bottom row: line chart (new users last 7 days) | gauge (completed share)
///   - latest trips list
class AdminOverview extends StatelessWidget {
  const AdminOverview({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            "Here's what's going on with field trips right now",
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).brightness == Brightness.dark
                  ? Colors.grey.shade400
                  : Colors.grey.shade600,
            ),
          ),
          const SizedBox(height: 22),
          const _KpiRow(),
          const SizedBox(height: 22),
          // Middle row
          LayoutBuilder(
            builder: (ctx, c) {
              if (c.maxWidth < 900) {
                return Column(
                  children: const [
                    _TripsBarChartCard(),
                    SizedBox(height: 16),
                    _StatusDonutCard(),
                  ],
                );
              }
              return const IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 3, child: _TripsBarChartCard()),
                    SizedBox(width: 16),
                    Expanded(flex: 2, child: _StatusDonutCard()),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          // Bottom analytics row
          LayoutBuilder(
            builder: (ctx, c) {
              if (c.maxWidth < 900) {
                return Column(
                  children: const [
                    _UsersLineChartCard(),
                    SizedBox(height: 16),
                    _CompletedGaugeCard(),
                  ],
                );
              }
              return const IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 3, child: _UsersLineChartCard()),
                    SizedBox(width: 16),
                    Expanded(flex: 2, child: _CompletedGaugeCard()),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 22),
          const _LatestTripsCard(),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Generic card
// ─────────────────────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  const _Card({required this.child, this.padding = const EdgeInsets.all(20)});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      decoration: BoxDecoration(
        color: isDark ? AppTheme.darkSurface : Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.25 : 0.04),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      padding: padding,
      child: child,
    );
  }
}

Color _mutedText(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? Colors.grey.shade400
        : Colors.grey.shade600;

Color _strongText(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
        ? AppTheme.darkText2
        : AppTheme.secondaryColor;

// ─────────────────────────────────────────────────────────────────────────────
// KPI cards
// ─────────────────────────────────────────────────────────────────────────────

class _KpiRow extends StatelessWidget {
  const _KpiRow();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('trips').snapshots(),
      builder: (ctx, tripSnap) {
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance.collection('users').snapshots(),
          builder: (ctx2, userSnap) {
            final trips = tripSnap.data?.docs ?? const [];
            final users = userSnap.data?.docs ?? const [];

            int totalTrips = trips.length;
            int activeTrips = 0;
            int completedTrips = 0;
            int pendingTrips = 0;
            for (final t in trips) {
              final s = (t.data()['status'] ?? '').toString();
              if (s == 'in_progress') activeTrips++;
              else if (s == 'completed') completedTrips++;
              else pendingTrips++;
            }

            return LayoutBuilder(
              builder: (c, cons) {
                final double tileWidth =
                    cons.maxWidth >= 1100 ? (cons.maxWidth - 48) / 4 : double.infinity;
                final children = [
                  _KpiTile(
                    icon: Icons.directions_bus_filled_rounded,
                    label: "Total Trips",
                    value: totalTrips.toString(),
                    tone: AppTheme.primaryColor,
                  ),
                  _KpiTile(
                    icon: Icons.play_circle_outline_rounded,
                    label: "Active Trips",
                    value: activeTrips.toString(),
                    tone: Colors.green.shade600,
                  ),
                  _KpiTile(
                    icon: Icons.flag_circle_outlined,
                    label: "Completed Trips",
                    value: completedTrips.toString(),
                    tone: AppTheme.secondaryColor,
                  ),
                  _KpiTile(
                    icon: Icons.people_outline_rounded,
                    label: "Total Users",
                    value: users.length.toString(),
                    sub: "$pendingTrips pending trips",
                    tone: AppTheme.accentColor,
                  ),
                ];
                if (cons.maxWidth >= 1100) {
                  return Row(
                    children: [
                      for (int i = 0; i < children.length; i++) ...[
                        SizedBox(width: tileWidth, child: children[i]),
                        if (i < children.length - 1) const SizedBox(width: 16),
                      ],
                    ],
                  );
                }
                return Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: children
                      .map((w) => SizedBox(
                            width: cons.maxWidth >= 700
                                ? (cons.maxWidth - 16) / 2
                                : double.infinity,
                            child: w,
                          ))
                      .toList(),
                );
              },
            );
          },
        );
      },
    );
  }
}

class _KpiTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final String? sub;
  final Color tone;
  const _KpiTile({
    required this.icon,
    required this.label,
    required this.value,
    this.tone = AppTheme.primaryColor,
    this.sub,
  });

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Row(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: tone.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: tone, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(fontSize: 12, color: _mutedText(context)),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: _strongText(context),
                  ),
                ),
                if (sub != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    sub!,
                    style: TextStyle(fontSize: 11, color: _mutedText(context)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Trips per day — bar chart card
// ─────────────────────────────────────────────────────────────────────────────

class _TripsBarChartCard extends StatelessWidget {
  const _TripsBarChartCard();

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final sevenAgo = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 6));

    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardHeader(
            title: "Trips created",
            subtitle: "Last 7 days",
          ),
          const SizedBox(height: 18),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('trips')
                .where('createdAt',
                    isGreaterThanOrEqualTo: Timestamp.fromDate(sevenAgo))
                .snapshots(),
            builder: (ctx, snap) {
              final List<int> counts = List<int>.filled(7, 0);
              if (snap.hasData) {
                for (final d in snap.data!.docs) {
                  final ts = d.data()['createdAt'] as Timestamp?;
                  if (ts == null) continue;
                  final date = ts.toDate();
                  final day = DateTime(date.year, date.month, date.day);
                  final idx = day.difference(sevenAgo).inDays;
                  if (idx >= 0 && idx < 7) counts[idx]++;
                }
              }
              final labels = List<String>.generate(7, (i) {
                final d = sevenAgo.add(Duration(days: i));
                const dn = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
                return dn[d.weekday - 1];
              });
              final int total = counts.fold(0, (a, b) => a + b);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("$total total this week",
                      style: TextStyle(
                          fontSize: 13,
                          color: _mutedText(context),
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 16),
                  SizedBox(
                    height: 180,
                    child: CustomPaint(
                      painter: _BarChartPainter(
                        counts: counts,
                        labels: labels,
                        barColor: AppTheme.primaryColor,
                        gridColor: Theme.of(context).brightness == Brightness.dark
                            ? const Color(0xFF374151)
                            : Colors.grey.shade200,
                        textColor: _mutedText(context),
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _BarChartPainter extends CustomPainter {
  final List<int> counts;
  final List<String> labels;
  final Color barColor;
  final Color gridColor;
  final Color textColor;
  _BarChartPainter({
    required this.counts,
    required this.labels,
    required this.barColor,
    required this.gridColor,
    required this.textColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const double leftPad = 0;
    const double rightPad = 0;
    const double topPad = 0;
    const double bottomPad = 28;
    final double chartH = size.height - topPad - bottomPad;
    final double chartW = size.width - leftPad - rightPad;

    final int peak = counts.isEmpty
        ? 1
        : counts.fold<int>(0, (a, b) => b > a ? b : a).clamp(1, 1 << 31);

    // Grid lines
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (int i = 0; i < 4; i++) {
      final y = topPad + chartH * (i / 3);
      canvas.drawLine(Offset(leftPad, y), Offset(leftPad + chartW, y), gridPaint);
    }

    // Bars
    final int n = counts.length;
    final double slot = chartW / n;
    final double barW = slot * 0.46;
    final paintBar = Paint()..color = barColor;
    final paintMuted = Paint()..color = barColor.withValues(alpha: 0.3);
    for (int i = 0; i < n; i++) {
      final v = counts[i];
      final h = (v / peak) * chartH;
      final cx = leftPad + slot * i + slot / 2;
      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(cx - barW / 2, topPad + chartH - h, barW, h),
        const Radius.circular(6),
      );
      canvas.drawRRect(rect, v == 0 ? paintMuted : paintBar);
    }

    // X labels
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (int i = 0; i < n; i++) {
      tp.text = TextSpan(
        text: labels[i],
        style: TextStyle(color: textColor, fontSize: 10, fontWeight: FontWeight.w500),
      );
      tp.layout();
      final cx = leftPad + slot * i + slot / 2;
      tp.paint(canvas, Offset(cx - tp.width / 2, topPad + chartH + 10));
    }
  }

  @override
  bool shouldRepaint(covariant _BarChartPainter old) =>
      old.counts != counts ||
      old.barColor != barColor ||
      old.gridColor != gridColor ||
      old.textColor != textColor;
}

// ─────────────────────────────────────────────────────────────────────────────
// Trip status donut
// ─────────────────────────────────────────────────────────────────────────────

class _StatusDonutCard extends StatelessWidget {
  const _StatusDonutCard();

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardHeader(title: "Trip status", subtitle: "All time"),
          const SizedBox(height: 14),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance.collection('trips').snapshots(),
            builder: (ctx, snap) {
              int active = 0;
              int completed = 0;
              int pending = 0;
              for (final d in snap.data?.docs ?? const []) {
                final s = (d.data()['status'] ?? '').toString();
                if (s == 'in_progress') {
                  active++;
                } else if (s == 'completed') {
                  completed++;
                } else {
                  pending++;
                }
              }
              final total = active + completed + pending;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    height: 180,
                    child: Center(
                      child: SizedBox(
                        width: 160,
                        height: 160,
                        child: CustomPaint(
                          painter: _DonutPainter(
                            values: [active.toDouble(), completed.toDouble(), pending.toDouble()],
                            colors: [
                              Colors.green.shade600,
                              AppTheme.primaryColor,
                              AppTheme.accentColor,
                            ],
                            trackColor:
                                Theme.of(context).brightness == Brightness.dark
                                    ? const Color(0xFF1F2A35)
                                    : Colors.grey.shade100,
                          ),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  total.toString(),
                                  style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    color: _strongText(context),
                                  ),
                                ),
                                Text("trips",
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: _mutedText(context),
                                    )),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  _legendRow(context, Colors.green.shade600, "Active", active, total),
                  _legendRow(context, AppTheme.primaryColor, "Completed", completed, total),
                  _legendRow(context, AppTheme.accentColor, "Pending", pending, total),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _legendRow(BuildContext context, Color color, String label, int v, int total) {
    final pct = total == 0 ? 0 : ((v / total) * 100).round();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label,
                style: TextStyle(fontSize: 12, color: _strongText(context))),
          ),
          Text("$v", style: TextStyle(fontSize: 12, color: _strongText(context), fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Text("$pct%", style: TextStyle(fontSize: 11, color: _mutedText(context))),
        ],
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  final List<double> values;
  final List<Color> colors;
  final Color trackColor;
  _DonutPainter({required this.values, required this.colors, required this.trackColor});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2;
    const strokeW = 18.0;
    final inner = radius - strokeW;
    final rect = Rect.fromCircle(center: center, radius: radius - strokeW / 2);

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeW
      ..strokeCap = StrokeCap.butt
      ..color = trackColor;
    canvas.drawCircle(center, radius - strokeW / 2, track);

    final total = values.fold<double>(0, (a, b) => a + b);
    if (total == 0) return;

    double start = -math.pi / 2;
    for (int i = 0; i < values.length; i++) {
      final sweep = (values[i] / total) * 2 * math.pi;
      if (sweep <= 0) continue;
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeW
        ..strokeCap = StrokeCap.butt
        ..color = colors[i % colors.length];
      canvas.drawArc(rect, start, sweep, false, paint);
      start += sweep;
    }
    // Inner mask so the donut hole looks crisp
    final innerPaint = Paint()..color = Colors.transparent;
    canvas.drawCircle(center, inner, innerPaint);
  }

  @override
  bool shouldRepaint(covariant _DonutPainter old) =>
      old.values != values || old.colors != colors || old.trackColor != trackColor;
}

// ─────────────────────────────────────────────────────────────────────────────
// New users — line chart
// ─────────────────────────────────────────────────────────────────────────────

class _UsersLineChartCard extends StatelessWidget {
  const _UsersLineChartCard();

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final sevenAgo = DateTime(now.year, now.month, now.day).subtract(const Duration(days: 6));
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardHeader(title: "New users", subtitle: "Last 7 days"),
          const SizedBox(height: 16),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance.collection('users').snapshots(),
            builder: (ctx, snap) {
              final List<int> counts = List<int>.filled(7, 0);
              if (snap.hasData) {
                for (final d in snap.data!.docs) {
                  final ts = d.data()['createdAt'] as Timestamp?;
                  if (ts == null) continue;
                  final date = ts.toDate();
                  final day = DateTime(date.year, date.month, date.day);
                  final idx = day.difference(sevenAgo).inDays;
                  if (idx >= 0 && idx < 7) counts[idx]++;
                }
              }
              final labels = List<String>.generate(7, (i) {
                final d = sevenAgo.add(Duration(days: i));
                const dn = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
                return dn[d.weekday - 1];
              });
              final total = counts.fold<int>(0, (a, b) => a + b);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text("$total new this week",
                      style: TextStyle(
                          fontSize: 13,
                          color: _mutedText(context),
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 180,
                    child: CustomPaint(
                      painter: _LineChartPainter(
                        counts: counts,
                        labels: labels,
                        lineColor: AppTheme.primaryColor,
                        fillColor: AppTheme.primaryColor.withValues(alpha: 0.15),
                        gridColor:
                            Theme.of(context).brightness == Brightness.dark
                                ? const Color(0xFF374151)
                                : Colors.grey.shade200,
                        textColor: _mutedText(context),
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _LineChartPainter extends CustomPainter {
  final List<int> counts;
  final List<String> labels;
  final Color lineColor;
  final Color fillColor;
  final Color gridColor;
  final Color textColor;
  _LineChartPainter({
    required this.counts,
    required this.labels,
    required this.lineColor,
    required this.fillColor,
    required this.gridColor,
    required this.textColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    const double bottomPad = 28;
    final double chartH = size.height - bottomPad;
    final double chartW = size.width;
    final int n = counts.length;
    final int peak = counts.isEmpty
        ? 1
        : counts.fold<int>(0, (a, b) => b > a ? b : a).clamp(1, 1 << 31);

    // Grid
    final gridPaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (int i = 0; i < 4; i++) {
      final y = chartH * (i / 3);
      canvas.drawLine(Offset(0, y), Offset(chartW, y), gridPaint);
    }

    // Build path
    final path = Path();
    final fillPath = Path();
    for (int i = 0; i < n; i++) {
      final x = (chartW / (n - 1)) * i;
      final y = chartH - (counts[i] / peak) * chartH;
      if (i == 0) {
        path.moveTo(x, y);
        fillPath.moveTo(x, chartH);
        fillPath.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fillPath.lineTo(x, y);
      }
    }
    fillPath.lineTo(chartW, chartH);
    fillPath.close();

    canvas.drawPath(fillPath, Paint()..color = fillColor);
    canvas.drawPath(
      path,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..strokeJoin = StrokeJoin.round,
    );

    // Points
    final dotPaint = Paint()..color = lineColor;
    final dotBg = Paint()..color = Colors.white;
    for (int i = 0; i < n; i++) {
      final x = (chartW / (n - 1)) * i;
      final y = chartH - (counts[i] / peak) * chartH;
      canvas.drawCircle(Offset(x, y), 4, dotPaint);
      canvas.drawCircle(Offset(x, y), 2, dotBg);
    }

    // X labels
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (int i = 0; i < n; i++) {
      tp.text = TextSpan(
        text: labels[i],
        style: TextStyle(color: textColor, fontSize: 10, fontWeight: FontWeight.w500),
      );
      tp.layout();
      final x = (chartW / (n - 1)) * i;
      tp.paint(canvas, Offset(x - tp.width / 2, chartH + 10));
    }
  }

  @override
  bool shouldRepaint(covariant _LineChartPainter old) =>
      old.counts != counts ||
      old.lineColor != lineColor ||
      old.fillColor != fillColor ||
      old.gridColor != gridColor ||
      old.textColor != textColor;
}

// ─────────────────────────────────────────────────────────────────────────────
// Completed gauge
// ─────────────────────────────────────────────────────────────────────────────

class _CompletedGaugeCard extends StatelessWidget {
  const _CompletedGaugeCard();

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardHeader(title: "Completion rate", subtitle: "Completed / total"),
          const SizedBox(height: 8),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance.collection('trips').snapshots(),
            builder: (ctx, snap) {
              final all = snap.data?.docs ?? const [];
              int completed = 0;
              for (final d in all) {
                if ((d.data()['status'] ?? '') == 'completed') completed++;
              }
              final pct = all.isEmpty ? 0.0 : completed / all.length;
              return Column(
                children: [
                  SizedBox(
                    height: 180,
                    child: CustomPaint(
                      painter: _GaugePainter(
                        value: pct,
                        color: AppTheme.primaryColor,
                        trackColor:
                            Theme.of(context).brightness == Brightness.dark
                                ? const Color(0xFF1F2A35)
                                : Colors.grey.shade100,
                      ),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.only(top: 30),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                "${(pct * 100).toStringAsFixed(0)}%",
                                style: TextStyle(
                                  fontSize: 30,
                                  fontWeight: FontWeight.bold,
                                  color: _strongText(context),
                                ),
                              ),
                              Text("$completed of ${all.length}",
                                  style: TextStyle(fontSize: 11, color: _mutedText(context))),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double value; // 0..1
  final Color color;
  final Color trackColor;
  _GaugePainter({required this.value, required this.color, required this.trackColor});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height * 0.85);
    final radius = math.min(size.width, size.height) * 0.55;
    const strokeW = 18.0;
    final rect = Rect.fromCircle(center: center, radius: radius);

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeW
      ..strokeCap = StrokeCap.round
      ..color = trackColor;
    canvas.drawArc(rect, math.pi, math.pi, false, trackPaint);

    final valPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeW
      ..strokeCap = StrokeCap.round
      ..color = color;
    canvas.drawArc(rect, math.pi, math.pi * value.clamp(0.0, 1.0), false, valPaint);
  }

  @override
  bool shouldRepaint(covariant _GaugePainter old) =>
      old.value != value || old.color != color || old.trackColor != trackColor;
}

// ─────────────────────────────────────────────────────────────────────────────
// Latest trips
// ─────────────────────────────────────────────────────────────────────────────

class _LatestTripsCard extends StatelessWidget {
  const _LatestTripsCard();

  @override
  Widget build(BuildContext context) {
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _CardHeader(title: "Latest trips", subtitle: "Most recently created"),
          const SizedBox(height: 16),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: FirebaseFirestore.instance
                .collection('trips')
                .orderBy('createdAt', descending: true)
                .limit(6)
                .snapshots(),
            builder: (ctx, snap) {
              if (snap.hasError) {
                return Text("Failed: ${snap.error}",
                    style: const TextStyle(color: Colors.red));
              }
              if (!snap.hasData) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(20),
                    child: CircularProgressIndicator(color: AppTheme.primaryColor),
                  ),
                );
              }
              final docs = snap.data!.docs;
              if (docs.isEmpty) {
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text("No trips yet.",
                      style: TextStyle(color: _mutedText(context))),
                );
              }
              return Column(
                children: [
                  for (int i = 0; i < docs.length; i++) ...[
                    _tripRow(context, docs[i].data()),
                    if (i < docs.length - 1)
                      Divider(
                          color: Theme.of(context).brightness == Brightness.dark
                              ? const Color(0xFF1F2A35)
                              : Colors.grey.shade100,
                          height: 1),
                  ],
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _tripRow(BuildContext context, Map<String, dynamic> data) {
    final status = (data['status'] ?? 'pending').toString();
    final color = status == 'in_progress'
        ? Colors.green
        : status == 'completed'
            ? AppTheme.primaryColor
            : AppTheme.accentColor;
    final label = status == 'in_progress'
        ? 'Active'
        : status == 'completed'
            ? 'Completed'
            : 'Pending';
    final buses = (data['buses'] as List?) ?? const [];
    int totalStudents = 0;
    for (final b in buses) {
      totalStudents += ((b as Map?)?['passengers'] as List?)?.length ?? 0;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.route_rounded,
                color: AppTheme.primaryColor, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (data['title'] ?? 'Untitled trip').toString(),
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: _strongText(context),
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  "${data['date'] ?? ''} · ${buses.length} bus${buses.length == 1 ? '' : 'es'} · $totalStudents student${totalStudents == 1 ? '' : 's'}",
                  style: TextStyle(fontSize: 11, color: _mutedText(context)),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(label,
                style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w600, color: color)),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

class _CardHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  const _CardHeader({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: _strongText(context))),
        const SizedBox(height: 2),
        Text(subtitle,
            style: TextStyle(fontSize: 12, color: _mutedText(context))),
      ],
    );
  }
}
