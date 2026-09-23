import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../config/theme.dart';

/// Platform announcements, for the school administrator who receives them.
///
/// A published announcement carries no recipient list — that is deliberate, so
/// one school can never learn who else subscribes. Which announcements *this*
/// administrator has opened is therefore kept per user, under
/// `users/{uid}/announcementReads`, and the unread count is the difference
/// between the two streams rather than a counter anyone maintains.
class AnnouncementBell extends StatelessWidget {
  const AnnouncementBell({super.key});

  static const _pageSize = 25;

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const SizedBox.shrink();
    final db = FirebaseFirestore.instance;

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: db
          .collection('announcements')
          .where('status', isEqualTo: 'published')
          .orderBy('publishedAt', descending: true)
          .limit(_pageSize)
          .snapshots(),
      builder: (context, annSnap) {
        final announcements = annSnap.data?.docs ?? const [];

        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: db
              .collection('users')
              .doc(uid)
              .collection('announcementReads')
              .snapshots(),
          builder: (context, readSnap) {
            final readDocs = readSnap.data?.docs ??
                const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
            final read = <String>{for (final d in readDocs) d.id};
            final unread =
                announcements.where((d) => !read.contains(d.id)).length;

            return _BellButton(
              unread: unread,
              // An empty list is still worth opening: it is how an admin sees
              // that there is nothing, rather than wondering whether the bell
              // works at all.
              onPressed: () => _open(context, uid, announcements, read),
            );
          },
        );
      },
    );
  }

  void _open(
    BuildContext context,
    String uid,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> announcements,
    Set<String> read,
  ) {
    showDialog<void>(
      context: context,
      builder: (_) => _AnnouncementDialog(
        uid: uid,
        announcements: announcements,
        initiallyRead: read,
      ),
    );
  }
}

class _BellButton extends StatelessWidget {
  final int unread;
  final VoidCallback onPressed;

  const _BellButton({required this.unread, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: unread == 0
          ? 'Announcements'
          : '$unread unread announcement${unread == 1 ? '' : 's'}',
      onPressed: onPressed,
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.notifications_none_rounded,
              color: Color(0xFF6B7280), size: 26),
          if (unread > 0)
            Positioned(
              right: -3,
              top: -3,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                constraints: const BoxConstraints(minWidth: 17),
                decoration: BoxDecoration(
                  color: AppTheme.errorColor,
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(color: Colors.white, width: 1.5),
                ),
                child: Text(
                  unread > 9 ? '9+' : '$unread',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    height: 1.3,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The panel behind the bell.
///
/// An announcement is marked read when it is expanded, not when the panel is
/// opened: glancing at a list of titles is not the same as having read the
/// notice, and the unread badge should not lie about that.
class _AnnouncementDialog extends StatefulWidget {
  final String uid;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> announcements;
  final Set<String> initiallyRead;

  const _AnnouncementDialog({
    required this.uid,
    required this.announcements,
    required this.initiallyRead,
  });

  @override
  State<_AnnouncementDialog> createState() => _AnnouncementDialogState();
}

class _AnnouncementDialogState extends State<_AnnouncementDialog> {
  String? _expandedId;
  late final Set<String> _read = {...widget.initiallyRead};

  static const _categoryLabels = <String, String>{
    'maintenance': 'Maintenance',
    'feature': 'New feature',
    'update': 'Update',
    'policy': 'Policy',
  };

  static const _categoryColors = <String, Color>{
    'maintenance': Color(0xFFF59E0B),
    'feature': Color(0xFF00C4B4),
    'update': Color(0xFF3B82F6),
    'policy': Color(0xFF8B5CF6),
  };

  Future<void> _markRead(String id) async {
    if (_read.contains(id)) return;
    setState(() => _read.add(id));
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.uid)
          .collection('announcementReads')
          .doc(id)
          .set({'readAt': FieldValue.serverTimestamp()});
    } catch (_) {
      // Losing the read marker only means the badge reappears next time, which
      // is the harmless direction to fail in. Nothing here is worth interrupting
      // the administrator with.
      if (mounted) setState(() => _read.remove(id));
    }
  }

  String _when(Timestamp? ts) {
    if (ts == null) return '';
    final d = ts.toDate();
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.announcements;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520, maxHeight: 560),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
              child: Row(
                children: [
                  const Icon(Icons.campaign_outlined,
                      color: Color(0xFF6B7280), size: 22),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Announcements',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.darkText,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close_rounded, size: 20),
                    color: const Color(0xFF9CA3AF),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Color(0xFFE5E7EB)),
            Flexible(
              child: items.isEmpty
                  ? const Padding(
                      padding:
                          EdgeInsets.symmetric(vertical: 48, horizontal: 24),
                      child: Text(
                        'Nothing has been announced yet.',
                        textAlign: TextAlign.center,
                        style:
                            TextStyle(color: Color(0xFF6B7280), fontSize: 14),
                      ),
                    )
                  : ListView.separated(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      itemCount: items.length,
                      separatorBuilder: (_, __) =>
                          const Divider(height: 1, color: Color(0xFFF3F4F6)),
                      itemBuilder: (context, i) => _tile(items[i]),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(QueryDocumentSnapshot<Map<String, dynamic>> doc) {
    final d = doc.data();
    final id = doc.id;
    final isRead = _read.contains(id);
    final expanded = _expandedId == id;
    final category = (d['category'] ?? '').toString();
    final colour = _categoryColors[category] ?? const Color(0xFF6B7280);
    final start = d['maintenanceStart'] as Timestamp?;
    final end = d['maintenanceEnd'] as Timestamp?;

    return InkWell(
      onTap: () {
        setState(() => _expandedId = expanded ? null : id);
        if (!expanded) _markRead(id);
      },
      child: Container(
        color: isRead ? Colors.white : const Color(0xFFF0FDFA),
        padding: const EdgeInsets.fromLTRB(20, 14, 16, 14),
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
                    _categoryLabels[category] ?? 'Notice',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: colour,
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  _when(d['publishedAt'] as Timestamp?),
                  style:
                      const TextStyle(fontSize: 11.5, color: Color(0xFF9CA3AF)),
                ),
                if (!isRead) ...[
                  const SizedBox(width: 8),
                  Container(
                    width: 7,
                    height: 7,
                    decoration: const BoxDecoration(
                      color: AppTheme.primaryColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 7),
            Text(
              (d['title'] ?? '').toString(),
              style: TextStyle(
                fontSize: 14.5,
                fontWeight: isRead ? FontWeight.w600 : FontWeight.w700,
                color: AppTheme.darkText,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              (d['body'] ?? '').toString(),
              maxLines: expanded ? null : 2,
              overflow: expanded ? TextOverflow.clip : TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 13, height: 1.45, color: Color(0xFF4B5563)),
            ),
            if (expanded && start != null) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFFFFFBEB),
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(color: const Color(0xFFFDE68A)),
                ),
                child: Text(
                  end != null
                      ? 'Window: ${_when(start)} — ${_when(end)}'
                      : 'Starts: ${_when(start)}',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF92400E)),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
