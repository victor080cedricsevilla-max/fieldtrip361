import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../../config/theme.dart';

/// Notification data model stored at users/{uid}/notifications/{id}
class AppNotification {
  final String id;
  final String title;
  final String body;
  final String type;
  final String? tripId;
  final bool read;
  final DateTime? createdAt;

  const AppNotification({
    required this.id,
    required this.title,
    required this.body,
    required this.type,
    this.tripId,
    required this.read,
    this.createdAt,
  });

  factory AppNotification.fromDoc(DocumentSnapshot doc) {
    final d = doc.data() as Map<String, dynamic>;
    return AppNotification(
      id: doc.id,
      title: (d['title'] ?? '').toString(),
      body: (d['body'] ?? '').toString(),
      type: (d['type'] ?? 'trip_update').toString(),
      tripId: d['tripId']?.toString(),
      read: d['read'] == true,
      createdAt: (d['createdAt'] as Timestamp?)?.toDate(),
    );
  }
}

/// Bell icon button with unread badge — drop into any AppBar actions list.
class NotificationBell extends StatelessWidget {
  const NotificationBell({super.key});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const SizedBox.shrink();

    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('users')
          .doc(uid)
          .collection('notifications')
          .where('read', isEqualTo: false)
          .snapshots(),
      builder: (context, snap) {
        final unread = snap.data?.docs.length ?? 0;
        return Stack(
          clipBehavior: Clip.none,
          children: [
            IconButton(
              tooltip: 'Notifications',
              icon: const Icon(Icons.notifications_outlined, color: AppTheme.secondaryColor),
              onPressed: () => _showPanel(context, uid),
            ),
            if (unread > 0)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: const BoxDecoration(
                    color: Color(0xFF3B82F6),
                    shape: BoxShape.circle,
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    unread > 9 ? '9+' : '$unread',
                    style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  void _showPanel(BuildContext context, String uid) {
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'notifications',
      barrierColor: Colors.black38,
      transitionDuration: const Duration(milliseconds: 220),
      transitionBuilder: (ctx, a1, a2, child) {
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).animate(CurvedAnimation(parent: a1, curve: Curves.easeOutCubic)),
          child: child,
        );
      },
      pageBuilder: (ctx, a1, a2) => Align(
        alignment: Alignment.centerRight,
        child: NotificationPanel(uid: uid),
      ),
    );
  }
}

class NotificationPanel extends StatelessWidget {
  final String uid;
  const NotificationPanel({super.key, required this.uid});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        width: MediaQuery.of(context).size.width * 0.88,
        height: double.infinity,
        margin: const EdgeInsets.only(top: 0),
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.horizontal(left: Radius.circular(20)),
          boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 24, offset: Offset(-4, 0))],
        ),
        child: StreamBuilder<QuerySnapshot>(
          stream: FirebaseFirestore.instance
              .collection('users')
              .doc(uid)
              .collection('notifications')
              .orderBy('createdAt', descending: true)
              .limit(50)
              .snapshots(),
          builder: (context, snap) {
            final docs = snap.data?.docs ?? [];
            final notifs = docs.map(AppNotification.fromDoc).toList();
            final unread = notifs.where((n) => !n.read).length;

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header
                SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 20, 12, 16),
                    child: Row(
                      children: [
                        const Text(
                          'Notifications',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.secondaryColor,
                          ),
                        ),
                        if (unread > 0) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFF3B82F6),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '$unread',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ],
                        const Spacer(),
                        if (unread > 0)
                          TextButton(
                            onPressed: () => _markAllRead(uid, docs),
                            child: const Text('Mark all read',
                                style: TextStyle(fontSize: 12, color: AppTheme.primaryColor)),
                          ),
                        IconButton(
                          icon: const Icon(Icons.close, size: 20, color: AppTheme.secondaryColor),
                          onPressed: () => Navigator.pop(context),
                        ),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 1),
                // List
                Expanded(
                  child: notifs.isEmpty
                      ? Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.notifications_none_rounded,
                                  size: 56, color: Colors.grey.shade300),
                              const SizedBox(height: 12),
                              Text('No notifications yet',
                                  style: TextStyle(color: Colors.grey.shade500, fontSize: 14)),
                            ],
                          ),
                        )
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          itemCount: notifs.length,
                          separatorBuilder: (_, __) =>
                              Divider(height: 1, color: Colors.grey.shade100, indent: 72),
                          itemBuilder: (context, i) =>
                              _NotifTile(notif: notifs[i], uid: uid),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  void _markAllRead(String uid, List<DocumentSnapshot> docs) {
    final batch = FirebaseFirestore.instance.batch();
    for (final doc in docs) {
      if ((doc.data() as Map<String, dynamic>)['read'] != true) {
        batch.update(doc.reference, {'read': true});
      }
    }
    batch.commit();
  }
}

class _NotifTile extends StatelessWidget {
  final AppNotification notif;
  final String uid;
  const _NotifTile({required this.notif, required this.uid});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () {
        if (!notif.read) {
          FirebaseFirestore.instance
              .collection('users')
              .doc(uid)
              .collection('notifications')
              .doc(notif.id)
              .update({'read': true});
        }
      },
      child: Container(
        color: notif.read ? Colors.transparent : const Color(0xFFF0F7FF),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Icon avatar
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: _iconColor(notif.type).withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(_iconFor(notif.type), color: _iconColor(notif.type), size: 20),
            ),
            const SizedBox(width: 12),
            // Content
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: RichText(
                          text: TextSpan(
                            style: const TextStyle(
                                color: AppTheme.secondaryColor, fontSize: 13, height: 1.4),
                            children: [
                              TextSpan(
                                text: notif.title,
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (!notif.read)
                        Container(
                          width: 8,
                          height: 8,
                          margin: const EdgeInsets.only(left: 6, top: 3),
                          decoration: const BoxDecoration(
                            color: Color(0xFF3B82F6),
                            shape: BoxShape.circle,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    notif.body,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600, height: 1.4),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    _relativeTime(notif.createdAt),
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconFor(String type) {
    switch (type) {
      case 'trip_departed':
        return Icons.directions_bus_rounded;
      case 'arrived':
        return Icons.location_on_rounded;
      case 'next_destination':
        return Icons.navigation_rounded;
      case 'trip_completed':
        return Icons.flag_rounded;
      case 'geofence_alert':
        return Icons.warning_amber_rounded;
      default:
        return Icons.notifications_rounded;
    }
  }

  Color _iconColor(String type) {
    switch (type) {
      case 'trip_departed':
        return AppTheme.primaryColor;
      case 'arrived':
        return Colors.green;
      case 'next_destination':
        return Colors.blue;
      case 'trip_completed':
        return Colors.green;
      case 'geofence_alert':
        return Colors.orange;
      default:
        return AppTheme.primaryColor;
    }
  }

  String _relativeTime(DateTime? dt) {
    if (dt == null) return '';
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} hour${diff.inHours > 1 ? 's' : ''} ago';
    if (diff.inDays == 1) return 'Yesterday';
    return '${diff.inDays} days ago';
  }
}
