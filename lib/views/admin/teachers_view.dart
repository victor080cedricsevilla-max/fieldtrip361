import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../config/theme.dart';
import '../../utils/staff_service.dart';

/// The school's staff list, and the only way onto it.
///
/// A teacher cannot sign themselves up — a facilitator sees where children are,
/// so the school decides who becomes one. An administrator invites a named
/// person at an address they choose, and the account arrives already attached
/// to this school. Removing someone ends that attachment and leaves the account
/// standing, because last term's attendance records name the person who took
/// them and must keep doing so.
class TeachersView extends StatelessWidget {
  const TeachersView({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                "Only people you invite can become facilitators at this school.",
                style: TextStyle(fontSize: 13.5, color: Color(0xFF6B7280)),
              ),
            ),
            ElevatedButton.icon(
              onPressed: () => _showInviteDialog(context),
              icon: const Icon(Icons.person_add_alt_1_rounded, size: 18),
              label: const Text("Invite teacher"),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.effectivePrimary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        Expanded(
          child: ListView(
            children: const [
              _PendingInvites(),
              SizedBox(height: 26),
              _StaffList(),
            ],
          ),
        ),
      ],
    );
  }

  static Future<void> _showInviteDialog(BuildContext context) async {
    final nameCtrl = TextEditingController();
    final emailCtrl = TextEditingController();

    await showDialog<void>(
      context: context,
      builder: (dlgCtx) => _InviteDialog(nameCtrl: nameCtrl, emailCtrl: emailCtrl),
    );
  }
}

// ── Invite dialog ─────────────────────────────────────────────────────────────

class _InviteDialog extends StatefulWidget {
  final TextEditingController nameCtrl;
  final TextEditingController emailCtrl;
  const _InviteDialog({required this.nameCtrl, required this.emailCtrl});

  @override
  State<_InviteDialog> createState() => _InviteDialogState();
}

class _InviteDialogState extends State<_InviteDialog> {
  bool _busy = false;
  String? _error;

  Future<void> _send() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await StaffService.invite(
        name: widget.nameCtrl.text.trim(),
        email: widget.emailCtrl.text.trim(),
      );
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("Invitation sent to ${widget.emailCtrl.text.trim()}."),
        backgroundColor: Colors.green,
      ));
    } catch (e) {
      if (mounted) setState(() => _error = StaffService.describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text("Invite a teacher"),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "The code goes to this address and nowhere else, so use the school "
              "address you already hold for them.",
              style: TextStyle(fontSize: 13, height: 1.45, color: Color(0xFF6B7280)),
            ),
            const SizedBox(height: 18),
            TextField(
              controller: widget.nameCtrl,
              textCapitalization: TextCapitalization.words,
              autofocus: true,
              decoration: InputDecoration(
                labelText: "Full name",
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: widget.emailCtrl,
              keyboardType: TextInputType.emailAddress,
              decoration: InputDecoration(
                labelText: "School email address",
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 14),
              Text(_error!,
                  style: const TextStyle(fontSize: 13, color: Color(0xFF9B2C20), height: 1.4)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("Cancel")),
        ElevatedButton(
          onPressed: _busy ? null : _send,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
              : const Text("Send invitation"),
        ),
      ],
    );
  }
}

// ── Outstanding invitations ───────────────────────────────────────────────────

class _PendingInvites extends StatelessWidget {
  const _PendingInvites();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: StaffService.invites(),
      builder: (context, snap) {
        final pending = (snap.data?.docs ?? const [])
            .where((d) => (d.data()['status'] ?? '') == 'unused')
            .toList()
          ..sort((a, b) {
            final at = a.data()['createdAt'] as Timestamp?;
            final bt = b.data()['createdAt'] as Timestamp?;
            return (bt?.millisecondsSinceEpoch ?? 0)
                .compareTo(at?.millisecondsSinceEpoch ?? 0);
          });

        if (pending.isEmpty) return const SizedBox.shrink();

        return _Card(
          title: "Waiting to be accepted",
          subtitle: "${pending.length} invitation${pending.length == 1 ? '' : 's'} sent, not yet used",
          child: Column(
            children: [
              for (final d in pending) _InviteRow(doc: d),
            ],
          ),
        );
      },
    );
  }
}

class _InviteRow extends StatelessWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  const _InviteRow({required this.doc});

  @override
  Widget build(BuildContext context) {
    final d = doc.data();
    final expires = d['expiresAt'] as Timestamp?;
    final expired = expires != null && expires.toDate().isBefore(DateTime.now());

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: const Color(0xFFFEF3C7),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.hourglass_top_rounded,
                size: 18, color: Color(0xFF92400E)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text((d['name'] ?? '').toString(),
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                Text(
                  expired
                      ? "${d['email']} · expired"
                      : "${d['email']}",
                  style: TextStyle(
                      fontSize: 12.5,
                      color: expired ? const Color(0xFF9B2C20) : Colors.grey.shade500),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () async {
              try {
                await StaffService.revokeInvite(doc.id);
              } catch (e) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(StaffService.describeError(e))),
                );
              }
            },
            child: const Text("Withdraw", style: TextStyle(color: Color(0xFF9B2C20))),
          ),
        ],
      ),
    );
  }
}

// ── Current staff ─────────────────────────────────────────────────────────────

class _StaffList extends StatelessWidget {
  const _StaffList();

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: StaffService.teachers(),
      builder: (context, snap) {
        if (!snap.hasData) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: CircularProgressIndicator(color: AppTheme.effectivePrimary),
            ),
          );
        }
        final docs = snap.data!.docs;

        return _Card(
          title: "Facilitators",
          subtitle: docs.isEmpty
              ? "Nobody has accepted an invitation yet"
              : "${docs.length} teacher${docs.length == 1 ? '' : 's'} on staff",
          child: docs.isEmpty
              ? Padding(
                  padding: const EdgeInsets.symmetric(vertical: 26),
                  child: Column(
                    children: [
                      Icon(Icons.groups_outlined, size: 40, color: Colors.grey.shade300),
                      const SizedBox(height: 10),
                      Text("Invite a teacher to get started.",
                          style: TextStyle(color: Colors.grey.shade500, fontSize: 13)),
                    ],
                  ),
                )
              : Column(
                  children: [for (final d in docs) _TeacherRow(doc: d)],
                ),
        );
      },
    );
  }
}

class _TeacherRow extends StatelessWidget {
  final QueryDocumentSnapshot<Map<String, dynamic>> doc;
  const _TeacherRow({required this.doc});

  Future<void> _remove(BuildContext context) async {
    final reasonCtrl = TextEditingController();
    final name = (doc.data()['name'] ?? 'This teacher').toString();

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text("Remove $name?"),
        content: SizedBox(
          width: 380,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "They lose access to this school's trips, students and documents "
                "straight away. Their account stays, so past attendance records "
                "still show who took them, and another school can invite them.",
                style: TextStyle(fontSize: 13, height: 1.45, color: Color(0xFF6B7280)),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: reasonCtrl,
                decoration: InputDecoration(
                  labelText: "Reason (optional)",
                  hintText: "e.g. resigned, transferred",
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFB3261E)),
            child: const Text("Remove"),
          ),
        ],
      ),
    );

    if (ok != true) return;
    try {
      await StaffService.removeFromSchool(uid: doc.id, reason: reasonCtrl.text.trim());
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("$name was removed from your school."), backgroundColor: Colors.green),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(StaffService.describeError(e)), backgroundColor: AppTheme.errorColor),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final d = doc.data();
    final name = (d['name'] ?? 'Teacher').toString();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          CircleAvatar(
            radius: 19,
            backgroundColor: AppTheme.effectivePrimary.withValues(alpha: 0.12),
            child: Text(
              name.isNotEmpty ? name[0].toUpperCase() : '?',
              style: TextStyle(
                  color: AppTheme.effectivePrimary, fontWeight: FontWeight.bold, fontSize: 15),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                Text((d['email'] ?? '').toString(),
                    style: TextStyle(fontSize: 12.5, color: Colors.grey.shade500)),
              ],
            ),
          ),
          IconButton(
            tooltip: "Remove from school",
            icon: const Icon(Icons.person_remove_outlined, size: 19),
            color: const Color(0xFFB3261E),
            onPressed: () => _remove(context),
          ),
        ],
      ),
    );
  }
}

// ── Shared card ───────────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;
  const _Card({required this.title, required this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  fontSize: 16, fontWeight: FontWeight.bold, color: AppTheme.darkText)),
          const SizedBox(height: 2),
          Text(subtitle, style: TextStyle(fontSize: 12.5, color: Colors.grey.shade500)),
          const Divider(height: 24, color: Color(0xFFF3F4F6)),
          child,
        ],
      ),
    );
  }
}
