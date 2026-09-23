import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';

/// Client side of customer support, shared by all four apps.
///
/// There is one of these rather than one per role because the server resolves
/// who is asking from their own account — the client never says who it is, what
/// school it belongs to or what role it holds, so admin, teacher, student and
/// parent all send exactly the same request.
class SupportService {
  SupportService._();

  static final _fns = FirebaseFunctions.instance;
  static final _db = FirebaseFirestore.instance;

  /// The categories the server will accept. Anything else is refused.
  static const categories = <String, String>{
    'question': 'Question',
    'bug': 'Something is broken',
    'feedback': 'Feedback',
    'billing': 'Billing',
    'account': 'Account access',
    'other': 'Other',
  };

  static const statusLabels = <String, String>{
    'open': 'Open',
    'in_progress': 'Being looked at',
    'waiting_for_requester': 'Waiting for you',
    'resolved': 'Resolved',
    'closed': 'Closed',
  };

  static Future<Map<String, dynamic>> _call(
    String name,
    Map<String, dynamic> payload,
  ) async {
    final res =
        await _fns.httpsCallable(name).call<Map<String, dynamic>>(payload);
    return Map<String, dynamic>.from(res.data);
  }

  /// Opens a ticket. Returns its quotable reference, e.g. SUP-2026-0001.
  static Future<String> create({
    required String subject,
    required String category,
    required String description,
  }) async {
    final res = await _call('createSupportTicket', {
      'subject': subject,
      'category': category,
      'description': description,
    });
    return (res['reference'] ?? '').toString();
  }

  static Future<void> reply({
    required String ticketId,
    required String text,
  }) =>
      _call('replyToSupportTicket', {'ticketId': ticketId, 'text': text});

  /// Clears the requester's unread flag. Best effort — a failure here only
  /// means the dot stays, so callers do not need to handle it.
  static Future<void> markRead(String ticketId) async {
    try {
      await _call('markTicketRead', {'ticketId': ticketId});
    } catch (_) {}
  }

  /// This account's own tickets, newest conversation first.
  ///
  /// Scoped by `requester.uid` because that is also what the security rule
  /// checks: a query that asked for anything wider would simply be refused.
  static Stream<QuerySnapshot<Map<String, dynamic>>> myTickets() {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const Stream.empty();
    return _db
        .collection('supportTickets')
        .where('requester.uid', isEqualTo: uid)
        .orderBy('lastMessageAt', descending: true)
        .limit(50)
        .snapshots();
  }

  static Stream<QuerySnapshot<Map<String, dynamic>>> messages(String ticketId) =>
      _db
          .collection('supportTickets')
          .doc(ticketId)
          .collection('messages')
          .orderBy('createdAt')
          .snapshots();

  /// Turns a callable failure into something worth showing a person.
  static String describeError(Object e) {
    if (e is FirebaseFunctionsException) {
      final m = e.message;
      if (m != null && m.isNotEmpty) return m;
      switch (e.code) {
        case 'resource-exhausted':
          return 'You have opened several requests just now. '
              'Please wait a moment before sending another.';
        case 'unauthenticated':
          return 'Please sign in again.';
        default:
          return 'That could not be sent. Please try again.';
      }
    }
    return 'That could not be sent. Check your connection and try again.';
  }
}
