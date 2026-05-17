import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../config/theme.dart';

/// List of group chats the current user belongs to.
/// Admins (role == 'admin' on their user doc) see every chat.
class ChatListView extends StatefulWidget {
  const ChatListView({super.key});

  @override
  State<ChatListView> createState() => _ChatListViewState();
}

class _ChatListViewState extends State<ChatListView> {
  String? _role;

  @override
  void initState() {
    super.initState();
    _loadRole();
  }

  Future<void> _loadRole() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final snap = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    if (!mounted) return;
    setState(() => _role = (snap.data()?['role'] ?? '').toString());
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) {
      return const Scaffold(body: Center(child: Text("Not signed in")));
    }

    Query<Map<String, dynamic>> query = FirebaseFirestore.instance.collection('chats');
    if (_role != 'admin') {
      query = query.where('memberIds', arrayContains: uid);
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text("Chats",
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: AppTheme.secondaryColor)),
        leading: Navigator.canPop(context)
            ? IconButton(
                icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: AppTheme.secondaryColor),
                onPressed: () => Navigator.pop(context),
              )
            : null,
      ),
      body: _role == null
          ? const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor))
          : StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: query.snapshots(),
              builder: (context, snap) {
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text("Failed to load chats: ${snap.error}",
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.red)),
                    ),
                  );
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
                }
                // Sort client-side by lastMessageAt desc (avoids needing a composite index).
                final docs = snap.data!.docs.toList()
                  ..sort((a, b) {
                    final ta = a.data()['lastMessageAt'] as Timestamp?;
                    final tb = b.data()['lastMessageAt'] as Timestamp?;
                    if (ta == null && tb == null) return 0;
                    if (ta == null) return 1;
                    if (tb == null) return -1;
                    return tb.compareTo(ta);
                  });
                if (docs.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.chat_bubble_outline, size: 56, color: Colors.grey.shade300),
                        const SizedBox(height: 12),
                        Text("No chats yet",
                            style: TextStyle(color: Colors.grey.shade500, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 4),
                        Text(
                          "Chats are created automatically once a bus is assigned to a trip.",
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                        ),
                      ],
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (c, i) {
                    final data = docs[i].data();
                    final String name = data['name'] ?? 'Chat';
                    final String last = (data['lastMessage'] ?? '').toString();
                    final String lastSender = (data['lastSenderName'] ?? '').toString();
                    final Timestamp? when = data['lastMessageAt'] as Timestamp?;
                    final int memberCount = (data['memberIds'] as List?)?.length ?? 0;

                    return Material(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(14),
                        onTap: () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => ChatRoomView(chatId: docs[i].id),
                          ),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Row(
                            children: [
                              CircleAvatar(
                                radius: 22,
                                backgroundColor: AppTheme.primaryColor.withValues(alpha: 0.12),
                                child: const Icon(Icons.directions_bus_rounded,
                                    color: AppTheme.primaryColor),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(
                                            name,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 14,
                                              color: AppTheme.secondaryColor,
                                            ),
                                          ),
                                        ),
                                        if (when != null)
                                          Text(
                                            _shortTime(when.toDate()),
                                            style: TextStyle(
                                                fontSize: 11, color: Colors.grey.shade500),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      last.isEmpty
                                          ? "$memberCount member${memberCount == 1 ? '' : 's'}"
                                          : (lastSender.isEmpty ? last : "$lastSender: $last"),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                          fontSize: 12, color: Colors.grey.shade600),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
    );
  }

  String _shortTime(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return "now";
    if (diff.inHours < 1) return "${diff.inMinutes}m";
    if (diff.inDays < 1) return "${diff.inHours}h";
    if (diff.inDays < 7) return "${diff.inDays}d";
    return "${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')}";
  }
}

/// Single chat thread. Lazily creates the chat doc client-side if missing
/// (useful if the Cloud Function hasn't run yet).
class ChatRoomView extends StatefulWidget {
  final String chatId;
  const ChatRoomView({super.key, required this.chatId});

  @override
  State<ChatRoomView> createState() => _ChatRoomViewState();
}

class _ChatRoomViewState extends State<ChatRoomView> {
  final _textCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  bool _sending = false;
  Map<String, dynamic>? _me; // {name, role}

  @override
  void initState() {
    super.initState();
    _loadMe();
  }

  Future<void> _loadMe() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final snap = await FirebaseFirestore.instance.collection('users').doc(uid).get();
    if (!mounted) return;
    setState(() => _me = snap.data());
  }

  Future<void> _send() async {
    final text = _textCtrl.text.trim();
    if (text.isEmpty || _me == null) return;
    setState(() => _sending = true);
    final uid = FirebaseAuth.instance.currentUser!.uid;
    try {
      await FirebaseFirestore.instance
          .collection('chats')
          .doc(widget.chatId)
          .collection('messages')
          .add({
        'senderId': uid,
        'senderName': _me!['name'] ?? '',
        'senderRole': _me!['role'] ?? '',
        'text': text,
        'createdAt': FieldValue.serverTimestamp(),
      });
      // lastMessage preview is updated by the onChatMessageCreated Cloud
      // Function with sanitized text — no client-side write needed here.
      _textCtrl.clear();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text("Failed to send: $e"),
        backgroundColor: Colors.red,
      ));
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, size: 20, color: AppTheme.secondaryColor),
          onPressed: () => Navigator.pop(context),
        ),
        title: StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance.collection('chats').doc(widget.chatId).snapshots(),
          builder: (ctx, snap) {
            final name = snap.data?.data()?['name'] ?? 'Chat';
            final memberCount = (snap.data?.data()?['memberIds'] as List?)?.length ?? 0;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name,
                    style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                        color: AppTheme.secondaryColor),
                    overflow: TextOverflow.ellipsis),
                if (memberCount > 0)
                  Text(
                    "$memberCount member${memberCount == 1 ? '' : 's'}",
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  ),
              ],
            );
          },
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: FirebaseFirestore.instance
                  .collection('chats')
                  .doc(widget.chatId)
                  .collection('messages')
                  .orderBy('createdAt', descending: true)
                  .limit(200)
                  .snapshots(),
              builder: (ctx, snap) {
                if (snap.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text("Failed to load messages: ${snap.error}",
                          textAlign: TextAlign.center,
                          style: const TextStyle(color: Colors.red)),
                    ),
                  );
                }
                if (!snap.hasData) {
                  return const Center(child: CircularProgressIndicator(color: AppTheme.primaryColor));
                }
                final messages = snap.data!.docs;
                if (messages.isEmpty) {
                  return Center(
                    child: Text("No messages yet. Say hello!",
                        style: TextStyle(color: Colors.grey.shade400)),
                  );
                }
                return ListView.builder(
                  controller: _scrollCtrl,
                  reverse: true,
                  padding: const EdgeInsets.fromLTRB(12, 16, 12, 16),
                  itemCount: messages.length,
                  itemBuilder: (c, i) {
                    final m = messages[i].data();
                    final bool mine = m['senderId'] == uid;
                    return _MessageBubble(
                      isMine: mine,
                      senderName: m['senderName']?.toString() ?? '',
                      senderRole: m['senderRole']?.toString() ?? '',
                      text: m['text']?.toString() ?? '',
                      createdAt: (m['createdAt'] as Timestamp?)?.toDate(),
                    );
                  },
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
              decoration: BoxDecoration(
                color: Colors.white,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.05),
                    blurRadius: 12,
                    offset: const Offset(0, -2),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _textCtrl,
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        hintText: "Type a message…",
                        contentPadding:
                            const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide(color: Colors.grey.shade300),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide(color: Colors.grey.shade300),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide:
                              const BorderSide(color: AppTheme.primaryColor, width: 1.5),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Material(
                    color: AppTheme.primaryColor,
                    shape: const CircleBorder(),
                    child: InkWell(
                      customBorder: const CircleBorder(),
                      onTap: _sending ? null : _send,
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: _sending
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
                              )
                            : const Icon(Icons.send_rounded, color: Colors.white, size: 18),
                      ),
                    ),
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

class _MessageBubble extends StatelessWidget {
  final bool isMine;
  final String senderName;
  final String senderRole;
  final String text;
  final DateTime? createdAt;

  const _MessageBubble({
    required this.isMine,
    required this.senderName,
    required this.senderRole,
    required this.text,
    required this.createdAt,
  });

  @override
  Widget build(BuildContext context) {
    final bg = isMine ? AppTheme.primaryColor : Colors.white;
    final fg = isMine ? Colors.white : AppTheme.secondaryColor;
    final isTeacher = senderRole.toLowerCase() == 'teacher';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: isMine ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMine)
            CircleAvatar(
              radius: 14,
              backgroundColor: (isTeacher ? Colors.red : AppTheme.primaryColor)
                  .withValues(alpha: 0.12),
              child: Text(
                senderName.isNotEmpty ? senderName[0].toUpperCase() : '?',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  color: isTeacher ? Colors.red : AppTheme.primaryColor,
                ),
              ),
            ),
          const SizedBox(width: 6),
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.72,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(14),
                  topRight: const Radius.circular(14),
                  bottomLeft: Radius.circular(isMine ? 14 : 2),
                  bottomRight: Radius.circular(isMine ? 2 : 14),
                ),
                border: Border.all(
                  color: isMine ? AppTheme.primaryColor : Colors.grey.shade200,
                ),
              ),
              child: Column(
                crossAxisAlignment:
                    isMine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  if (!isMine && senderName.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(
                        senderName,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                          color: isTeacher ? Colors.red.shade600 : AppTheme.primaryColor,
                        ),
                      ),
                    ),
                  Text(text, style: TextStyle(fontSize: 13, color: fg, height: 1.3)),
                  if (createdAt != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        _hm(createdAt!),
                        style: TextStyle(
                          fontSize: 9,
                          color: isMine
                              ? Colors.white.withValues(alpha: 0.8)
                              : Colors.grey.shade500,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _hm(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    return "$h:$m";
  }
}
