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

/// Bell icon button with unread badge -- drop into any AppBar actions list.
///
/// With [announceTripEvents] the bell also raises what arrives while it is on
/// screen: an emergency as a dialog, a stopover or a resumed trip as a snackbar.
/// That is for the school administrator, whose dashboard runs in a browser that
/// may hold no push token at all — the inbox document is the one delivery that
/// is certain to reach them, so it is the one that is watched.
class NotificationBell extends StatefulWidget {
  final bool announceTripEvents;
  const NotificationBell({super.key, this.announceTripEvents = false});

  @override
  State<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends State<NotificationBell> {
  static const _liveTypes = {'trip_emergency', 'trip_stopover', 'trip_resumed'};

  final _announced = <String>{};
  // Anything created before the bell appeared is already in the inbox; only
  // what arrives afterwards is worth interrupting for.
  final _since = DateTime.now().subtract(const Duration(minutes: 2));

  void _announce(List<DocumentChange> changes) {
    if (!widget.announceTripEvents) return;
    for (final change in changes) {
      if (change.type != DocumentChangeType.added) continue;
      if (_announced.contains(change.doc.id)) continue;
      final n = AppNotification.fromDoc(change.doc);
      if (!_liveTypes.contains(n.type)) continue;
      if (n.createdAt != null && n.createdAt!.isBefore(_since)) continue;
      _announced.add(n.id);
      WidgetsBinding.instance.addPostFrameCallback((_) => _show(n));
    }
  }

  void _show(AppNotification n) {
    if (!mounted) return;
    if (n.type == 'trip_emergency') {
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          backgroundColor: Colors.red.shade50,
          title: Row(children: [
            const Icon(Icons.emergency_rounded, color: Colors.red, size: 28),
            const SizedBox(width: 10),
            Expanded(
              child: Text(n.title,
                  style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 17)),
            ),
          ]),
          content: Text(n.body, style: const TextStyle(fontSize: 14.5, height: 1.45)),
          actions: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
              onPressed: () {
                FirebaseFirestore.instance
                    .collection('users')
                    .doc(FirebaseAuth.instance.currentUser?.uid)
                    .collection('notifications')
                    .doc(n.id)
                    .update({'read': true}).catchError((_) {});
                Navigator.pop(ctx);
              },
              child: const Text('Acknowledge'),
            ),
          ],
        ),
      );
      return;
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      duration: const Duration(seconds: 8),
      backgroundColor: n.type == 'trip_resumed' ? Colors.green.shade700 : Colors.orange.shade800,
      content: Text('${n.title}\n${n.body}', style: const TextStyle(height: 1.35)),
    ));
  }

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
        if (snap.hasData) _announce(snap.data!.docChanges);
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
        width: (MediaQuery.of(context).size.width * 0.88).clamp(0.0, 440.0),
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
                            child: Text('Mark all read',
                                style: TextStyle(fontSize: 12, color: AppTheme.effectivePrimary)),
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
      case 'trip_emergency':
        return Icons.emergency_rounded;
      case 'trip_stopover':
        return Icons.local_gas_station_rounded;
      case 'trip_resumed':
        return Icons.play_circle_rounded;
      case 'attendance_manual':
        return Icons.how_to_reg_rounded;
      case 'geofence_paused':
      case 'geofence_resumed':
        return Icons.location_searching_rounded;
      default:
        return Icons.notifications_rounded;
    }
  }

  Color _iconColor(String type) {
    switch (type) {
      case 'trip_departed':
        return AppTheme.effectivePrimary;
      case 'arrived':
        return Colors.green;
      case 'next_destination':
        return Colors.blue;
      case 'trip_completed':
        return Colors.green;
      case 'geofence_alert':
        return Colors.orange;
      case 'trip_emergency':
        return Colors.red;
      case 'trip_stopover':
        return Colors.orange;
      case 'trip_resumed':
        return Colors.green;
      default:
        return AppTheme.effectivePrimary;
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
