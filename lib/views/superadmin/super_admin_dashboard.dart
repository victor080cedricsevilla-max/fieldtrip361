import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../config/console_theme.dart';
import '../../controllers/auth_controller.dart';
import '../auth/login_view.dart';
import 'sections/announcements_section.dart';
import 'sections/applications_section.dart';
import 'sections/audit_logs_section.dart';
import 'sections/overview_section.dart';
import 'sections/schools_section.dart';
import 'sections/settings_section.dart';
import 'sections/support_section.dart';
import 'super_admin_data.dart';
import 'widgets/console_scaffold.dart';
import 'widgets/console_ui.dart';

/// The platform operator's console.
///
/// Scope is deliberately narrow: subscribing schools, their administrator
/// accounts, the applications that create them, announcements and support.
/// There is no students view, no locations view and no trips view here, and no
/// security rule that would let one be added by accident.
class SuperAdminDashboard extends StatefulWidget {
  const SuperAdminDashboard({super.key});

  @override
  State<SuperAdminDashboard> createState() => _SuperAdminDashboardState();
}

class _SuperAdminDashboardState extends State<SuperAdminDashboard> {
  int _index = 0;

  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _appsSub;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _ticketsSub;

  int _openApplications = 0;
  int _openTickets = 0;

  Map<String, dynamic> _me = const {};

  @override
  void initState() {
    super.initState();
    _loadMe();
    _watchCounts();
  }

  Future<void> _loadMe() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    try {
      final snap = await FirebaseFirestore.instance.collection('users').doc(uid).get();
      if (mounted) setState(() => _me = snap.data() ?? const {});
    } catch (_) {
      // The header falls back to the Auth profile; nothing here is essential.
    }
  }

  /// Sidebar counts answer "what is waiting for me" before any section opens.
  void _watchCounts() {
    _appsSub = PlatformQueries.applicationsAwaitingReview().snapshots().listen(
          (s) => mounted ? setState(() => _openApplications = s.size) : null,
          onError: (_) {},
        );
    _ticketsSub = PlatformQueries.ticketsNeedingSupport().snapshots().listen(
          (s) => mounted ? setState(() => _openTickets = s.size) : null,
          onError: (_) {},
        );
  }

  @override
  void dispose() {
    _appsSub?.cancel();
    _ticketsSub?.cancel();
    super.dispose();
  }

  Future<void> _signOut() async {
    await AuthController().logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const LoginView()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final user = FirebaseAuth.instance.currentUser;

    final items = <ConsoleNavItem>[
      const ConsoleNavItem(
        label: 'Overview',
        icon: Icons.space_dashboard_outlined,
        activeIcon: Icons.space_dashboard_rounded,
      ),
      ConsoleNavItem(
        label: 'School Applications',
        icon: Icons.assignment_outlined,
        activeIcon: Icons.assignment_rounded,
        badge: _openApplications,
      ),
      const ConsoleNavItem(
        label: 'Schools & Admins',
        icon: Icons.apartment_outlined,
        activeIcon: Icons.apartment_rounded,
      ),
      const ConsoleNavItem(
        label: 'Announcements',
        icon: Icons.campaign_outlined,
        activeIcon: Icons.campaign_rounded,
      ),
      ConsoleNavItem(
        label: 'Customer Support',
        icon: Icons.support_agent_outlined,
        activeIcon: Icons.support_agent,
        badge: _openTickets,
      ),
      const ConsoleNavItem(
        label: 'Audit Logs',
        icon: Icons.history_toggle_off_outlined,
        activeIcon: Icons.history_rounded,
      ),
      const ConsoleNavItem(
        label: 'Settings',
        icon: Icons.settings_outlined,
        activeIcon: Icons.settings_rounded,
      ),
    ];

    final sections = <Widget>[
      OverviewSection(onOpenSection: (i) => setState(() => _index = i)),
      const ApplicationsSection(),
      const SchoolsSection(),
      const AnnouncementsSection(),
      const SupportSection(),
      const AuditLogsSection(),
      SettingsSection(me: _me, onProfileChanged: _loadMe),
    ];

    return ConsoleScaffold(
      items: items,
      selectedIndex: _index,
      onSelect: (i) => setState(() => _index = i),
      accountName: (_me['name'] ?? user?.displayName ?? 'Platform admin').toString(),
      accountEmail: (_me['email'] ?? user?.email ?? '').toString(),
      onSignOut: _signOut,
      headerActions: [
        Tooltip(
          message: 'The platform console has no access to student, parent or '
              'teacher records, locations or trip documents.',
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: Insets.md,
              vertical: Insets.sm,
            ),
            decoration: BoxDecoration(
              color: t.info.bg,
              border: Border.all(color: t.info.border),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.lock_outline_rounded, size: 14, color: t.info.fg),
                const SizedBox(width: Insets.xs + 2),
                Text(
                  'Platform scope',
                  style: TextStyle(
                    fontSize: FontSizes.caption,
                    fontWeight: FontWeight.w600,
                    color: t.info.fg,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: Insets.md),
      ],
      child: IndexedStack(index: _index, children: sections),
    );
  }
}

/// A section that is not built yet renders this rather than a blank page, so it
/// is obvious the area exists and nothing is silently broken.
class ConsoleSectionPlaceholder extends StatelessWidget {
  final String title;
  final String message;
  final IconData icon;

  const ConsoleSectionPlaceholder({
    super.key,
    required this.title,
    required this.message,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return ConsolePage(
      child: ConsoleEmptyState(icon: icon, title: title, message: message),
    );
  }
}
