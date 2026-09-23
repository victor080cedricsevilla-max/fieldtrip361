import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../config/console_theme.dart';
import '../super_admin_data.dart';
import '../widgets/console_scaffold.dart';
import '../widgets/console_ui.dart';

/// Every platform-management action, in order, with who did it and why.
///
/// This log covers approvals, suspensions, announcements and support decisions.
/// A school's own activity log is a separate collection the console cannot read.
class AuditLogsSection extends StatefulWidget {
  const AuditLogsSection({super.key});

  @override
  State<AuditLogsSection> createState() => _AuditLogsSectionState();
}

class _AuditLogsSectionState extends State<AuditLogsSection> {
  final _search = TextEditingController();
  String _query = '';
  String _actionFilter = 'all';
  int _limit = 50;

  static const _actionGroups = <String, String>{
    'all': 'All actions',
    'application.': 'Applications',
    'school_admin.': 'Admin accounts',
    'school.': 'Schools',
    'announcement.': 'Announcements',
    'support.': 'Support',
    'super_admin.': 'Super admins',
  };

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(Map<String, dynamic> d) {
    final action = (d['action'] ?? '').toString();
    if (_actionFilter != 'all' && !action.startsWith(_actionFilter)) return false;
    if (_query.isEmpty) return true;
    final haystack = [
      action,
      d['actorEmail'],
      d['targetId'],
      d['targetType'],
      d['reason'],
      (d['metadata'] ?? const {}).toString(),
    ].map((v) => (v ?? '').toString().toLowerCase()).join(' ');
    return haystack.contains(_query.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);

    return ConsolePage(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: 'Audit Logs',
            subtitle: 'Platform-management actions only. School activity stays with the school.',
          ),
          const SizedBox(height: Insets.xl),
          Wrap(
            spacing: Insets.md,
            runSpacing: Insets.md,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ConsoleSearchField(
                controller: _search,
                hint: 'Search action, actor, reason',
                onChanged: (v) => setState(() => _query = v),
              ),
              DropdownMenu<String>(
                initialSelection: _actionFilter,
                label: const Text('Area'),
                onSelected: (v) => setState(() => _actionFilter = v ?? 'all'),
                dropdownMenuEntries: _actionGroups.entries
                    .map((e) => DropdownMenuEntry(value: e.key, label: e.value))
                    .toList(),
              ),
            ],
          ),
          const SizedBox(height: Insets.lg),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: PlatformQueries.auditLogs().limit(_limit).snapshots(),
            builder: (context, snap) {
              if (snap.hasError) {
                return ConsoleErrorState(
                  title: 'The audit log could not be loaded',
                  message: 'Check that you are signed in as a super admin, then try again.',
                  technicalDetail: snap.error.toString(),
                  onRetry: () => setState(() {}),
                );
              }
              if (!snap.hasData) {
                return const DelayedLoader(child: ConsoleSkeleton(rows: 6, rowHeight: 56));
              }

              final all = snap.data!.docs;
              final rows = all.where((d) => _matches(d.data())).toList();

              if (all.isEmpty) {
                return const ConsoleEmptyState(
                  icon: Icons.history_toggle_off_outlined,
                  title: 'No platform actions yet',
                  message: 'Approving an application, suspending an administrator or '
                      'publishing an announcement will be recorded here.',
                );
              }
              if (rows.isEmpty) {
                return ConsoleEmptyState(
                  icon: Icons.search_off_rounded,
                  title: 'No entries match',
                  message: 'Try a different search term, or clear the area filter.',
                  action: ConsoleButton(
                    label: 'Clear filters',
                    kind: ConsoleButtonKind.secondary,
                    onPressed: () => setState(() {
                      _search.clear();
                      _query = '';
                      _actionFilter = 'all';
                    }),
                  ),
                );
              }

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ConsoleCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        for (int i = 0; i < rows.length; i++)
                          _AuditRow(
                            data: rows[i].data(),
                            isLast: i == rows.length - 1,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: Insets.lg),
                  if (all.length >= _limit)
                    ConsoleButton(
                      label: 'Load older entries',
                      icon: Icons.expand_more_rounded,
                      kind: ConsoleButtonKind.secondary,
                      onPressed: () => setState(() => _limit += 50),
                    )
                  else
                    Text(
                      'Showing all ${rows.length} entries.',
                      style: TextStyle(fontSize: FontSizes.caption, color: t.textMuted),
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

class _AuditRow extends StatelessWidget {
  final Map<String, dynamic> data;
  final bool isLast;

  const _AuditRow({required this.data, required this.isLast});

  static const _labels = <String, String>{
    'super_admin.bootstrapped': 'First super admin created',
    'super_admin.granted': 'Super-admin access granted',
    'super_admin.revoked': 'Super-admin access revoked',
    'school_admin.disabled': 'School admin disabled',
    'school_admin.enabled': 'School admin re-enabled',
    'school_admin.credentials_resent': 'Admin credentials resent',
    'application.submitted': 'Application submitted',
    'application.resubmitted': 'Documents resubmitted',
    'application.approved': 'Application approved',
    'application.rejected': 'Application rejected',
    'application.documents_requested': 'More documents requested',
    'application.override': 'Review warning overridden',
    'school.provisioned': 'School provisioned',
    'announcement.published': 'Announcement published',
    'announcement.unpublished': 'Announcement withdrawn',
    'support.status_changed': 'Ticket status changed',
    'support.replied': 'Support reply sent',
    'account.password_changed': 'Password changed',
  };

  IconData get _icon {
    final a = (data['action'] ?? '').toString();
    if (a.startsWith('application.approved') || a.startsWith('school.provisioned')) {
      return Icons.check_circle_outline_rounded;
    }
    if (a.startsWith('application.rejected') || a.contains('disabled')) {
      return Icons.block_rounded;
    }
    if (a.startsWith('announcement.')) return Icons.campaign_outlined;
    if (a.startsWith('support.')) return Icons.support_agent_outlined;
    if (a.startsWith('super_admin.')) return Icons.shield_outlined;
    return Icons.bolt_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final action = (data['action'] ?? '').toString();
    final reason = (data['reason'] ?? '').toString();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Insets.lg, vertical: Insets.md),
      decoration: BoxDecoration(
        border: isLast ? null : Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(_icon, size: 17, color: t.textFaint),
          ),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _labels[action] ?? action,
                  style: TextStyle(
                    fontSize: FontSizes.body,
                    fontWeight: FontWeight.w600,
                    color: t.text,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    (data['actorEmail'] ?? 'system').toString(),
                    if ((data['targetId'] ?? '').toString().isNotEmpty)
                      '→ ${data['targetType'] ?? 'record'} ${data['targetId']}',
                  ].join('  '),
                  style: TextStyle(fontSize: FontSizes.caption, color: t.textMuted),
                ),
                if (reason.isNotEmpty) ...[
                  const SizedBox(height: Insets.xs),
                  Text(
                    reason,
                    style: TextStyle(
                      fontSize: FontSizes.caption,
                      height: 1.5,
                      color: t.textMuted,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: Insets.md),
          Tooltip(
            message: formatTimestamp(data['at']),
            child: Text(
              relativeTime(data['at']),
              style: TextStyle(fontSize: FontSizes.caption, color: t.textFaint),
            ),
          ),
        ],
      ),
    );
  }
}
