import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../config/console_theme.dart';
import '../super_admin_data.dart';
import '../widgets/console_scaffold.dart';
import '../widgets/console_ui.dart';
import '../widgets/reason_dialog.dart';

/// Platform notices sent to every school administrator.
///
/// An announcement carries no recipient list: each administrator's read state
/// lives under their own account, so publishing one can never reveal who else
/// subscribes to FieldTrip360.
class AnnouncementsSection extends StatefulWidget {
  const AnnouncementsSection({super.key});

  @override
  State<AnnouncementsSection> createState() => _AnnouncementsSectionState();
}

class _AnnouncementsSectionState extends State<AnnouncementsSection> {
  Future<void> _compose({
    String? id,
    Map<String, dynamic>? existing,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _ComposeAnnouncementDialog(
        announcementId: id,
        existing: existing,
      ),
    );
    if (result == true && mounted) setState(() {});
  }

  Future<void> _withdraw(String id, String title) async {
    final reason = await ReasonDialog.show(
      context,
      ReasonDialog(
        title: 'Withdraw this announcement?',
        description: '"$title" stops appearing in every administrator\'s inbox. '
            'Administrators who already read it will simply no longer see it listed.',
        confirmLabel: 'Withdraw',
        confirmIcon: Icons.unpublished_outlined,
        confirmKind: ConsoleButtonKind.danger,
      ),
    );
    if (reason == null) return;
    try {
      await PlatformActions.unpublishAnnouncement(announcementId: id, reason: reason);
      if (mounted) setState(() {});
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not withdraw the announcement: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);

    return ConsolePage(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: 'Announcements',
            subtitle: 'Maintenance windows, new features and platform notices for '
                'every school administrator.',
            actions: [
              ConsoleButton(
                label: 'New announcement',
                icon: Icons.add_rounded,
                onPressed: () => _compose(),
              ),
            ],
          ),
          const SizedBox(height: Insets.xl),
          StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: PlatformQueries.announcements().limit(50).snapshots(),
            builder: (context, snap) {
              if (snap.hasError) {
                return ConsoleErrorState(
                  title: 'Announcements could not be loaded',
                  message: 'Check your connection and try again.',
                  technicalDetail: snap.error.toString(),
                  onRetry: () => setState(() {}),
                );
              }
              if (!snap.hasData) {
                return const DelayedLoader(child: ConsoleSkeleton(rows: 3, rowHeight: 110));
              }
              final docs = snap.data!.docs;
              if (docs.isEmpty) {
                return ConsoleEmptyState(
                  icon: Icons.campaign_outlined,
                  title: 'No announcements yet',
                  message: 'Publish one to tell every subscribing school about '
                      'maintenance, a new feature or a policy change.',
                  action: ConsoleButton(
                    label: 'Write the first announcement',
                    icon: Icons.add_rounded,
                    onPressed: () => _compose(),
                  ),
                );
              }

              return Column(
                children: docs.map((doc) {
                  final d = doc.data();
                  final published = d['status'] == 'published';
                  final category = (d['category'] ?? '').toString();
                  return Padding(
                    padding: const EdgeInsets.only(bottom: Insets.md),
                    child: ConsoleCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                AnnouncementCategory.icon(category),
                                size: 20,
                                color: t.info.fg,
                              ),
                              const SizedBox(width: Insets.md),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      (d['title'] ?? '').toString(),
                                      style: TextStyle(
                                        fontSize: FontSizes.bodyLg,
                                        fontWeight: FontWeight.w600,
                                        color: t.text,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${AnnouncementCategory.label(category)} · '
                                      '${published ? 'published ${relativeTime(d['publishedAt'])}' : 'draft'}',
                                      style: TextStyle(
                                        fontSize: FontSizes.caption,
                                        color: t.textMuted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: Insets.md),
                              StatusBadge(
                                label: published ? 'Published' : 'Withdrawn',
                                tone: published ? t.success : t.neutral,
                                icon: published
                                    ? Icons.public_rounded
                                    : Icons.public_off_rounded,
                                dense: true,
                              ),
                            ],
                          ),
                          const SizedBox(height: Insets.md),
                          Text(
                            (d['body'] ?? '').toString(),
                            style: TextStyle(
                              fontSize: FontSizes.body,
                              height: 1.6,
                              color: t.textMuted,
                            ),
                          ),
                          if (d['maintenanceStart'] is Timestamp) ...[
                            const SizedBox(height: Insets.md),
                            Container(
                              padding: const EdgeInsets.all(Insets.md),
                              decoration: BoxDecoration(
                                color: t.warning.bg,
                                border: Border.all(color: t.warning.border),
                                borderRadius: Radii.control,
                              ),
                              child: Row(
                                children: [
                                  Icon(Icons.schedule_rounded, size: 16, color: t.warning.fg),
                                  const SizedBox(width: Insets.sm),
                                  Expanded(
                                    child: Text(
                                      'Maintenance ${formatTimestamp(d['maintenanceStart'])}'
                                      '${d['maintenanceEnd'] is Timestamp ? ' → ${formatTimestamp(d['maintenanceEnd'])}' : ''}',
                                      style: TextStyle(
                                        fontSize: FontSizes.caption,
                                        color: t.warning.fg,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: Insets.lg),
                          Wrap(
                            spacing: Insets.sm,
                            children: [
                              ConsoleButton(
                                label: 'Edit',
                                icon: Icons.edit_outlined,
                                kind: ConsoleButtonKind.secondary,
                                onPressed: () => _compose(id: doc.id, existing: d),
                              ),
                              if (published)
                                ConsoleButton(
                                  label: 'Withdraw',
                                  icon: Icons.unpublished_outlined,
                                  kind: ConsoleButtonKind.ghost,
                                  onPressed: () =>
                                      _withdraw(doc.id, (d['title'] ?? '').toString()),
                                ),
                            ],
                          ),
                        ],
                      ),
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

class _ComposeAnnouncementDialog extends StatefulWidget {
  final String? announcementId;
  final Map<String, dynamic>? existing;

  const _ComposeAnnouncementDialog({this.announcementId, this.existing});

  @override
  State<_ComposeAnnouncementDialog> createState() => _ComposeAnnouncementDialogState();
}

class _ComposeAnnouncementDialogState extends State<_ComposeAnnouncementDialog> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  String _category = AnnouncementCategory.update;
  DateTime? _start;
  DateTime? _end;
  bool _busy = false;
  String? _titleError;
  String? _bodyError;
  String? _submitError;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e != null) {
      _title.text = (e['title'] ?? '').toString();
      _body.text = (e['body'] ?? '').toString();
      _category = (e['category'] ?? AnnouncementCategory.update).toString();
      if (e['maintenanceStart'] is Timestamp) {
        _start = (e['maintenanceStart'] as Timestamp).toDate();
      }
      if (e['maintenanceEnd'] is Timestamp) {
        _end = (e['maintenanceEnd'] as Timestamp).toDate();
      }
    }
  }

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    super.dispose();
  }

  Future<void> _pickWindow(bool isStart) async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: (isStart ? _start : _end) ?? now,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime((isStart ? _start : _end) ?? now),
    );
    if (!mounted) return;
    final picked = DateTime(
      date.year,
      date.month,
      date.day,
      time?.hour ?? 0,
      time?.minute ?? 0,
    );
    setState(() => isStart ? _start = picked : _end = picked);
  }

  Future<void> _publish() async {
    setState(() {
      _titleError = _title.text.trim().length < 4 ? 'Give the announcement a clear title.' : null;
      _bodyError = _body.text.trim().length < 10
          ? 'Say what is changing and when, in at least a sentence.'
          : null;
      _submitError = null;
    });
    if (_titleError != null || _bodyError != null) return;
    if (_category == AnnouncementCategory.maintenance && _start == null) {
      setState(() => _submitError = 'A maintenance announcement needs a start time.');
      return;
    }
    if (_start != null && _end != null && !_end!.isAfter(_start!)) {
      setState(() => _submitError = 'The maintenance window must end after it starts.');
      return;
    }

    setState(() => _busy = true);
    try {
      await PlatformActions.publishAnnouncement(
        announcementId: widget.announcementId,
        title: _title.text.trim(),
        body: _body.text.trim(),
        category: _category,
        maintenanceStart: _start,
        maintenanceEnd: _end,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) setState(() => _submitError = 'Could not publish: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final isMaintenance = _category == AnnouncementCategory.maintenance;

    return Dialog(
      backgroundColor: t.surface,
      shape: const RoundedRectangleBorder(borderRadius: Radii.card),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Insets.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.announcementId == null ? 'New announcement' : 'Edit announcement',
                style: TextStyle(
                  fontSize: FontSizes.title,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                  color: t.text,
                ),
              ),
              const SizedBox(height: Insets.xs),
              Text(
                'Goes to every school administrator\'s inbox. Nobody outside the '
                'platform sees it, and no recipient list is stored.',
                style: TextStyle(fontSize: FontSizes.body, height: 1.5, color: t.textMuted),
              ),
              const SizedBox(height: Insets.xl),
              ConsoleField(
                label: 'Category',
                child: DropdownMenu<String>(
                  initialSelection: _category,
                  width: 320,
                  onSelected: (v) => setState(() => _category = v ?? _category),
                  dropdownMenuEntries: AnnouncementCategory.all
                      .map((c) => DropdownMenuEntry(
                            value: c,
                            label: AnnouncementCategory.label(c),
                            leadingIcon: Icon(AnnouncementCategory.icon(c), size: 18),
                          ))
                      .toList(),
                ),
              ),
              const SizedBox(height: Insets.lg),
              ConsoleField(
                label: 'Title',
                required: true,
                errorText: _titleError,
                child: TextField(
                  controller: _title,
                  decoration: const InputDecoration(
                    hintText: 'e.g. Scheduled maintenance on Sunday evening',
                  ),
                ),
              ),
              const SizedBox(height: Insets.lg),
              ConsoleField(
                label: 'Message',
                required: true,
                errorText: _bodyError,
                helper: 'Plain language. Say what changes, when, and what the school '
                    'should do, if anything.',
                child: TextField(
                  controller: _body,
                  minLines: 4,
                  maxLines: 10,
                  decoration: const InputDecoration(
                    hintText: 'Trips created during the window may not sync until it ends…',
                  ),
                ),
              ),
              if (isMaintenance) ...[
                const SizedBox(height: Insets.lg),
                ConsoleField(
                  label: 'Maintenance window',
                  required: true,
                  helper: 'Shown to administrators alongside the message.',
                  child: Wrap(
                    spacing: Insets.sm,
                    runSpacing: Insets.sm,
                    children: [
                      ConsoleButton(
                        label: _start == null
                            ? 'Set start'
                            : 'Starts ${formatTimestamp(_start)}',
                        icon: Icons.play_arrow_rounded,
                        kind: ConsoleButtonKind.secondary,
                        onPressed: () => _pickWindow(true),
                      ),
                      ConsoleButton(
                        label: _end == null ? 'Set end' : 'Ends ${formatTimestamp(_end)}',
                        icon: Icons.stop_rounded,
                        kind: ConsoleButtonKind.secondary,
                        onPressed: () => _pickWindow(false),
                      ),
                    ],
                  ),
                ),
              ],
              if (_submitError != null) ...[
                const SizedBox(height: Insets.lg),
                Semantics(
                  liveRegion: true,
                  child: Text(
                    _submitError!,
                    style: TextStyle(fontSize: FontSizes.body, color: t.danger.fg),
                  ),
                ),
              ],
              const SizedBox(height: Insets.xl),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  ConsoleButton(
                    label: 'Cancel',
                    kind: ConsoleButtonKind.ghost,
                    onPressed: _busy ? null : () => Navigator.of(context).pop(false),
                  ),
                  const SizedBox(width: Insets.sm),
                  ConsoleButton(
                    label: widget.announcementId == null ? 'Publish' : 'Save changes',
                    icon: Icons.campaign_rounded,
                    busy: _busy,
                    onPressed: _busy ? null : _publish,
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
