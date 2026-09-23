import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../config/console_theme.dart';
import '../super_admin_data.dart';
import '../widgets/console_scaffold.dart';
import '../widgets/console_ui.dart';
import '../widgets/reason_dialog.dart';

/// School subscription applications: the queue, and the review that decides one.
///
/// Nothing is decided automatically. OCR only puts the text of a document next
/// to the document, and any mismatch it surfaces is a prompt to look, never a
/// verdict — the operator approves, rejects or asks for more, and their reason
/// is recorded either way.
class ApplicationsSection extends StatefulWidget {
  const ApplicationsSection({super.key});

  @override
  State<ApplicationsSection> createState() => _ApplicationsSectionState();
}

class _ApplicationsSectionState extends State<ApplicationsSection> {
  final _search = TextEditingController();
  String _query = '';
  String _filter = 'awaiting';
  String? _openId;
  int _page = 0;
  static const _pageSize = 10;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(Map<String, dynamic> d) {
    final status = (d['status'] ?? '').toString();
    switch (_filter) {
      case 'awaiting':
        if (!ApplicationStatus.awaitingReview.contains(status)) return false;
        break;
      case 'with_applicant':
        if (!ApplicationStatus.awaitingApplicant.contains(status)) return false;
        break;
      case 'all':
        break;
      default:
        if (status != _filter) return false;
    }
    if (_query.isEmpty) return true;
    final rep = (d['representative'] ?? const {}) as Map;
    final hay = [
      d['schoolName'],
      d['legalName'],
      d['reference'],
      d['email'],
      rep['name'],
      rep['email'],
    ].map((v) => (v ?? '').toString().toLowerCase()).join(' ');
    return hay.contains(_query);
  }

  @override
  Widget build(BuildContext context) {
    if (_openId != null) {
      return _ApplicationReview(
        applicationId: _openId!,
        onClose: () => setState(() => _openId = null),
      );
    }

    return ConsolePage(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: 'School Applications',
            subtitle: 'Every subscription starts here. Complete applications are '
                'reviewed within 7 banking days; processing may take up to 14 calendar days.',
          ),
          const SizedBox(height: Insets.xl),
          Wrap(
            spacing: Insets.md,
            runSpacing: Insets.md,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ConsoleSearchField(
                controller: _search,
                hint: 'Search school, reference, applicant',
                onChanged: (v) => setState(() {
                  _query = v.trim().toLowerCase();
                  _page = 0;
                }),
              ),
              DropdownMenu<String>(
                initialSelection: _filter,
                label: const Text('Queue'),
                onSelected: (v) => setState(() {
                  _filter = v ?? 'awaiting';
                  _page = 0;
                }),
                dropdownMenuEntries: [
                  const DropdownMenuEntry(value: 'awaiting', label: 'Awaiting my review'),
                  const DropdownMenuEntry(value: 'with_applicant', label: 'With the applicant'),
                  const DropdownMenuEntry(value: 'all', label: 'All applications'),
                  ...ApplicationStatus.all.map(
                    (s) => DropdownMenuEntry(value: s, label: ApplicationStatus.label(s)),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: Insets.lg),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: PlatformQueries.allApplications().limit(200).snapshots(),
            builder: (context, snap) {
              if (snap.hasError) {
                return ConsoleErrorState(
                  title: 'Applications could not be loaded',
                  message: 'Check that you are signed in as a super admin, then try again.',
                  technicalDetail: snap.error.toString(),
                  onRetry: () => setState(() {}),
                );
              }
              if (!snap.hasData) {
                return const DelayedLoader(child: ConsoleSkeleton(rows: 5, rowHeight: 92));
              }

              final all = snap.data!.docs;
              final rows = all.where((d) => _matches(d.data())).toList();

              if (all.isEmpty) {
                return const ConsoleEmptyState(
                  icon: Icons.assignment_outlined,
                  title: 'No applications yet',
                  message: 'When a school applies from the website, their application '
                      'and verification documents arrive here for review.',
                );
              }
              if (rows.isEmpty) {
                return ConsoleEmptyState(
                  icon: Icons.inbox_rounded,
                  title: _filter == 'awaiting'
                      ? 'Nothing is waiting for you'
                      : 'No applications match',
                  message: _filter == 'awaiting'
                      ? 'Every submitted application has been decided. Switch the queue '
                          'filter to see the full history.'
                      : 'Try a different search term, or switch the queue filter.',
                  action: ConsoleButton(
                    label: 'Show all applications',
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
              final pageItems = rows.skip(start).take(_pageSize).toList();

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ...pageItems.map(
                    (doc) => Padding(
                      padding: const EdgeInsets.only(bottom: Insets.md),
                      child: _ApplicationRow(
                        doc: doc,
                        onOpen: () => setState(() => _openId = doc.id),
                      ),
                    ),
                  ),
                  const SizedBox(height: Insets.sm),
                  ConsolePagination(
                    page: _page,
                    pageSize: _pageSize,
                    shown: pageItems.length,
                    hasMore: start + _pageSize < rows.length,
                    onPrevious: () => setState(() => _page--),
                    onNext: () => setState(() => _page++),
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

class _ApplicationRow extends StatelessWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  final VoidCallback onOpen;

  const _ApplicationRow({required this.doc, required this.onOpen});

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final d = doc.data();
    final status = (d['status'] ?? '').toString();
    final rep = (d['representative'] ?? const {}) as Map;
    final target = d['reviewTargetAt'];
    final overdue = target is Timestamp &&
        target.toDate().isBefore(DateTime.now()) &&
        ApplicationStatus.awaitingReview.contains(status);

    return ConsoleCard(
      onTap: onOpen,
      accent: overdue ? t.danger.border : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        (d['schoolName'] ?? 'Unnamed school').toString(),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: FontSizes.bodyLg,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                          color: t.text,
                        ),
                      ),
                    ),
                    const SizedBox(width: Insets.sm),
                    StatusBadge(
                      label: ApplicationStatus.label(status),
                      tone: ApplicationStatus.tone(t, status),
                      icon: ApplicationStatus.icon(status),
                      dense: true,
                    ),
                    if (overdue) ...[
                      const SizedBox(width: Insets.xs),
                      StatusBadge(
                        label: 'Past target',
                        tone: t.danger,
                        icon: Icons.priority_high_rounded,
                        dense: true,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: Insets.xs),
                Text(
                  '${d['reference'] ?? '—'} · ${InstitutionType.label((d['institutionType'] ?? '').toString())}',
                  style: TextStyle(fontSize: FontSizes.caption, color: t.textMuted),
                ),
                const SizedBox(height: Insets.sm),
                Text(
                  '${rep['name'] ?? 'Applicant'} · ${d['email'] ?? ''}',
                  style: TextStyle(fontSize: FontSizes.body, color: t.textMuted),
                ),
              ],
            ),
          ),
          const SizedBox(width: Insets.lg),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                ((d['plan'] ?? const {}) as Map)['tierLabel']?.toString() ?? 'No plan',
                style: TextStyle(
                  fontSize: FontSizes.body,
                  fontWeight: FontWeight.w600,
                  color: t.text,
                ),
              ),
              Text(
                'Submitted ${relativeTime(d['submittedAt'])}',
                style: TextStyle(fontSize: FontSizes.caption, color: t.textMuted),
              ),
              const SizedBox(height: Insets.md),
              ConsoleButton(
                label: ApplicationStatus.awaitingReview.contains(status) ? 'Review' : 'Open',
                icon: Icons.arrow_forward_rounded,
                kind: ApplicationStatus.awaitingReview.contains(status)
                    ? ConsoleButtonKind.primary
                    : ConsoleButtonKind.secondary,
                onPressed: onOpen,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Review ───────────────────────────────────────────────────────────────────

class _ApplicationReview extends StatefulWidget {
  final String applicationId;
  final VoidCallback onClose;

  const _ApplicationReview({required this.applicationId, required this.onClose});

  @override
  State<_ApplicationReview> createState() => _ApplicationReviewState();
}

class _ApplicationReviewState extends State<_ApplicationReview> {
  bool _busy = false;
  String? _actionError;
  String? _actionMessage;

  /// Stable per decision attempt, so a double click or a retry after a network
  /// blip cannot provision two schools.
  late String _idempotencyKey = _newKey();

  String _newKey() {
    final r = Random.secure();
    return '${widget.applicationId}-${DateTime.now().millisecondsSinceEpoch}-'
        '${List.generate(6, (_) => r.nextInt(36).toRadixString(36)).join()}';
  }

  Future<void> _decide({
    required String decision,
    required Map<String, dynamic> application,
    List<String> requestedDocTypes = const [],
    bool overrideWarnings = false,
    String? overrideReason,
    required String reason,
  }) async {
    setState(() {
      _busy = true;
      _actionError = null;
      _actionMessage = null;
    });
    try {
      final res = await PlatformActions.decideApplication(
        applicationId: widget.applicationId,
        decision: decision,
        reason: reason,
        requestedDocTypes: requestedDocTypes,
        overrideWarnings: overrideWarnings,
        overrideReason: overrideReason,
        idempotencyKey: _idempotencyKey,
      );
      if (!mounted) return;
      final emailSent = res['emailSent'] == true;
      setState(() {
        _idempotencyKey = _newKey();
        _actionMessage = switch (decision) {
          'approve' => emailSent
              ? 'Approved. The school was provisioned and the credentials email was sent.'
              : 'Approved and the school was provisioned, but the credentials email '
                  'did not send (${res['emailError'] ?? 'unknown error'}). Retry it below.',
          'reject' => emailSent
              ? 'Rejected. The applicant has been emailed the reason.'
              : 'Rejected, but the notification email did not send '
                  '(${res['emailError'] ?? 'unknown error'}).',
          _ => emailSent
              ? 'Documents requested. The applicant has been emailed the list.'
              : 'Documents requested, but the email did not send '
                  '(${res['emailError'] ?? 'unknown error'}).',
        };
      });
    } catch (e) {
      if (mounted) setState(() => _actionError = _friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendly(Object e) {
    final s = e.toString();
    if (s.contains('failed-precondition')) {
      return 'This application has already been decided. Reload to see the current state.';
    }
    if (s.contains('permission-denied')) {
      return 'Your account is not allowed to decide applications.';
    }
    return 'The decision could not be recorded. $s';
  }

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance
          .collection('schoolApplications')
          .doc(widget.applicationId)
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) {
          return ConsolePage(
            child: ConsoleErrorState(
              title: 'This application could not be loaded',
              message: 'It may have been removed. Go back to the queue and try again.',
              technicalDetail: snap.error.toString(),
              onRetry: widget.onClose,
            ),
          );
        }
        if (!snap.hasData) {
          return const ConsolePage(
            child: DelayedLoader(child: ConsoleSkeleton(rows: 4, rowHeight: 120)),
          );
        }
        final d = snap.data!.data();
        if (d == null) {
          return ConsolePage(
            child: ConsoleEmptyState(
              icon: Icons.help_outline_rounded,
              title: 'Application not found',
              message: 'It may have been deleted.',
              action: ConsoleButton(
                label: 'Back to the queue',
                kind: ConsoleButtonKind.secondary,
                onPressed: widget.onClose,
              ),
            ),
          );
        }

        final status = (d['status'] ?? '').toString();
        final decided = status == ApplicationStatus.approved ||
            status == ApplicationStatus.rejected;

        return ConsolePage(
          maxWidth: 1320,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ConsoleButton(
                label: 'Back to applications',
                icon: Icons.arrow_back_rounded,
                kind: ConsoleButtonKind.ghost,
                onPressed: widget.onClose,
              ),
              const SizedBox(height: Insets.lg),
              _ReviewHeader(data: d, tokens: t),
              const SizedBox(height: Insets.xl),
              LayoutBuilder(
                builder: (context, c) {
                  final stacked = c.maxWidth < 1000;
                  final left = _DocumentsPanel(
                    applicationId: widget.applicationId,
                    application: d,
                  );
                  final right = Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _ApplicantPanel(data: d, tokens: t),
                      const SizedBox(height: Insets.lg),
                      _HistoryPanel(applicationId: widget.applicationId),
                    ],
                  );
                  if (stacked) {
                    return Column(children: [left, const SizedBox(height: Insets.lg), right]);
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(flex: 7, child: left),
                      const SizedBox(width: Insets.lg),
                      Expanded(flex: 4, child: right),
                    ],
                  );
                },
              ),
              const SizedBox(height: Insets.xl),
              if (_actionMessage != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: Insets.md),
                  child: Semantics(
                    liveRegion: true,
                    child: Container(
                      padding: const EdgeInsets.all(Insets.md),
                      decoration: BoxDecoration(
                        color: t.success.bg,
                        border: Border.all(color: t.success.border),
                        borderRadius: Radii.control,
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.check_circle_outline_rounded,
                              size: 18, color: t.success.fg),
                          const SizedBox(width: Insets.sm),
                          Expanded(
                            child: Text(
                              _actionMessage!,
                              style: TextStyle(
                                  fontSize: FontSizes.body, color: t.success.fg),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (_actionError != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: Insets.md),
                  child: Semantics(
                    liveRegion: true,
                    child: Container(
                      padding: const EdgeInsets.all(Insets.md),
                      decoration: BoxDecoration(
                        color: t.danger.bg,
                        border: Border.all(color: t.danger.border),
                        borderRadius: Radii.control,
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.error_outline_rounded, size: 18, color: t.danger.fg),
                          const SizedBox(width: Insets.sm),
                          Expanded(
                            child: Text(
                              _actionError!,
                              style: TextStyle(fontSize: FontSizes.body, color: t.danger.fg),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              _DecisionBar(
                application: d,
                applicationId: widget.applicationId,
                busy: _busy,
                alreadyDecided: decided,
                onDecide: _decide,
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ReviewHeader extends StatelessWidget {
  final Map<String, dynamic> data;
  final ConsoleTokens tokens;

  const _ReviewHeader({required this.data, required this.tokens});

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    final status = (data['status'] ?? '').toString();
    final target = data['reviewTargetAt'];
    final deadline = data['processingDeadlineAt'];
    final overdue = target is Timestamp && target.toDate().isBefore(DateTime.now());

    return ConsoleCard(
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
                      (data['schoolName'] ?? 'Unnamed school').toString(),
                      style: TextStyle(
                        fontSize: FontSizes.heading,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                        color: t.text,
                      ),
                    ),
                    const SizedBox(height: Insets.xs),
                    Text(
                      '${data['reference'] ?? '—'} · '
                      '${InstitutionType.label((data['institutionType'] ?? '').toString())}',
                      style: TextStyle(fontSize: FontSizes.body, color: t.textMuted),
                    ),
                  ],
                ),
              ),
              StatusBadge(
                label: ApplicationStatus.label(status),
                tone: ApplicationStatus.tone(t, status),
                icon: ApplicationStatus.icon(status),
              ),
            ],
          ),
          const SizedBox(height: Insets.lg),
          Wrap(
            spacing: Insets.xxl,
            runSpacing: Insets.md,
            children: [
              _Stat(label: 'Submitted', value: formatTimestamp(data['submittedAt']), tokens: t),
              _Stat(
                label: 'Documents complete',
                value: data['documentsCompletedAt'] == null
                    ? 'Not yet'
                    : formatTimestamp(data['documentsCompletedAt']),
                tokens: t,
              ),
              _Stat(
                label: 'Review target (7 banking days)',
                value: formatTimestamp(target, withTime: false),
                tone: overdue && ApplicationStatus.awaitingReview.contains(status)
                    ? t.danger
                    : null,
                tokens: t,
              ),
              _Stat(
                label: 'Processing limit (14 calendar days)',
                value: formatTimestamp(deadline, withTime: false),
                tokens: t,
              ),
            ],
          ),
          if (ApplicationStatus.awaitingReview.contains(status)) ...[
            const SizedBox(height: Insets.md),
            Text(
              'The timeline is a review commitment, not a payment deadline, and '
              'nothing is approved automatically when it passes.',
              style: TextStyle(
                fontSize: FontSizes.caption,
                height: 1.5,
                color: t.textFaint,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final StatusTone? tone;
  final ConsoleTokens tokens;

  const _Stat({
    required this.label,
    required this.value,
    required this.tokens,
    this.tone,
  });

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: FontSizes.caption, color: t.textMuted),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: FontSizes.body,
            fontWeight: FontWeight.w600,
            color: tone?.fg ?? t.text,
          ),
        ),
      ],
    );
  }
}

class _ApplicantPanel extends StatelessWidget {
  final Map<String, dynamic> data;
  final ConsoleTokens tokens;

  const _ApplicantPanel({required this.data, required this.tokens});

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    final rep = (data['representative'] ?? const {}) as Map;
    final plan = (data['plan'] ?? const {}) as Map;
    final address = (data['address'] ?? '').toString();

    return ConsoleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Applicant & plan',
            style: TextStyle(
              fontSize: FontSizes.bodyLg,
              fontWeight: FontWeight.w600,
              color: t.text,
            ),
          ),
          const SizedBox(height: Insets.lg),
          _KeyValue(label: 'Legal name', value: (data['legalName'] ?? '—').toString(), tokens: t),
          _KeyValue(label: 'Address', value: address.isEmpty ? '—' : address, tokens: t),
          _KeyValue(
            label: 'Representative',
            value: '${rep['name'] ?? '—'}${rep['position'] == null ? '' : ', ${rep['position']}'}',
            tokens: t,
          ),
          _KeyValue(label: 'Contact email', value: (data['email'] ?? '—').toString(), tokens: t),
          if ((rep['phone'] ?? '').toString().isNotEmpty)
            _KeyValue(label: 'Contact number', value: rep['phone'].toString(), tokens: t),
          Divider(color: t.border, height: Insets.xl),
          _KeyValue(
            label: 'Requested plan',
            value: '${plan['tierLabel'] ?? '—'} · '
                '${(plan['capacity'] as num?)?.toInt() == 0 ? 'custom capacity' : 'up to ${plan['capacity']} students'}',
            tokens: t,
          ),
          _KeyValue(
            label: 'Billing',
            value: '${formatPeso(plan['priceMonthly'] as num?)}/month'
                '${plan['billingCycle'] == 'annual' ? ', billed annually' : ''}',
            tokens: t,
          ),
          const SizedBox(height: Insets.sm),
          Container(
            padding: const EdgeInsets.all(Insets.md),
            decoration: BoxDecoration(
              color: t.warning.bg,
              border: Border.all(color: t.warning.border),
              borderRadius: Radii.control,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.science_outlined, size: 16, color: t.warning.fg),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(
                    'Payment is bypassed in this build. Approving provisions the '
                    'subscription and issues a receipt marked as test mode — no money '
                    'is collected.',
                    style: TextStyle(
                      fontSize: FontSizes.caption,
                      height: 1.5,
                      color: t.warning.fg,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _KeyValue extends StatelessWidget {
  final String label;
  final String value;
  final ConsoleTokens tokens;

  const _KeyValue({required this.label, required this.value, required this.tokens});

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: FontSizes.caption, color: t.textMuted)),
          const SizedBox(height: 2),
          SelectableText(
            value,
            style: TextStyle(fontSize: FontSizes.body, color: t.text),
          ),
        ],
      ),
    );
  }
}

class _HistoryPanel extends StatelessWidget {
  final String applicationId;

  const _HistoryPanel({required this.applicationId});

  static const _labels = <String, String>{
    'submitted': 'Application submitted',
    'resubmitted': 'Documents resubmitted',
    'documents_requested': 'More documents requested',
    'approved': 'Approved',
    'rejected': 'Rejected',
    'claimed': 'Taken for review',
    'override': 'Review warning overridden',
    'note': 'Reviewer note',
  };

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    return ConsoleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'History',
            style: TextStyle(
              fontSize: FontSizes.bodyLg,
              fontWeight: FontWeight.w600,
              color: t.text,
            ),
          ),
          const SizedBox(height: Insets.lg),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: PlatformQueries.applicationEvents(applicationId).snapshots(),
            builder: (context, snap) {
              if (snap.hasError) {
                return Text(
                  'The history could not be loaded.',
                  style: TextStyle(fontSize: FontSizes.body, color: t.danger.fg),
                );
              }
              if (!snap.hasData) {
                return const DelayedLoader(child: ConsoleSkeleton(rows: 2, rowHeight: 40));
              }
              final docs = snap.data!.docs;
              if (docs.isEmpty) {
                return Text(
                  'No events recorded yet.',
                  style: TextStyle(fontSize: FontSizes.body, color: t.textMuted),
                );
              }
              return Column(
                children: docs.map((e) {
                  final d = e.data();
                  final type = (d['type'] ?? '').toString();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: Insets.md),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          margin: const EdgeInsets.only(top: 6, right: Insets.md),
                          decoration: BoxDecoration(
                            color: t.borderStrong,
                            shape: BoxShape.circle,
                          ),
                        ),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _labels[type] ?? type,
                                style: TextStyle(
                                  fontSize: FontSizes.body,
                                  fontWeight: FontWeight.w600,
                                  color: t.text,
                                ),
                              ),
                              Text(
                                '${d['actorEmail'] ?? 'applicant'} · ${formatTimestamp(d['at'])}',
                                style: TextStyle(
                                  fontSize: FontSizes.caption,
                                  color: t.textMuted,
                                ),
                              ),
                              if ((d['reason'] ?? '').toString().isNotEmpty) ...[
                                const SizedBox(height: Insets.xs),
                                Text(
                                  d['reason'].toString(),
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
                      ],
                    ),
                  );
                }).toList(),
              );
            },
          ),
        ],
      ),
    );
  }
}

/// The uploaded documents, each with its extracted text beside it.
class _DocumentsPanel extends StatelessWidget {
  final String applicationId;
  final Map<String, dynamic> application;

  const _DocumentsPanel({required this.applicationId, required this.application});

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final required = ((application['requiredDocTypes'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();

    return ConsoleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Verification documents',
            style: TextStyle(
              fontSize: FontSizes.bodyLg,
              fontWeight: FontWeight.w600,
              color: t.text,
            ),
          ),
          const SizedBox(height: Insets.xs),
          Text(
            'Text is extracted to make the documents searchable beside the original. '
            'Extraction does not judge whether a school is genuine — that is your call.',
            style: TextStyle(fontSize: FontSizes.caption, height: 1.5, color: t.textMuted),
          ),
          const SizedBox(height: Insets.lg),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: PlatformQueries.applicationDocuments(applicationId).snapshots(),
            builder: (context, snap) {
              if (snap.hasError) {
                return ConsoleErrorState(
                  title: 'Documents could not be loaded',
                  message: 'Try reloading the page.',
                  technicalDetail: snap.error.toString(),
                );
              }
              if (!snap.hasData) {
                return const DelayedLoader(child: ConsoleSkeleton(rows: 2, rowHeight: 96));
              }
              final docs = snap.data!.docs;
              if (docs.isEmpty) {
                return const ConsoleEmptyState(
                  icon: Icons.folder_open_outlined,
                  title: 'No documents uploaded',
                  message: 'The applicant has not attached any verification documents yet.',
                );
              }

              final uploadedTypes =
                  docs.map((d) => (d.data()['type'] ?? '').toString()).toSet();
              final missing = required.where((r) => !uploadedTypes.contains(r)).toList();

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (missing.isNotEmpty) ...[
                    Container(
                      padding: const EdgeInsets.all(Insets.md),
                      decoration: BoxDecoration(
                        color: t.warning.bg,
                        border: Border.all(color: t.warning.border),
                        borderRadius: Radii.control,
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(Icons.rule_folder_outlined,
                                  size: 16, color: t.warning.fg),
                              const SizedBox(width: Insets.sm),
                              Text(
                                'Still missing for this institution type',
                                style: TextStyle(
                                  fontSize: FontSizes.body,
                                  fontWeight: FontWeight.w600,
                                  color: t.warning.fg,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: Insets.xs),
                          ...missing.map((m) => Text(
                                '• ${ApplicationDocType.label(m)}',
                                style: TextStyle(
                                  fontSize: FontSizes.caption,
                                  height: 1.6,
                                  color: t.warning.fg,
                                ),
                              )),
                        ],
                      ),
                    ),
                    const SizedBox(height: Insets.lg),
                  ],
                  ...docs.map((doc) => Padding(
                        padding: const EdgeInsets.only(bottom: Insets.md),
                        child: _DocumentCard(
                          applicationId: applicationId,
                          documentId: doc.id,
                          data: doc.data(),
                        ),
                      )),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _DocumentCard extends StatefulWidget {
  final String applicationId;
  final String documentId;
  final Map<String, dynamic> data;

  const _DocumentCard({
    required this.applicationId,
    required this.documentId,
    required this.data,
  });

  @override
  State<_DocumentCard> createState() => _DocumentCardState();
}

class _DocumentCardState extends State<_DocumentCard> {
  bool _expanded = true;
  bool _rerunning = false;

  Future<void> _rerunOcr() async {
    setState(() => _rerunning = true);
    try {
      await PlatformActions.reRunOcr(
        applicationId: widget.applicationId,
        documentId: widget.documentId,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not re-run extraction: $e')),
      );
    } finally {
      if (mounted) setState(() => _rerunning = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final d = widget.data;
    final type = (d['type'] ?? '').toString();
    final ocr = (d['ocr'] ?? const {}) as Map;
    final ocrStatus = (ocr['status'] ?? OcrStatus.pending).toString();
    final url = (d['downloadUrl'] ?? '').toString();
    final contentType = (d['contentType'] ?? '').toString();
    final isImage = contentType.startsWith('image/');
    final hints = ((d['reviewHints'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();

    return Container(
      decoration: BoxDecoration(
        color: t.surfaceMuted,
        border: Border.all(color: t.border),
        borderRadius: Radii.control,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            borderRadius: Radii.control,
            child: Padding(
              padding: const EdgeInsets.all(Insets.md),
              child: Row(
                children: [
                  Icon(
                    isImage ? Icons.image_outlined : Icons.picture_as_pdf_outlined,
                    size: 20,
                    color: t.textFaint,
                  ),
                  const SizedBox(width: Insets.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          ApplicationDocType.label(type),
                          style: TextStyle(
                            fontSize: FontSizes.body,
                            fontWeight: FontWeight.w600,
                            color: t.text,
                          ),
                        ),
                        Text(
                          '${d['fileName'] ?? ''} · uploaded ${relativeTime(d['uploadedAt'])}'
                          '${(d['version'] as num?) != null && (d['version'] as num) > 1 ? ' · v${d['version']}' : ''}',
                          style: TextStyle(
                            fontSize: FontSizes.caption,
                            color: t.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  StatusBadge(
                    label: OcrStatus.label(ocrStatus),
                    tone: OcrStatus.tone(t, ocrStatus),
                    icon: ocrStatus == OcrStatus.extracted
                        ? Icons.text_snippet_outlined
                        : Icons.help_outline_rounded,
                    dense: true,
                  ),
                  const SizedBox(width: Insets.sm),
                  Icon(
                    _expanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                    color: t.textFaint,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded) ...[
            Divider(height: 1, color: t.border),
            Padding(
              padding: const EdgeInsets.all(Insets.md),
              child: LayoutBuilder(
                builder: (context, c) {
                  final side = c.maxWidth >= 720;
                  final original = _OriginalPreview(
                    url: url,
                    isImage: isImage,
                    fileName: (d['fileName'] ?? 'document').toString(),
                  );
                  final extracted = _ExtractedPanel(
                    ocr: ocr,
                    hints: hints,
                    onRerun: _rerunning ? null : _rerunOcr,
                    rerunning: _rerunning,
                  );
                  if (!side) {
                    return Column(
                      children: [original, const SizedBox(height: Insets.md), extracted],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: original),
                      const SizedBox(width: Insets.md),
                      Expanded(child: extracted),
                    ],
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _OriginalPreview extends StatelessWidget {
  final String url;
  final bool isImage;
  final String fileName;

  const _OriginalPreview({
    required this.url,
    required this.isImage,
    required this.fileName,
  });

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Original',
          style: TextStyle(
            fontSize: FontSizes.caption,
            fontWeight: FontWeight.w700,
            color: t.textMuted,
          ),
        ),
        const SizedBox(height: Insets.sm),
        Container(
          height: 320,
          decoration: BoxDecoration(
            color: t.surface,
            border: Border.all(color: t.border),
            borderRadius: Radii.control,
          ),
          clipBehavior: Clip.antiAlias,
          child: url.isEmpty
              ? Center(
                  child: Text(
                    'No file attached',
                    style: TextStyle(fontSize: FontSizes.body, color: t.textMuted),
                  ),
                )
              : isImage
                  ? InteractiveViewer(
                      maxScale: 5,
                      child: Image.network(
                        url,
                        fit: BoxFit.contain,
                        width: double.infinity,
                        loadingBuilder: (context, child, progress) => progress == null
                            ? child
                            : const Center(child: CircularProgressIndicator()),
                        errorBuilder: (context, _, __) => Center(
                          child: Padding(
                            padding: const EdgeInsets.all(Insets.lg),
                            child: Text(
                              'The image could not be displayed. Open it in a new tab '
                              'instead.',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                  fontSize: FontSizes.body, color: t.textMuted),
                            ),
                          ),
                        ),
                      ),
                    )
                  : Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.picture_as_pdf_outlined,
                              size: 34, color: t.textFaint),
                          const SizedBox(height: Insets.sm),
                          Text(
                            fileName,
                            style: TextStyle(
                                fontSize: FontSizes.body, color: t.textMuted),
                          ),
                        ],
                      ),
                    ),
        ),
        const SizedBox(height: Insets.sm),
        ConsoleButton(
          label: 'Open original',
          icon: Icons.open_in_new_rounded,
          kind: ConsoleButtonKind.secondary,
          onPressed: url.isEmpty
              ? null
              : () => launchUrl(Uri.parse(url), webOnlyWindowName: '_blank'),
          disabledReason: 'No file is attached to this entry',
        ),
      ],
    );
  }
}

class _ExtractedPanel extends StatelessWidget {
  final Map ocr;
  final List<String> hints;
  final VoidCallback? onRerun;
  final bool rerunning;

  const _ExtractedPanel({
    required this.ocr,
    required this.hints,
    required this.onRerun,
    required this.rerunning,
  });

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final status = (ocr['status'] ?? OcrStatus.pending).toString();
    final fields = (ocr['fields'] ?? const {}) as Map;
    final rawText = (ocr['rawText'] ?? '').toString();
    final error = (ocr['error'] ?? '').toString();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              'Extracted text',
              style: TextStyle(
                fontSize: FontSizes.caption,
                fontWeight: FontWeight.w700,
                color: t.textMuted,
              ),
            ),
            const Spacer(),
            if (onRerun != null || rerunning)
              ConsoleButton(
                label: 'Re-run',
                icon: Icons.refresh_rounded,
                kind: ConsoleButtonKind.ghost,
                busy: rerunning,
                onPressed: onRerun,
              ),
          ],
        ),
        const SizedBox(height: Insets.sm),
        if (fields.isNotEmpty)
          Container(
            padding: const EdgeInsets.all(Insets.md),
            decoration: BoxDecoration(
              color: t.surface,
              border: Border.all(color: t.border),
              borderRadius: Radii.control,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: fields.entries
                  .where((e) => (e.value ?? '').toString().trim().isNotEmpty)
                  .map((e) => Padding(
                        padding: const EdgeInsets.only(bottom: Insets.sm),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SizedBox(
                              width: 120,
                              child: Text(
                                _fieldLabel(e.key.toString()),
                                style: TextStyle(
                                  fontSize: FontSizes.caption,
                                  color: t.textMuted,
                                ),
                              ),
                            ),
                            Expanded(
                              child: SelectableText(
                                e.value.toString(),
                                style: TextStyle(
                                  fontSize: FontSizes.caption,
                                  color: t.text,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ))
                  .toList(),
            ),
          ),
        if (hints.isNotEmpty) ...[
          const SizedBox(height: Insets.sm),
          Container(
            padding: const EdgeInsets.all(Insets.md),
            decoration: BoxDecoration(
              color: t.warning.bg,
              border: Border.all(color: t.warning.border),
              borderRadius: Radii.control,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.visibility_outlined, size: 15, color: t.warning.fg),
                    const SizedBox(width: Insets.sm),
                    Expanded(
                      child: Text(
                        'Worth checking against the document',
                        style: TextStyle(
                          fontSize: FontSizes.caption,
                          fontWeight: FontWeight.w700,
                          color: t.warning.fg,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Insets.xs),
                ...hints.map((h) => Text(
                      '• $h',
                      style: TextStyle(
                        fontSize: FontSizes.caption,
                        height: 1.6,
                        color: t.warning.fg,
                      ),
                    )),
              ],
            ),
          ),
        ],
        const SizedBox(height: Insets.sm),
        Container(
          height: hints.isEmpty && fields.isEmpty ? 320 : 180,
          width: double.infinity,
          padding: const EdgeInsets.all(Insets.md),
          decoration: BoxDecoration(
            color: t.surface,
            border: Border.all(color: t.border),
            borderRadius: Radii.control,
          ),
          child: status == OcrStatus.pending
              ? Center(
                  child: Text(
                    'Extracting text…',
                    style: TextStyle(fontSize: FontSizes.body, color: t.textMuted),
                  ),
                )
              : rawText.trim().isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(Insets.md),
                        child: Text(
                          error.isNotEmpty
                              ? error
                              : 'No text could be read from this file. Review the '
                                  'original directly — extraction failing is not a '
                                  'reason to reject.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: FontSizes.body,
                            height: 1.5,
                            color: t.textMuted,
                          ),
                        ),
                      ),
                    )
                  : SingleChildScrollView(
                      child: SelectableText(
                        rawText,
                        style: TextStyle(
                          fontSize: FontSizes.caption,
                          height: 1.6,
                          fontFamily: 'monospace',
                          color: t.text,
                        ),
                      ),
                    ),
        ),
      ],
    );
  }

  String _fieldLabel(String key) {
    switch (key) {
      case 'institutionName':
        return 'Institution name';
      case 'registrationNumber':
        return 'Registration no.';
      case 'issuingAgency':
        return 'Issuing agency';
      case 'address':
        return 'Address';
      case 'issueDate':
        return 'Issue date';
      case 'validUntil':
        return 'Valid until';
      default:
        return key;
    }
  }
}

/// Approve, request documents, or reject — with the reason that will be
/// recorded and, where relevant, emailed.
class _DecisionBar extends StatelessWidget {
  final Map<String, dynamic> application;
  final String applicationId;
  final bool busy;
  final bool alreadyDecided;
  final Future<void> Function({
    required String decision,
    required Map<String, dynamic> application,
    List<String> requestedDocTypes,
    bool overrideWarnings,
    String? overrideReason,
    required String reason,
  }) onDecide;

  const _DecisionBar({
    required this.application,
    required this.applicationId,
    required this.busy,
    required this.alreadyDecided,
    required this.onDecide,
  });

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final decision = (application['decision'] ?? const {}) as Map;

    if (alreadyDecided) {
      return ConsoleCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  ApplicationStatus.icon((application['status'] ?? '').toString()),
                  color: ApplicationStatus.tone(
                          t, (application['status'] ?? '').toString())
                      .fg,
                ),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(
                    'Decided: ${ApplicationStatus.label((application['status'] ?? '').toString())}'
                    ' on ${formatTimestamp(decision['at'])}',
                    style: TextStyle(
                      fontSize: FontSizes.bodyLg,
                      fontWeight: FontWeight.w600,
                      color: t.text,
                    ),
                  ),
                ),
              ],
            ),
            if ((decision['reason'] ?? '').toString().isNotEmpty) ...[
              const SizedBox(height: Insets.sm),
              Text(
                decision['reason'].toString(),
                style: TextStyle(fontSize: FontSizes.body, height: 1.6, color: t.textMuted),
              ),
            ],
            const SizedBox(height: Insets.md),
            Text(
              'Changing a recorded decision is not done from this screen. To stop a '
              'provisioned school, disable its administrator account under Schools & '
              'Admins — that keeps this decision in the history.',
              style: TextStyle(
                fontSize: FontSizes.caption,
                height: 1.5,
                color: t.textFaint,
              ),
            ),
          ],
        ),
      );
    }

    final requiredTypes = ((application['requiredDocTypes'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();

    return ConsoleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Decision',
            style: TextStyle(
              fontSize: FontSizes.bodyLg,
              fontWeight: FontWeight.w600,
              color: t.text,
            ),
          ),
          const SizedBox(height: Insets.xs),
          Text(
            'Approving provisions the school and emails its administrator a temporary '
            'password. Every outcome is recorded with your reason.',
            style: TextStyle(fontSize: FontSizes.body, height: 1.5, color: t.textMuted),
          ),
          const SizedBox(height: Insets.lg),
          Wrap(
            spacing: Insets.md,
            runSpacing: Insets.md,
            children: [
              ConsoleButton(
                label: 'Approve & provision',
                icon: Icons.verified_outlined,
                busy: busy,
                onPressed: busy
                    ? null
                    : () async {
                        final reason = await ReasonDialog.show(
                          context,
                          ReasonDialog(
                            title: 'Approve this application?',
                            description:
                                'A school and one administrator account are created, and '
                                'the temporary password is emailed. The subscription is '
                                'activated in payment-bypass mode, so no payment is taken.',
                            confirmLabel: 'Approve & provision',
                            confirmIcon: Icons.verified_outlined,
                            reasonLabel: 'What did you verify?',
                            reasonHelper:
                                'Recorded in the audit log. Name the documents you '
                                'checked, so the decision can be defended later.',
                          ),
                        );
                        if (reason != null) {
                          await onDecide(
                            decision: 'approve',
                            application: application,
                            reason: reason,
                          );
                        }
                      },
              ),
              ConsoleButton(
                label: 'Request more documents',
                icon: Icons.upload_file_rounded,
                kind: ConsoleButtonKind.secondary,
                onPressed: busy
                    ? null
                    : () async {
                        final result = await showDialog<_DocRequest>(
                          context: context,
                          barrierDismissible: false,
                          builder: (_) => _RequestDocumentsDialog(
                            suggested: requiredTypes,
                          ),
                        );
                        if (result != null) {
                          await onDecide(
                            decision: 'request_documents',
                            application: application,
                            requestedDocTypes: result.types,
                            reason: result.reason,
                          );
                        }
                      },
              ),
              ConsoleButton(
                label: 'Reject',
                icon: Icons.cancel_outlined,
                kind: ConsoleButtonKind.danger,
                onPressed: busy
                    ? null
                    : () async {
                        final reason = await ReasonDialog.show(
                          context,
                          ReasonDialog(
                            title: 'Reject this application?',
                            description:
                                'The applicant is emailed the reason you give here. No '
                                'school or administrator account is created.',
                            confirmLabel: 'Reject application',
                            confirmIcon: Icons.cancel_outlined,
                            confirmKind: ConsoleButtonKind.danger,
                            reasonLabel: 'Reason for rejection',
                            reasonHelper:
                                'Written to the applicant, so say plainly what was wrong '
                                'and whether they may apply again.',
                          ),
                        );
                        if (reason != null) {
                          await onDecide(
                            decision: 'reject',
                            application: application,
                            reason: reason,
                          );
                        }
                      },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DocRequest {
  final List<String> types;
  final String reason;
  const _DocRequest(this.types, this.reason);
}

class _RequestDocumentsDialog extends StatefulWidget {
  final List<String> suggested;

  const _RequestDocumentsDialog({required this.suggested});

  @override
  State<_RequestDocumentsDialog> createState() => _RequestDocumentsDialogState();
}

class _RequestDocumentsDialogState extends State<_RequestDocumentsDialog> {
  late final Set<String> _selected = {...widget.suggested};
  final _reason = TextEditingController();
  String? _error;

  static const _allTypes = [
    ApplicationDocType.secRegistration,
    ApplicationDocType.depedPermit,
    ApplicationDocType.chedRecognition,
    ApplicationDocType.tesdaRegistration,
    ApplicationDocType.governmentEstablishment,
    ApplicationDocType.authorizationLetter,
    ApplicationDocType.articlesOfIncorporation,
    ApplicationDocType.schoolIdentifier,
    ApplicationDocType.addressProof,
    ApplicationDocType.other,
  ];

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  void _submit() {
    if (_selected.isEmpty) {
      setState(() => _error = 'Choose at least one document to ask for.');
      return;
    }
    if (_reason.text.trim().length < 10) {
      setState(() => _error = 'Explain what is missing or unclear, in a sentence.');
      return;
    }
    Navigator.of(context).pop(_DocRequest(_selected.toList(), _reason.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    return Dialog(
      backgroundColor: t.surface,
      shape: const RoundedRectangleBorder(borderRadius: Radii.card),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Insets.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Request more documents',
                style: TextStyle(
                  fontSize: FontSizes.title,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                  color: t.text,
                ),
              ),
              const SizedBox(height: Insets.sm),
              Text(
                'The applicant is emailed this list and can upload the missing files '
                'without starting over. The review clock is re-estimated from the day '
                'their documents are complete.',
                style: TextStyle(fontSize: FontSizes.body, height: 1.55, color: t.textMuted),
              ),
              const SizedBox(height: Insets.lg),
              ..._allTypes.map(
                (type) => CheckboxListTile(
                  value: _selected.contains(type),
                  onChanged: (v) => setState(() {
                    if (v == true) {
                      _selected.add(type);
                    } else {
                      _selected.remove(type);
                    }
                    _error = null;
                  }),
                  title: Text(
                    ApplicationDocType.label(type),
                    style: TextStyle(fontSize: FontSizes.body, color: t.text),
                  ),
                  subtitle: Text(
                    ApplicationDocType.description(type),
                    style: TextStyle(fontSize: FontSizes.caption, color: t.textMuted),
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
              ),
              const SizedBox(height: Insets.md),
              ConsoleField(
                label: 'What should they send, and why?',
                required: true,
                errorText: _error,
                child: TextField(
                  controller: _reason,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    hintText: 'e.g. The DepEd permit you attached has expired — please '
                        'upload the current one.',
                  ),
                ),
              ),
              const SizedBox(height: Insets.xl),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  ConsoleButton(
                    label: 'Cancel',
                    kind: ConsoleButtonKind.ghost,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: Insets.sm),
                  ConsoleButton(
                    label: 'Send request',
                    icon: Icons.send_rounded,
                    onPressed: _submit,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
