import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../config/console_theme.dart';
import '../super_admin_data.dart';
import '../widgets/console_scaffold.dart';
import '../widgets/console_ui.dart';

/// What the operator needs to know before opening anything else: what is
/// waiting, what is late, and what changed recently.
class OverviewSection extends StatelessWidget {
  /// Jumps to another sidebar section — every number here leads somewhere.
  final ValueChanged<int> onOpenSection;

  const OverviewSection({super.key, required this.onOpenSection});

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);

    return ConsolePage(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: 'Overview',
            subtitle: 'Subscriptions, applications and support across the platform.',
          ),
          const SizedBox(height: Insets.xl),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: PlatformQueries.allApplications().snapshots(),
            builder: (context, appSnap) {
              return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: PlatformQueries.schools().snapshots(),
                builder: (context, schoolSnap) {
                  return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                    stream: PlatformQueries.schoolAdmins().snapshots(),
                    builder: (context, adminSnap) {
                      return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                        stream: PlatformQueries.ticketsNeedingSupport().snapshots(),
                        builder: (context, ticketSnap) {
                          // Render whatever has arrived: a failing tickets query
                          // should not blank out the application counts.
                          final anyLoading = [appSnap, schoolSnap, adminSnap, ticketSnap]
                              .any((s) => s.connectionState == ConnectionState.waiting);
                          final anyError = [appSnap, schoolSnap, adminSnap, ticketSnap]
                              .any((s) => s.hasError);

                          if (anyLoading && !appSnap.hasData) {
                            return const DelayedLoader(
                              child: ConsoleSkeleton(rows: 2, rowHeight: 132),
                            );
                          }

                          return _OverviewBody(
                            applications: appSnap.data?.docs ?? const [],
                            schools: schoolSnap.data?.docs ?? const [],
                            admins: adminSnap.data?.docs ?? const [],
                            openTickets: ticketSnap.data?.size ?? 0,
                            partial: anyError,
                            onOpenSection: onOpenSection,
                            tokens: t,
                          );
                        },
                      );
                    },
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

class _OverviewBody extends StatelessWidget {
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> applications;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> schools;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> admins;
  final int openTickets;
  final bool partial;
  final ValueChanged<int> onOpenSection;
  final ConsoleTokens tokens;

  const _OverviewBody({
    required this.applications,
    required this.schools,
    required this.admins,
    required this.openTickets,
    required this.partial,
    required this.onOpenSection,
    required this.tokens,
  });

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    final now = DateTime.now();

    int countWhere(bool Function(Map<String, dynamic>) test) =>
        applications.where((d) => test(d.data())).length;

    final pending = countWhere(
        (d) => ApplicationStatus.awaitingReview.contains(d['status']));
    final needingDocs = countWhere(
        (d) => d['status'] == ApplicationStatus.needsMoreDocuments);
    final approvedSchools = schools.where((d) => d.data()['status'] == 'active').length;
    final disabledAdmins =
        admins.where((d) => d.data()['accountStatus'] == 'disabled').length;

    // "At risk" is measured against the published promise: a 7-banking-day
    // target and a 14-calendar-day ceiling, both computed on the server and
    // stored on the application.
    final atRisk = applications.where((doc) {
      final d = doc.data();
      if (!ApplicationStatus.awaitingReview.contains(d['status'])) return false;
      final target = d['reviewTargetAt'];
      if (target is! Timestamp) return false;
      return target.toDate().difference(now).inHours <= 48;
    }).toList()
      ..sort((a, b) {
        final ta = a.data()['reviewTargetAt'];
        final tb = b.data()['reviewTargetAt'];
        if (ta is! Timestamp || tb is! Timestamp) return 0;
        return ta.compareTo(tb);
      });

    final recentDecisions = applications
        .where((d) => [ApplicationStatus.approved, ApplicationStatus.rejected]
            .contains(d.data()['status']))
        .take(5)
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (partial)
          Padding(
            padding: const EdgeInsets.only(bottom: Insets.lg),
            child: _PartialNotice(tokens: t),
          ),
        LayoutBuilder(
          builder: (context, c) {
            final columns = c.maxWidth >= 980 ? 5 : (c.maxWidth >= 620 ? 3 : 2);
            final width = (c.maxWidth - (columns - 1) * Insets.lg) / columns;
            return Wrap(
              spacing: Insets.lg,
              runSpacing: Insets.lg,
              children: [
                SizedBox(
                  width: width,
                  child: MetricTile(
                    label: 'Pending applications',
                    value: '$pending',
                    icon: Icons.inbox_rounded,
                    tone: pending > 0 ? t.info : t.neutral,
                    caption: pending == 0 ? 'Nothing waiting' : 'Awaiting your decision',
                    onTap: () => onOpenSection(1),
                  ),
                ),
                SizedBox(
                  width: width,
                  child: MetricTile(
                    label: 'Awaiting documents',
                    value: '$needingDocs',
                    icon: Icons.upload_file_rounded,
                    tone: needingDocs > 0 ? t.warning : t.neutral,
                    caption: 'With the applicant',
                    onTap: () => onOpenSection(1),
                  ),
                ),
                SizedBox(
                  width: width,
                  child: MetricTile(
                    label: 'Approved schools',
                    value: '$approvedSchools',
                    icon: Icons.apartment_rounded,
                    tone: t.success,
                    caption: 'Active subscriptions',
                    onTap: () => onOpenSection(2),
                  ),
                ),
                SizedBox(
                  width: width,
                  child: MetricTile(
                    label: 'Disabled admins',
                    value: '$disabledAdmins',
                    icon: Icons.person_off_rounded,
                    tone: disabledAdmins > 0 ? t.danger : t.neutral,
                    caption: 'Suspended accounts',
                    onTap: () => onOpenSection(2),
                  ),
                ),
                SizedBox(
                  width: width,
                  child: MetricTile(
                    label: 'Open tickets',
                    value: '$openTickets',
                    icon: Icons.support_agent_rounded,
                    tone: openTickets > 0 ? t.warning : t.neutral,
                    caption: 'Unresolved support',
                    onTap: () => onOpenSection(4),
                  ),
                ),
              ],
            );
          },
        ),
        const SizedBox(height: Insets.xxl),
        LayoutBuilder(
          builder: (context, c) {
            final stacked = c.maxWidth < 900;
            final left = _AtRiskCard(
              items: atRisk,
              tokens: t,
              onOpen: () => onOpenSection(1),
            );
            final right = _RecentActivityCard(
              decisions: recentDecisions,
              tokens: t,
            );
            if (stacked) {
              return Column(
                children: [left, const SizedBox(height: Insets.lg), right],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(flex: 3, child: left),
                const SizedBox(width: Insets.lg),
                Expanded(flex: 2, child: right),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _PartialNotice extends StatelessWidget {
  final ConsoleTokens tokens;
  const _PartialNotice({required this.tokens});

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return Container(
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: t.warning.bg,
        border: Border.all(color: t.warning.border),
        borderRadius: Radii.control,
      ),
      child: Row(
        children: [
          Icon(Icons.info_outline_rounded, size: 18, color: t.warning.fg),
          const SizedBox(width: Insets.sm),
          Expanded(
            child: Text(
              'Some figures could not be loaded, so this page is showing what it has. '
              'Reload to try again.',
              style: TextStyle(fontSize: FontSizes.body, color: t.warning.fg),
            ),
          ),
        ],
      ),
    );
  }
}

class _AtRiskCard extends StatelessWidget {
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> items;
  final ConsoleTokens tokens;
  final VoidCallback onOpen;

  const _AtRiskCard({required this.items, required this.tokens, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return ConsoleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Approaching the review target',
                  style: TextStyle(
                    fontSize: FontSizes.bodyLg,
                    fontWeight: FontWeight.w600,
                    color: t.text,
                  ),
                ),
              ),
              if (items.isNotEmpty)
                ConsoleButton(
                  label: 'Review',
                  kind: ConsoleButtonKind.primary,
                  onPressed: onOpen,
                ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          Text(
            'Complete applications are reviewed within 7 banking days.',
            style: TextStyle(fontSize: FontSizes.caption, color: t.textMuted),
          ),
          const SizedBox(height: Insets.lg),
          if (items.isEmpty)
            ConsoleEmptyState(
              icon: Icons.check_circle_outline_rounded,
              title: 'Nothing is running late',
              message: 'Every open application still has more than two days '
                  'before its review target.',
            )
          else
            ...items.take(6).map((doc) => _AtRiskRow(doc: doc, tokens: t)),
        ],
      ),
    );
  }
}

class _AtRiskRow extends StatelessWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  final ConsoleTokens tokens;

  const _AtRiskRow({required this.doc, required this.tokens});

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    final d = doc.data();
    final target = d['reviewTargetAt'];
    final overdue = target is Timestamp && target.toDate().isBefore(DateTime.now());
    final tone = overdue ? t.danger : t.warning;

    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.sm),
      child: Container(
        padding: const EdgeInsets.all(Insets.md),
        decoration: BoxDecoration(
          color: t.surfaceMuted,
          borderRadius: Radii.control,
          border: Border.all(color: t.border),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    (d['schoolName'] ?? 'Unnamed school').toString(),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: FontSizes.body,
                      fontWeight: FontWeight.w600,
                      color: t.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${d['reference'] ?? '—'} · submitted ${relativeTime(d['submittedAt'])}',
                    style: TextStyle(fontSize: FontSizes.caption, color: t.textMuted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Insets.md),
            StatusBadge(
              label: overdue ? 'Past target' : 'Due ${relativeTime(target)}',
              tone: tone,
              icon: overdue ? Icons.priority_high_rounded : Icons.schedule_rounded,
              dense: true,
            ),
          ],
        ),
      ),
    );
  }
}

class _RecentActivityCard extends StatelessWidget {
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> decisions;
  final ConsoleTokens tokens;

  const _RecentActivityCard({required this.decisions, required this.tokens});

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return ConsoleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Recent decisions',
            style: TextStyle(
              fontSize: FontSizes.bodyLg,
              fontWeight: FontWeight.w600,
              color: t.text,
            ),
          ),
          const SizedBox(height: Insets.lg),
          if (decisions.isEmpty)
            ConsoleEmptyState(
              icon: Icons.gavel_rounded,
              title: 'No decisions yet',
              message: 'Approvals and rejections appear here as you make them.',
            )
          else
            ...decisions.map((doc) {
              final d = doc.data();
              final status = (d['status'] ?? '').toString();
              return Padding(
                padding: const EdgeInsets.only(bottom: Insets.md),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      ApplicationStatus.icon(status),
                      size: 16,
                      color: ApplicationStatus.tone(t, status).fg,
                    ),
                    const SizedBox(width: Insets.sm),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            (d['schoolName'] ?? 'Unnamed school').toString(),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: FontSizes.body,
                              fontWeight: FontWeight.w500,
                              color: t.text,
                            ),
                          ),
                          Text(
                            '${ApplicationStatus.label(status)} · '
                            '${relativeTime((d['decision'] ?? const {})['at'])}',
                            style: TextStyle(
                              fontSize: FontSizes.caption,
                              color: t.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }),
          const SizedBox(height: Insets.sm),
          Divider(color: t.border, height: Insets.xl),
          _LatestAnnouncement(tokens: t),
        ],
      ),
    );
  }
}

class _LatestAnnouncement extends StatelessWidget {
  final ConsoleTokens tokens;
  const _LatestAnnouncement({required this.tokens});

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: PlatformQueries.announcements().limit(1).snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return Text(
            'Announcements could not be loaded.',
            style: TextStyle(fontSize: FontSizes.caption, color: t.textMuted),
          );
        }
        final docs = snap.data?.docs ?? const [];
        if (docs.isEmpty) {
          return Text(
            'No announcements published yet.',
            style: TextStyle(fontSize: FontSizes.caption, color: t.textMuted),
          );
        }
        final d = docs.first.data();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Latest announcement',
              style: TextStyle(
                fontSize: FontSizes.caption,
                fontWeight: FontWeight.w600,
                color: t.textMuted,
              ),
            ),
            const SizedBox(height: Insets.sm),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  AnnouncementCategory.icon((d['category'] ?? '').toString()),
                  size: 16,
                  color: t.info.fg,
                ),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        (d['title'] ?? '').toString(),
                        style: TextStyle(
                          fontSize: FontSizes.body,
                          fontWeight: FontWeight.w500,
                          color: t.text,
                        ),
                      ),
                      Text(
                        relativeTime(d['publishedAt'] ?? d['createdAt']),
                        style: TextStyle(
                          fontSize: FontSizes.caption,
                          color: t.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}
