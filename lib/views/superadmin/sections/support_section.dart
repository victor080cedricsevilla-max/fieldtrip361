import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../config/console_theme.dart';
import '../super_admin_data.dart';
import '../widgets/console_ui.dart';

/// Support tickets raised from any of the four apps.
///
/// The console shows the requester's name, role, school and what they chose to
/// write in the ticket — the minimum needed to answer them. It is not a route
/// into their profile or their school's records, and no rule here grants one.
class SupportSection extends StatefulWidget {
  const SupportSection({super.key});

  @override
  State<SupportSection> createState() => _SupportSectionState();
}

class _SupportSectionState extends State<SupportSection> {
  final _search = TextEditingController();
  String _query = '';
  String _filter = 'unresolved';
  String? _selectedId;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(Map<String, dynamic> d) {
    final status = (d['status'] ?? '').toString();
    if (_filter == 'unresolved' && !TicketStatus.unresolved.contains(status)) return false;
    if (_filter != 'unresolved' && _filter != 'all' && status != _filter) return false;
    if (_query.isEmpty) return true;
    final requester = (d['requester'] ?? const {}) as Map;
    final hay = [
      d['subject'],
      d['reference'],
      d['description'],
      requester['name'],
      requester['email'],
      requester['schoolName'],
    ].map((v) => (v ?? '').toString().toLowerCase()).join(' ');
    return hay.contains(_query);
  }

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 1080;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Insets.xxl, Insets.xxl, Insets.xxl, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionHeader(
                title: 'Customer Support',
                subtitle: 'Questions and bug reports from administrators, teachers, '
                    'students and parents.',
              ),
              const SizedBox(height: Insets.lg),
              Wrap(
                spacing: Insets.md,
                runSpacing: Insets.md,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ConsoleSearchField(
                    controller: _search,
                    hint: 'Search subject, reference, requester',
                    onChanged: (v) => setState(() => _query = v.trim().toLowerCase()),
                  ),
                  DropdownMenu<String>(
                    initialSelection: _filter,
                    label: const Text('Status'),
                    onSelected: (v) => setState(() => _filter = v ?? 'unresolved'),
                    dropdownMenuEntries: [
                      const DropdownMenuEntry(value: 'unresolved', label: 'Unresolved'),
                      const DropdownMenuEntry(value: 'all', label: 'All tickets'),
                      ...TicketStatus.all.map(
                        (s) => DropdownMenuEntry(value: s, label: TicketStatus.label(s)),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: Insets.lg),
            ],
          ),
        ),
        Expanded(
          child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
            stream: PlatformQueries.allTickets().limit(100).snapshots(),
            builder: (context, snap) {
              if (snap.hasError) {
                return ConsoleErrorState(
                  title: 'Tickets could not be loaded',
                  message: 'Check your connection and try again.',
                  technicalDetail: snap.error.toString(),
                  onRetry: () => setState(() {}),
                );
              }
              if (!snap.hasData) {
                return const Padding(
                  padding: EdgeInsets.symmetric(horizontal: Insets.xxl),
                  child: DelayedLoader(child: ConsoleSkeleton(rows: 5, rowHeight: 76)),
                );
              }

              final all = snap.data!.docs;
              final rows = all.where((d) => _matches(d.data())).toList();

              if (all.isEmpty) {
                return const ConsoleEmptyState(
                  icon: Icons.support_agent_outlined,
                  title: 'No support tickets yet',
                  message: 'Tickets raised from the web dashboard or any of the mobile '
                      'apps arrive here.',
                );
              }
              if (rows.isEmpty) {
                return ConsoleEmptyState(
                  icon: Icons.search_off_rounded,
                  title: 'No tickets match',
                  message: 'Try a different search term, or switch the status filter.',
                  action: ConsoleButton(
                    label: 'Show unresolved',
                    kind: ConsoleButtonKind.secondary,
                    onPressed: () => setState(() {
                      _search.clear();
                      _query = '';
                      _filter = 'unresolved';
                    }),
                  ),
                );
              }

              final selected = rows.firstWhere(
                (d) => d.id == _selectedId,
                orElse: () => rows.first,
              );

              if (!wide) {
                return ListView(
                  padding: const EdgeInsets.fromLTRB(
                      Insets.xxl, 0, Insets.xxl, Insets.huge),
                  children: rows
                      .map((doc) => Padding(
                            padding: const EdgeInsets.only(bottom: Insets.sm),
                            child: _TicketListTile(
                              doc: doc,
                              selected: false,
                              onTap: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (_) => Scaffold(
                                    backgroundColor: t.page,
                                    appBar: AppBar(
                                      title: Text((doc.data()['subject'] ?? 'Ticket').toString()),
                                    ),
                                    body: _TicketThread(ticketId: doc.id, ticket: doc.data()),
                                  ),
                                ),
                              ),
                            ),
                          ))
                      .toList(),
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: 380,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(
                          Insets.xxl, 0, Insets.lg, Insets.huge),
                      children: rows
                          .map((doc) => Padding(
                                padding: const EdgeInsets.only(bottom: Insets.sm),
                                child: _TicketListTile(
                                  doc: doc,
                                  selected: doc.id == selected.id,
                                  onTap: () => setState(() => _selectedId = doc.id),
                                ),
                              ))
                          .toList(),
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(0, 0, Insets.xxl, Insets.xxl),
                      child: _TicketThread(
                        key: ValueKey(selected.id),
                        ticketId: selected.id,
                        ticket: selected.data(),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _TicketListTile extends StatelessWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  final bool selected;
  final VoidCallback onTap;

  const _TicketListTile({required this.doc, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final d = doc.data();
    final status = (d['status'] ?? '').toString();
    final requester = (d['requester'] ?? const {}) as Map;
    final unread = d['unreadForSupport'] == true;

    return ConsoleCard(
      onTap: onTap,
      accent: selected ? t.brand : null,
      padding: const EdgeInsets.all(Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (unread)
                Container(
                  width: 8,
                  height: 8,
                  margin: const EdgeInsets.only(right: Insets.sm),
                  decoration: BoxDecoration(color: t.brand, shape: BoxShape.circle),
                ),
              Expanded(
                child: Text(
                  (d['subject'] ?? 'Untitled').toString(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: FontSizes.body,
                    fontWeight: unread ? FontWeight.w700 : FontWeight.w600,
                    color: t.text,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: Insets.xs),
          Text(
            '${requester['role'] ?? 'user'} · ${requester['schoolName'] ?? 'No school'}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: FontSizes.caption, color: t.textMuted),
          ),
          const SizedBox(height: Insets.sm),
          Row(
            children: [
              StatusBadge(
                label: TicketStatus.label(status),
                tone: TicketStatus.tone(t, status),
                icon: TicketStatus.icon(status),
                dense: true,
              ),
              const Spacer(),
              Text(
                relativeTime(d['lastMessageAt'] ?? d['createdAt']),
                style: TextStyle(fontSize: 11, color: t.textFaint),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TicketThread extends StatefulWidget {
  final String ticketId;
  final Map<String, dynamic> ticket;

  const _TicketThread({super.key, required this.ticketId, required this.ticket});

  @override
  State<_TicketThread> createState() => _TicketThreadState();
}

class _TicketThreadState extends State<_TicketThread> {
  final _reply = TextEditingController();
  bool _sending = false;
  String? _error;
  String? _nextStatus;

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _reply.text.trim();
    if (text.length < 2) {
      setState(() => _error = 'Write a reply before sending.');
      return;
    }
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await PlatformActions.replyToTicket(
        ticketId: widget.ticketId,
        text: text,
        newStatus: _nextStatus,
      );
      _reply.clear();
      if (mounted) setState(() => _nextStatus = null);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not send the reply: $e');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _setStatus(String status) async {
    try {
      await PlatformActions.setTicketStatus(ticketId: widget.ticketId, status: status);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not change the status: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final d = widget.ticket;
    final requester = (d['requester'] ?? const {}) as Map;
    final status = (d['status'] ?? '').toString();
    final attachments = (d['attachments'] as List?) ?? const [];

    return ConsoleCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(Insets.xl),
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
                            (d['subject'] ?? 'Untitled').toString(),
                            style: TextStyle(
                              fontSize: FontSizes.title,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                              color: t.text,
                            ),
                          ),
                          const SizedBox(height: Insets.xs),
                          Text(
                            '${d['reference'] ?? '—'} · '
                            '${TicketCategory.label((d['category'] ?? '').toString())} · '
                            'opened ${relativeTime(d['createdAt'])}',
                            style: TextStyle(
                              fontSize: FontSizes.caption,
                              color: t.textMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: Insets.md),
                    DropdownMenu<String>(
                      initialSelection: status,
                      width: 220,
                      label: const Text('Status'),
                      onSelected: (v) {
                        if (v != null && v != status) _setStatus(v);
                      },
                      dropdownMenuEntries: TicketStatus.all
                          .map((s) => DropdownMenuEntry(
                                value: s,
                                label: TicketStatus.label(s),
                                leadingIcon: Icon(TicketStatus.icon(s), size: 18),
                              ))
                          .toList(),
                    ),
                  ],
                ),
                const SizedBox(height: Insets.lg),
                _RequesterCard(requester: requester, tokens: t),
                const SizedBox(height: Insets.lg),
                Text(
                  (d['description'] ?? '').toString(),
                  style: TextStyle(fontSize: FontSizes.body, height: 1.6, color: t.text),
                ),
                if (attachments.isNotEmpty) ...[
                  const SizedBox(height: Insets.md),
                  Wrap(
                    spacing: Insets.sm,
                    runSpacing: Insets.sm,
                    children: attachments.map((a) {
                      final att = a as Map;
                      return ConsoleButton(
                        label: (att['fileName'] ?? 'Attachment').toString(),
                        icon: Icons.attach_file_rounded,
                        kind: ConsoleButtonKind.secondary,
                        onPressed: () {
                          final url = (att['downloadUrl'] ?? '').toString();
                          if (url.isNotEmpty) launchUrl(Uri.parse(url));
                        },
                      );
                    }).toList(),
                  ),
                ],
              ],
            ),
          ),
          Divider(height: 1, color: t.border),
          Flexible(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: PlatformQueries.ticketMessages(widget.ticketId).snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Padding(
                    padding: const EdgeInsets.all(Insets.xl),
                    child: Text(
                      'The conversation could not be loaded.',
                      style: TextStyle(fontSize: FontSizes.body, color: t.danger.fg),
                    ),
                  );
                }
                if (!snap.hasData) {
                  return const Padding(
                    padding: EdgeInsets.all(Insets.xl),
                    child: DelayedLoader(child: ConsoleSkeleton(rows: 2, rowHeight: 48)),
                  );
                }
                final msgs = snap.data!.docs;
                if (msgs.isEmpty) {
                  return Padding(
                    padding: const EdgeInsets.all(Insets.xl),
                    child: Text(
                      'No replies yet. Your first reply starts the conversation.',
                      style: TextStyle(fontSize: FontSizes.body, color: t.textMuted),
                    ),
                  );
                }
                return ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.all(Insets.xl),
                  children: msgs.map((m) {
                    final md = m.data();
                    final fromSupport = md['senderSide'] == 'support';
                    return Padding(
                      padding: const EdgeInsets.only(bottom: Insets.md),
                      child: Align(
                        alignment:
                            fromSupport ? Alignment.centerRight : Alignment.centerLeft,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 520),
                          child: Container(
                            padding: const EdgeInsets.all(Insets.md),
                            decoration: BoxDecoration(
                              color: fromSupport ? t.info.bg : t.surfaceMuted,
                              border: Border.all(
                                  color: fromSupport ? t.info.border : t.border),
                              borderRadius: Radii.control,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  fromSupport ? 'FieldTrip360 support' : 'Requester',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: fromSupport ? t.info.fg : t.textMuted,
                                  ),
                                ),
                                const SizedBox(height: Insets.xs),
                                Text(
                                  (md['text'] ?? '').toString(),
                                  style: TextStyle(
                                    fontSize: FontSizes.body,
                                    height: 1.55,
                                    color: t.text,
                                  ),
                                ),
                                const SizedBox(height: Insets.xs),
                                Text(
                                  formatTimestamp(md['createdAt']),
                                  style: TextStyle(fontSize: 11, color: t.textFaint),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ),
          Divider(height: 1, color: t.border),
          Padding(
            padding: const EdgeInsets.all(Insets.xl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ConsoleField(
                  label: 'Reply',
                  errorText: _error,
                  child: TextField(
                    controller: _reply,
                    minLines: 3,
                    maxLines: 6,
                    decoration: const InputDecoration(
                      hintText: 'Answer the question, or say what you need from them.',
                    ),
                  ),
                ),
                const SizedBox(height: Insets.md),
                Wrap(
                  spacing: Insets.sm,
                  runSpacing: Insets.sm,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ConsoleButton(
                      label: 'Send reply',
                      icon: Icons.send_rounded,
                      busy: _sending,
                      onPressed: _sending ? null : _send,
                    ),
                    DropdownMenu<String>(
                      initialSelection: _nextStatus ?? status,
                      width: 240,
                      label: const Text('Set status on send'),
                      onSelected: (v) => setState(() => _nextStatus = v),
                      dropdownMenuEntries: TicketStatus.all
                          .map((s) => DropdownMenuEntry(
                                value: s,
                                label: TicketStatus.label(s),
                              ))
                          .toList(),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RequesterCard extends StatelessWidget {
  final Map requester;
  final ConsoleTokens tokens;

  const _RequesterCard({required this.requester, required this.tokens});

  @override
  Widget build(BuildContext context) {
    final t = tokens;
    return Container(
      padding: const EdgeInsets.all(Insets.md),
      decoration: BoxDecoration(
        color: t.surfaceMuted,
        border: Border.all(color: t.border),
        borderRadius: Radii.control,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.person_outline_rounded, size: 18, color: t.textFaint),
          const SizedBox(width: Insets.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (requester['name'] ?? 'Requester').toString(),
                  style: TextStyle(
                    fontSize: FontSizes.body,
                    fontWeight: FontWeight.w600,
                    color: t.text,
                  ),
                ),
                Text(
                  [
                    requester['role'] ?? 'user',
                    if ((requester['schoolName'] ?? '').toString().isNotEmpty)
                      requester['schoolName'],
                    if ((requester['email'] ?? '').toString().isNotEmpty) requester['email'],
                  ].join(' · '),
                  style: TextStyle(fontSize: FontSizes.caption, color: t.textMuted),
                ),
                const SizedBox(height: Insets.xs),
                Text(
                  'This is everything the ticket carries. Opening a ticket does not '
                  'grant access to their profile or their school\'s records.',
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.45,
                    color: t.textFaint,
                    fontStyle: FontStyle.italic,
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
