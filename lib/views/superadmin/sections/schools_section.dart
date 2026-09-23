import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../config/console_theme.dart';
import '../super_admin_data.dart';
import '../widgets/console_scaffold.dart';
import '../widgets/console_ui.dart';
import '../widgets/reason_dialog.dart';

/// Subscribing schools and the administrator account attached to each.
///
/// The console shows the subscription and the one account it provisioned. It
/// has no route to the school's students, parents, teachers or trips, by rule
/// as well as by design.
class SchoolsSection extends StatefulWidget {
  const SchoolsSection({super.key});

  @override
  State<SchoolsSection> createState() => _SchoolsSectionState();
}

class _SchoolsSectionState extends State<SchoolsSection> {
  final _search = TextEditingController();
  String _query = '';
  String _filter = 'all';
  int _page = 0;
  static const _pageSize = 12;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);

    return ConsolePage(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: 'Schools & Admin Accounts',
            subtitle: 'Active subscriptions and the administrator provisioned for each.',
          ),
          const SizedBox(height: Insets.xl),
          Wrap(
            spacing: Insets.md,
            runSpacing: Insets.md,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ConsoleSearchField(
                controller: _search,
                hint: 'Search school or admin email',
                onChanged: (v) => setState(() {
                  _query = v.trim().toLowerCase();
                  _page = 0;
                }),
              ),
              DropdownMenu<String>(
                initialSelection: _filter,
                label: const Text('Show'),
                onSelected: (v) => setState(() {
                  _filter = v ?? 'all';
                  _page = 0;
                }),
                dropdownMenuEntries: const [
                  DropdownMenuEntry(value: 'all', label: 'All schools'),
                  DropdownMenuEntry(value: 'active', label: 'Active'),
                  DropdownMenuEntry(value: 'disabled', label: 'Disabled admin'),
                ],
              ),
            ],
          ),
          const SizedBox(height: Insets.lg),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: PlatformQueries.schools().snapshots(),
            builder: (context, schoolSnap) {
              return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
                stream: PlatformQueries.schoolAdmins().snapshots(),
                builder: (context, adminSnap) {
                  if (schoolSnap.hasError) {
                    return ConsoleErrorState(
                      title: 'Schools could not be loaded',
                      message: 'Check your connection and try again.',
                      technicalDetail: schoolSnap.error.toString(),
                      onRetry: () => setState(() {}),
                    );
                  }
                  if (!schoolSnap.hasData) {
                    return const DelayedLoader(
                      child: ConsoleSkeleton(rows: 4, rowHeight: 96),
                    );
                  }

                  // Admin accounts are matched to their school in memory: one
                  // query for each collection beats a per-school lookup.
                  final adminsBySchool = <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
                  for (final a in adminSnap.data?.docs ?? const []) {
                    final sid = (a.data()['schoolId'] ?? '').toString();
                    if (sid.isNotEmpty) adminsBySchool[sid] = a;
                  }

                  final all = schoolSnap.data!.docs;
                  final filtered = all.where((doc) {
                    final d = doc.data();
                    final admin = adminsBySchool[doc.id]?.data();
                    if (_filter == 'active' && d['status'] != 'active') return false;
                    if (_filter == 'disabled' &&
                        (admin?['accountStatus'] ?? 'active') != 'disabled') {
                      return false;
                    }
                    if (_query.isEmpty) return true;
                    final hay = [
                      d['name'],
                      d['adminEmail'],
                      d['tierLabel'],
                      admin?['email'],
                      admin?['name'],
                    ].map((v) => (v ?? '').toString().toLowerCase()).join(' ');
                    return hay.contains(_query);
                  }).toList();

                  if (all.isEmpty) {
                    return const ConsoleEmptyState(
                      icon: Icons.apartment_outlined,
                      title: 'No schools yet',
                      message: 'A school appears here once you approve its subscription '
                          'application and the admin account is provisioned.',
                    );
                  }
                  if (filtered.isEmpty) {
                    return ConsoleEmptyState(
                      icon: Icons.search_off_rounded,
                      title: 'No schools match',
                      message: 'Try a different search term or clear the filter.',
                      action: ConsoleButton(
                        label: 'Clear filters',
                        kind: ConsoleButtonKind.secondary,
                        onPressed: () => setState(() {
                          _search.clear();
                          _query = '';
                          _filter = 'all';
                        }),
                      ),
                    );
                  }

                  final start = _page * _pageSize;
                  final pageItems = filtered.skip(start).take(_pageSize).toList();

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (adminSnap.hasError)
                        Padding(
                          padding: const EdgeInsets.only(bottom: Insets.md),
                          child: Container(
                            padding: const EdgeInsets.all(Insets.md),
                            decoration: BoxDecoration(
                              color: t.warning.bg,
                              border: Border.all(color: t.warning.border),
                              borderRadius: Radii.control,
                            ),
                            child: Text(
                              'Administrator accounts could not be loaded, so account '
                              'status is not shown below.',
                              style: TextStyle(
                                fontSize: FontSizes.body,
                                color: t.warning.fg,
                              ),
                            ),
                          ),
                        ),
                      ...pageItems.map(
                        (doc) => Padding(
                          padding: const EdgeInsets.only(bottom: Insets.md),
                          child: _SchoolCard(
                            schoolId: doc.id,
                            school: doc.data(),
                            admin: adminsBySchool[doc.id],
                          ),
                        ),
                      ),
                      const SizedBox(height: Insets.sm),
                      ConsolePagination(
                        page: _page,
                        pageSize: _pageSize,
                        shown: pageItems.length,
                        hasMore: start + _pageSize < filtered.length,
                        onPrevious: () => setState(() => _page--),
                        onNext: () => setState(() => _page++),
                      ),
                    ],
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

class _SchoolCard extends StatefulWidget {
  final String schoolId;
  final Map<String, dynamic> school;
  final QueryDocumentSnapshot<Map<String, dynamic>>? admin;

  const _SchoolCard({required this.schoolId, required this.school, this.admin});

  @override
  State<_SchoolCard> createState() => _SchoolCardState();
}

class _SchoolCardState extends State<_SchoolCard> {
  bool _busy = false;
  String? _feedback;
  bool _feedbackIsError = false;

  Future<void> _toggleAccount(bool disable) async {
    final admin = widget.admin;
    if (admin == null) return;
    final name = (widget.school['name'] ?? 'this school').toString();

    final reason = await ReasonDialog.show(
      context,
      ReasonDialog(
        title: disable ? 'Disable this administrator?' : 'Re-enable this administrator?',
        description: disable
            ? 'The administrator of $name will be signed out immediately and blocked '
                'from signing in again. Their school\'s students, parents and teachers '
                'keep their accounts and their trips are untouched.'
            : 'The administrator of $name will be able to sign in again with their '
                'existing password.',
        confirmLabel: disable ? 'Disable account' : 'Re-enable account',
        confirmIcon: disable ? Icons.block_rounded : Icons.lock_open_rounded,
        confirmKind: disable ? ConsoleButtonKind.danger : ConsoleButtonKind.primary,
      ),
    );
    if (reason == null || !mounted) return;

    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      await PlatformActions.setAdminAccountStatus(
        uid: admin.id,
        disable: disable,
        reason: reason,
      );
      if (mounted) {
        setState(() {
          _feedback = disable
              ? 'Account disabled and sessions revoked.'
              : 'Account re-enabled.';
          _feedbackIsError = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _feedback = 'Could not change the account: $e';
          _feedbackIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _resendCredentials() async {
    final reason = await ReasonDialog.show(
      context,
      ReasonDialog(
        title: 'Resend administrator credentials?',
        description: 'A new temporary password is generated and emailed to the '
            'administrator. Any previous temporary password stops working immediately.',
        confirmLabel: 'Send new credentials',
        confirmIcon: Icons.mark_email_read_outlined,
      ),
    );
    if (reason == null || !mounted) return;

    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      final res = await PlatformActions.resendAdminCredentials(
        schoolId: widget.schoolId,
        reason: reason,
      );
      if (mounted) {
        final sent = res['emailSent'] == true;
        setState(() {
          _feedback = sent
              ? 'New credentials emailed to ${res['email'] ?? 'the administrator'}.'
              : 'A new password was set, but the email did not send '
                  '(${res['emailError'] ?? 'unknown error'}). Retry from this card.';
          _feedbackIsError = !sent;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _feedback = 'Could not resend credentials: $e';
          _feedbackIsError = true;
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final s = widget.school;
    final admin = widget.admin?.data();
    final disabled = (admin?['accountStatus'] ?? 'active') == 'disabled';
    final capacity = (s['capacity'] as num?)?.toInt() ?? 0;
    final students = (s['studentCount'] as num?)?.toInt() ?? 0;
    final testMode = s['paymentStatus'] == 'test_mode';

    return ConsoleCard(
      accent: disabled ? t.danger.border : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      (s['name'] ?? 'Unnamed school').toString(),
                      style: TextStyle(
                        fontSize: FontSizes.bodyLg,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.2,
                        color: t.text,
                      ),
                    ),
                    const SizedBox(height: Insets.xs),
                    Text(
                      '${s['tierLabel'] ?? 'Plan'} · '
                      '${capacity == 0 ? 'custom capacity' : '$students of $capacity students'} · '
                      '${formatPeso((s['priceMonthly'] as num?))}/month'
                      '${s['billingCycle'] == 'annual' ? ', billed annually' : ''}',
                      style: TextStyle(fontSize: FontSizes.body, color: t.textMuted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Insets.md),
              Wrap(
                spacing: Insets.sm,
                runSpacing: Insets.sm,
                children: [
                  if (testMode)
                    StatusBadge(
                      label: 'Payment bypassed',
                      tone: t.warning,
                      icon: Icons.science_outlined,
                      dense: true,
                    ),
                  StatusBadge(
                    label: disabled ? 'Admin disabled' : 'Active',
                    tone: disabled ? t.danger : t.success,
                    icon: disabled ? Icons.block_rounded : Icons.check_circle_rounded,
                    dense: true,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: Insets.lg),
          Container(
            padding: const EdgeInsets.all(Insets.md),
            decoration: BoxDecoration(
              color: t.surfaceMuted,
              borderRadius: Radii.control,
              border: Border.all(color: t.border),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.admin_panel_settings_outlined, size: 18, color: t.textFaint),
                const SizedBox(width: Insets.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        admin == null
                            ? 'No administrator account linked'
                            : (admin['name'] ?? 'Administrator').toString(),
                        style: TextStyle(
                          fontSize: FontSizes.body,
                          fontWeight: FontWeight.w600,
                          color: t.text,
                        ),
                      ),
                      Text(
                        (admin?['email'] ?? s['adminEmail'] ?? '—').toString(),
                        style: TextStyle(fontSize: FontSizes.caption, color: t.textMuted),
                      ),
                      if (admin?['mustChangePassword'] == true) ...[
                        const SizedBox(height: Insets.xs),
                        Text(
                          'Has not set their own password yet.',
                          style: TextStyle(fontSize: FontSizes.caption, color: t.warning.fg),
                        ),
                      ],
                      if (disabled && (admin?['disabledReason'] ?? '').toString().isNotEmpty) ...[
                        const SizedBox(height: Insets.xs),
                        Text(
                          'Disabled: ${admin!['disabledReason']}',
                          style: TextStyle(fontSize: FontSizes.caption, color: t.danger.fg),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (_feedback != null) ...[
            const SizedBox(height: Insets.md),
            Semantics(
              liveRegion: true,
              child: Text(
                _feedback!,
                style: TextStyle(
                  fontSize: FontSizes.body,
                  color: _feedbackIsError ? t.danger.fg : t.success.fg,
                ),
              ),
            ),
          ],
          const SizedBox(height: Insets.lg),
          Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.sm,
            children: [
              ConsoleButton(
                label: disabled ? 'Re-enable admin' : 'Disable admin',
                icon: disabled ? Icons.lock_open_rounded : Icons.block_rounded,
                kind: disabled ? ConsoleButtonKind.primary : ConsoleButtonKind.danger,
                busy: _busy,
                onPressed: widget.admin == null || _busy ? null : () => _toggleAccount(!disabled),
                disabledReason: widget.admin == null
                    ? 'No administrator account is linked to this school yet'
                    : null,
              ),
              ConsoleButton(
                label: 'Resend credentials',
                icon: Icons.mark_email_read_outlined,
                kind: ConsoleButtonKind.secondary,
                onPressed: _busy ? null : _resendCredentials,
              ),
            ],
          ),
        ],
      ),
    );
  }
}
