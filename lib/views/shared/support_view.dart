import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../config/theme.dart';
import '../../utils/support_service.dart';

/// Contact support, shared by the admin, teacher, student and parent apps.
///
/// The same screen serves all four because a support request is the same act in
/// each: say what is wrong, and read the reply. Nothing here is role-specific,
/// and nothing here reveals another person's conversation — the list is scoped
/// to this account's own tickets, which is also all the security rule allows.
class SupportView extends StatelessWidget {
  const SupportView({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        title: const Text('Help & support'),
        backgroundColor: Colors.white,
        foregroundColor: AppTheme.darkText,
        elevation: 0.5,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _compose(context),
        backgroundColor: AppTheme.effectivePrimary,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add_comment_outlined),
        label: const Text('New request'),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: SupportService.myTickets(),
        builder: (context, snap) {
          if (snap.hasError) {
            return const _Centered(
              icon: Icons.error_outline_rounded,
              title: 'Your requests could not be loaded',
              detail: 'Check your connection and try again.',
            );
          }
          if (!snap.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          final docs = snap.data!.docs;
          if (docs.isEmpty) {
            return const _Centered(
              icon: Icons.support_agent_rounded,
              title: 'No requests yet',
              detail:
                  'Send one and it reaches the FieldTrip360 team directly. '
                  'Your reply arrives here.',
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const SizedBox(height: 10),
            itemBuilder: (context, i) => _TicketTile(doc: docs[i]),
          );
        },
      ),
    );
  }

  static Future<void> _compose(BuildContext context) async {
    final reference = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _ComposeSheet(),
    );
    if (reference != null && reference.isNotEmpty && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Request $reference sent.')),
      );
    }
  }
}

class _Centered extends StatelessWidget {
  final IconData icon;
  final String title;
  final String detail;

  const _Centered({
    required this.icon,
    required this.title,
    required this.detail,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: const Color(0xFFD1D5DB)),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppTheme.darkText,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              detail,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  fontSize: 13.5, height: 1.5, color: Color(0xFF6B7280)),
            ),
          ],
        ),
      ),
    );
  }
}

class _TicketTile extends StatelessWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;

  const _TicketTile({required this.doc});

  @override
  Widget build(BuildContext context) {
    final d = doc.data();
    final status = (d['status'] ?? 'open').toString();
    final unread = d['unreadForRequester'] == true;
    final colour = _statusColour(status);

    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () {
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => _ThreadView(ticketId: doc.id, subject: (d['subject'] ?? '').toString()),
          ));
        },
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: unread ? AppTheme.effectivePrimary : const Color(0xFFE5E7EB),
              width: unread ? 1.4 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: colour.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      SupportService.statusLabels[status] ?? status,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: colour,
                      ),
                    ),
                  ),
                  const Spacer(),
                  Text(
                    (d['reference'] ?? '').toString(),
                    style: const TextStyle(
                        fontSize: 11.5,
                        color: Color(0xFF9CA3AF),
                        fontWeight: FontWeight.w600),
                  ),
                  if (unread) ...[
                    const SizedBox(width: 8),
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: AppTheme.effectivePrimary,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 8),
              Text(
                (d['subject'] ?? '').toString(),
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: AppTheme.darkText,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                (d['description'] ?? '').toString(),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13, height: 1.4, color: Color(0xFF6B7280)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  static Color _statusColour(String status) {
    switch (status) {
      case 'resolved':
        return const Color(0xFF10B981);
      case 'closed':
        return const Color(0xFF6B7280);
      case 'waiting_for_requester':
        return const Color(0xFFF59E0B);
      case 'in_progress':
        return const Color(0xFF3B82F6);
      default:
        return AppTheme.primaryColor;
    }
  }
}

/// The new-request form.
///
/// Subject, category and description only. A support request must never become
/// a place where a student's records are re-entered by hand, so nothing here
/// asks for them.
class _ComposeSheet extends StatefulWidget {
  const _ComposeSheet();

  @override
  State<_ComposeSheet> createState() => _ComposeSheetState();
}

class _ComposeSheetState extends State<_ComposeSheet> {
  final _subject = TextEditingController();
  final _description = TextEditingController();
  String _category = 'question';
  bool _sending = false;
  String? _error;

  @override
  void dispose() {
    _subject.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      final reference = await SupportService.create(
        subject: _subject.text.trim(),
        category: _category,
        description: _description.text.trim(),
      );
      if (mounted) Navigator.of(context).pop(reference);
    } catch (e) {
      if (mounted) {
        setState(() => _error = SupportService.describeError(e));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canSend = _subject.text.trim().length >= 4 &&
        _description.text.trim().length >= 10 &&
        !_sending;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Container(
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Center(
                child: Container(
                  width: 38,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE5E7EB),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'New request',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.darkText,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _subject,
                textCapitalization: TextCapitalization.sentences,
                maxLength: 160,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'Subject',
                  hintText: 'In a few words, what is this about?',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
              const SizedBox(height: 14),
              DropdownButtonFormField<String>(
                initialValue: _category,
                decoration: const InputDecoration(
                  labelText: 'Category',
                  border: OutlineInputBorder(),
                ),
                items: SupportService.categories.entries
                    .map((e) =>
                        DropdownMenuItem(value: e.key, child: Text(e.value)))
                    .toList(),
                onChanged: (v) => setState(() => _category = v ?? 'question'),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _description,
                maxLines: 5,
                maxLength: 5000,
                textCapitalization: TextCapitalization.sentences,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: 'What do you need help with?',
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: const TextStyle(
                      color: AppTheme.errorColor, fontSize: 13),
                ),
              ],
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: canSend ? _send : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.effectivePrimary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                  child: _sending
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Send request',
                          style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One conversation: the original request, then every reply in order.
class _ThreadView extends StatefulWidget {
  final String ticketId;
  final String subject;

  const _ThreadView({required this.ticketId, required this.subject});

  @override
  State<_ThreadView> createState() => _ThreadViewState();
}

class _ThreadViewState extends State<_ThreadView> {
  final _reply = TextEditingController();
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    SupportService.markRead(widget.ticketId);
  }

  @override
  void dispose() {
    _reply.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _reply.text.trim();
    if (text.length < 2) return;
    setState(() => _sending = true);
    try {
      await SupportService.reply(ticketId: widget.ticketId, text: text);
      _reply.clear();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(SupportService.describeError(e))),
        );
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF9FAFB),
      appBar: AppBar(
        title: Text(widget.subject, overflow: TextOverflow.ellipsis),
        backgroundColor: Colors.white,
        foregroundColor: AppTheme.darkText,
        elevation: 0.5,
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: SupportService.messages(widget.ticketId),
              builder: (context, snap) {
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final docs = snap.data!.docs;
                if (docs.isEmpty) {
                  return const _Centered(
                    icon: Icons.mark_email_unread_outlined,
                    title: 'Sent',
                    detail: 'No reply yet. You will see it here.',
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: docs.length,
                  itemBuilder: (context, i) => _Bubble(data: docs[i].data()),
                );
              },
            ),
          ),
          Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
            child: SafeArea(
              top: false,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: _reply,
                      minLines: 1,
                      maxLines: 4,
                      maxLength: 5000,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: 'Write a reply',
                        counterText: '',
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(22),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 10),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filled(
                    onPressed: _sending ? null : _send,
                    style: IconButton.styleFrom(
                      backgroundColor: AppTheme.effectivePrimary,
                      foregroundColor: Colors.white,
                    ),
                    icon: _sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.white),
                          )
                        : const Icon(Icons.send_rounded, size: 20),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  final Map<String, dynamic> data;

  const _Bubble({required this.data});

  @override
  Widget build(BuildContext context) {
    final fromSupport = (data['senderSide'] ?? '') == 'support';
    return Align(
      alignment: fromSupport ? Alignment.centerLeft : Alignment.centerRight,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.78,
        ),
        decoration: BoxDecoration(
          color: fromSupport ? Colors.white : AppTheme.effectivePrimary,
          borderRadius: BorderRadius.circular(14),
          border: fromSupport
              ? Border.all(color: const Color(0xFFE5E7EB))
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (fromSupport)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(
                  (data['senderName'] ?? 'FieldTrip360 support').toString(),
                  style: const TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF6B7280),
                  ),
                ),
              ),
            Text(
              (data['text'] ?? '').toString(),
              style: TextStyle(
                fontSize: 14,
                height: 1.45,
                color: fromSupport ? const Color(0xFF374151) : Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
