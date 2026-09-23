import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../../config/console_theme.dart';

/// Vocabulary, queries and callable wrappers for the platform console.
///
/// Status strings are duplicated in `functions/lib/applications.js` and in the
/// security rules; they live in one place on each side so a rename is a single
/// edit per language rather than a hunt through screens.

// ─── Application status ───────────────────────────────────────────────────────

class ApplicationStatus {
  ApplicationStatus._();

  static const String draft = 'draft';
  static const String submitted = 'submitted';
  static const String underReview = 'under_review';
  static const String needsMoreDocuments = 'needs_more_documents';
  static const String approved = 'approved';
  static const String rejected = 'rejected';

  /// Waiting on the operator.
  static const List<String> awaitingReview = [submitted, underReview];

  /// Waiting on the applicant.
  static const List<String> awaitingApplicant = [draft, needsMoreDocuments];

  static const List<String> all = [
    draft, submitted, underReview, needsMoreDocuments, approved, rejected,
  ];

  static String label(String status) {
    switch (status) {
      case draft:
        return 'Draft';
      case submitted:
        return 'Submitted';
      case underReview:
        return 'Under review';
      case needsMoreDocuments:
        return 'Needs documents';
      case approved:
        return 'Approved';
      case rejected:
        return 'Rejected';
      default:
        return status;
    }
  }

  static IconData icon(String status) {
    switch (status) {
      case draft:
        return Icons.edit_note_rounded;
      case submitted:
        return Icons.inbox_rounded;
      case underReview:
        return Icons.pending_actions_rounded;
      case needsMoreDocuments:
        return Icons.upload_file_rounded;
      case approved:
        return Icons.check_circle_rounded;
      case rejected:
        return Icons.cancel_rounded;
      default:
        return Icons.help_outline_rounded;
    }
  }

  static StatusTone tone(ConsoleTokens t, String status) {
    switch (status) {
      case approved:
        return t.success;
      case rejected:
        return t.danger;
      case needsMoreDocuments:
        return t.warning;
      case submitted:
      case underReview:
        return t.info;
      default:
        return t.neutral;
    }
  }
}

// ─── Support ticket status ────────────────────────────────────────────────────

class TicketStatus {
  TicketStatus._();

  static const String open = 'open';
  static const String inProgress = 'in_progress';
  static const String waitingForRequester = 'waiting_for_requester';
  static const String resolved = 'resolved';
  static const String closed = 'closed';

  /// Still the operator's problem.
  static const List<String> unresolved = [open, inProgress, waitingForRequester];

  static const List<String> all = [open, inProgress, waitingForRequester, resolved, closed];

  static String label(String status) {
    switch (status) {
      case open:
        return 'Open';
      case inProgress:
        return 'In progress';
      case waitingForRequester:
        return 'Waiting for requester';
      case resolved:
        return 'Resolved';
      case closed:
        return 'Closed';
      default:
        return status;
    }
  }

  static IconData icon(String status) {
    switch (status) {
      case open:
        return Icons.mark_email_unread_rounded;
      case inProgress:
        return Icons.autorenew_rounded;
      case waitingForRequester:
        return Icons.hourglass_top_rounded;
      case resolved:
        return Icons.task_alt_rounded;
      case closed:
        return Icons.archive_rounded;
      default:
        return Icons.help_outline_rounded;
    }
  }

  static StatusTone tone(ConsoleTokens t, String status) {
    switch (status) {
      case open:
        return t.warning;
      case inProgress:
        return t.info;
      case waitingForRequester:
        return t.neutral;
      case resolved:
        return t.success;
      case closed:
        return t.neutral;
      default:
        return t.neutral;
    }
  }
}

// ─── Support ticket categories ────────────────────────────────────────────────

class TicketCategory {
  TicketCategory._();

  static const String question = 'question';
  static const String bug = 'bug';
  static const String feedback = 'feedback';
  static const String billing = 'billing';
  static const String account = 'account';
  static const String other = 'other';

  static const List<String> all = [question, bug, feedback, billing, account, other];

  static String label(String c) {
    switch (c) {
      case question:
        return 'Question';
      case bug:
        return 'Bug report';
      case feedback:
        return 'Feedback';
      case billing:
        return 'Billing & subscription';
      case account:
        return 'Account access';
      default:
        return 'Other';
    }
  }
}

// ─── Announcements ────────────────────────────────────────────────────────────

class AnnouncementCategory {
  AnnouncementCategory._();

  static const String maintenance = 'maintenance';
  static const String feature = 'feature';
  static const String update = 'update';
  static const String policy = 'policy';

  static const List<String> all = [maintenance, feature, update, policy];

  static String label(String c) {
    switch (c) {
      case maintenance:
        return 'Scheduled maintenance';
      case feature:
        return 'New feature';
      case update:
        return 'Platform update';
      case policy:
        return 'Policy change';
      default:
        return c;
    }
  }

  static IconData icon(String c) {
    switch (c) {
      case maintenance:
        return Icons.build_circle_outlined;
      case feature:
        return Icons.auto_awesome_outlined;
      case update:
        return Icons.system_update_alt_rounded;
      case policy:
        return Icons.gavel_rounded;
      default:
        return Icons.campaign_outlined;
    }
  }
}

// ─── Institution types and their verification documents ───────────────────────

class InstitutionType {
  InstitutionType._();

  static const String privateIncorporated = 'private_incorporated';
  static const String publicSchool = 'public_school';
  static const String stateUniversity = 'state_university';
  static const String tvet = 'tvet';
  static const String other = 'other';

  static const List<String> all = [
    privateIncorporated, publicSchool, stateUniversity, tvet, other,
  ];

  static String label(String type) {
    switch (type) {
      case privateIncorporated:
        return 'Private school (incorporated)';
      case publicSchool:
        return 'Public school (DepEd)';
      case stateUniversity:
        return 'State university or local college';
      case tvet:
        return 'TVET institution';
      default:
        return 'Other institution';
    }
  }
}

/// The document kinds an applicant can be asked for. Which ones are required
/// depends on the institution type — a public school has no SEC registration,
/// so asking every applicant for one would be a wall, not a check.
class ApplicationDocType {
  ApplicationDocType._();

  static const String secRegistration = 'sec_registration';
  static const String depedPermit = 'deped_permit';
  static const String chedRecognition = 'ched_recognition';
  static const String tesdaRegistration = 'tesda_registration';
  static const String governmentEstablishment = 'government_establishment';
  static const String authorizationLetter = 'authorization_letter';
  static const String articlesOfIncorporation = 'articles_of_incorporation';
  static const String schoolIdentifier = 'school_identifier';
  static const String addressProof = 'address_proof';
  static const String other = 'other';

  static String label(String type) {
    switch (type) {
      case secRegistration:
        return 'SEC Certificate of Registration / Incorporation';
      case depedPermit:
        return 'DepEd permit or recognition';
      case chedRecognition:
        return 'CHED authority / recognition';
      case tesdaRegistration:
        return 'TESDA program registration certificate';
      case governmentEstablishment:
        return 'Charter, ordinance or establishment document';
      case authorizationLetter:
        return 'Authorization letter for the representative';
      case articlesOfIncorporation:
        return 'Articles of Incorporation';
      case schoolIdentifier:
        return 'Official school ID / directory reference';
      case addressProof:
        return 'Proof of school address';
      default:
        return 'Supporting document';
    }
  }

  static String description(String type) {
    switch (type) {
      case secRegistration:
        return 'Proves the institution exists as a registered corporation.';
      case depedPermit:
        return 'Permit or recognition covering the basic-education programs offered.';
      case chedRecognition:
        return 'Required only for higher-education programs.';
      case tesdaRegistration:
        return 'Required only for technical-vocational programs.';
      case governmentEstablishment:
        return 'The charter, ordinance or DepEd issuance that established the school.';
      case authorizationLetter:
        return 'Signed evidence that you may act for the school in this subscription.';
      case articlesOfIncorporation:
        return 'Optional. Shows the legal name and stated purpose.';
      case schoolIdentifier:
        return 'Optional. School ID number or an official directory listing.';
      case addressProof:
        return 'Optional. A utility bill or official letterhead showing the address.';
      default:
        return 'Any other document the reviewer asked for.';
    }
  }
}

/// How an OCR extraction ended. The console never presents any of these as a
/// verdict on the school — only as the state of a text-extraction job.
class OcrStatus {
  OcrStatus._();

  static const String pending = 'pending';
  static const String extracted = 'extracted';
  static const String partial = 'partial';
  static const String unreadable = 'unreadable';
  static const String failed = 'failed';
  static const String skipped = 'skipped';

  static String label(String s) {
    switch (s) {
      case pending:
        return 'Extracting text…';
      case extracted:
        return 'Text extracted';
      case partial:
        return 'Partially extracted';
      case unreadable:
        return 'Could not read the document';
      case failed:
        return 'Extraction failed';
      case skipped:
        return 'Extraction not run';
      default:
        return s;
    }
  }

  static StatusTone tone(ConsoleTokens t, String s) {
    switch (s) {
      case extracted:
        return t.success;
      case partial:
        return t.warning;
      case unreadable:
      case failed:
        return t.danger;
      default:
        return t.neutral;
    }
  }
}

// ─── Queries ──────────────────────────────────────────────────────────────────

class PlatformQueries {
  PlatformQueries._();

  static FirebaseFirestore get _db => FirebaseFirestore.instance;

  /// Applications the operator still has to decide on.
  static Query<Map<String, dynamic>> applicationsAwaitingReview() => _db
      .collection('schoolApplications')
      .where('status', whereIn: ApplicationStatus.awaitingReview);

  static Query<Map<String, dynamic>> applicationsByStatus(List<String> statuses) => _db
      .collection('schoolApplications')
      .where('status', whereIn: statuses)
      .orderBy('submittedAt', descending: true);

  static Query<Map<String, dynamic>> allApplications() =>
      _db.collection('schoolApplications').orderBy('submittedAt', descending: true);

  static Query<Map<String, dynamic>> applicationDocuments(String applicationId) => _db
      .collection('schoolApplications')
      .doc(applicationId)
      .collection('documents')
      .orderBy('uploadedAt', descending: false);

  static Query<Map<String, dynamic>> applicationEvents(String applicationId) => _db
      .collection('schoolApplications')
      .doc(applicationId)
      .collection('events')
      .orderBy('at', descending: true);

  static Query<Map<String, dynamic>> schools() =>
      _db.collection('schools').orderBy('createdAt', descending: true);

  /// School-administrator accounts. The `role` filter is not cosmetic: the
  /// security rule only allows a super admin to read documents where
  /// `role == 'admin'`, so a query without it is denied outright.
  static Query<Map<String, dynamic>> schoolAdmins() =>
      _db.collection('users').where('role', isEqualTo: 'admin');

  static Query<Map<String, dynamic>> announcements() =>
      _db.collection('announcements').orderBy('createdAt', descending: true);

  static Query<Map<String, dynamic>> ticketsNeedingSupport() => _db
      .collection('supportTickets')
      .where('status', whereIn: TicketStatus.unresolved);

  static Query<Map<String, dynamic>> allTickets() =>
      _db.collection('supportTickets').orderBy('lastMessageAt', descending: true);

  static Query<Map<String, dynamic>> ticketMessages(String ticketId) => _db
      .collection('supportTickets')
      .doc(ticketId)
      .collection('messages')
      .orderBy('createdAt');

  static Query<Map<String, dynamic>> auditLogs() =>
      _db.collection('platformAuditLogs').orderBy('at', descending: true);

  static Query<Map<String, dynamic>> receiptsForSchool(String schoolId) => _db
      .collection('receipts')
      .where('schoolId', isEqualTo: schoolId)
      .orderBy('issuedAt', descending: true);
}

// ─── Callable wrappers ────────────────────────────────────────────────────────

/// Thin wrappers over the platform Cloud Functions.
///
/// Every one of these is authorized on the server; the console calls them and
/// renders what comes back. Nothing here decides anything locally.
class PlatformActions {
  PlatformActions._();

  static FirebaseFunctions get _fns => FirebaseFunctions.instance;

  static Future<Map<String, dynamic>> _call(
    String name,
    Map<String, dynamic> payload,
  ) async {
    final res = await _fns.httpsCallable(name).call<Map<String, dynamic>>(payload);
    return Map<String, dynamic>.from(res.data);
  }

  static Future<Map<String, dynamic>> decideApplication({
    required String applicationId,
    required String decision, // approve | reject | request_documents
    required String reason,
    List<String> requestedDocTypes = const [],
    String? reviewerNote,
    bool overrideWarnings = false,
    String? overrideReason,
    required String idempotencyKey,
  }) =>
      _call('decideSchoolApplication', {
        'applicationId': applicationId,
        'decision': decision,
        'reason': reason,
        'requestedDocTypes': requestedDocTypes,
        'reviewerNote': reviewerNote,
        'overrideWarnings': overrideWarnings,
        'overrideReason': overrideReason,
        'idempotencyKey': idempotencyKey,
      });

  static Future<Map<String, dynamic>> claimApplicationForReview(String applicationId) =>
      _call('claimApplicationForReview', {'applicationId': applicationId});

  static Future<Map<String, dynamic>> setAdminAccountStatus({
    required String uid,
    required bool disable,
    required String reason,
  }) =>
      _call('setSchoolAdminAccountStatus', {
        'uid': uid,
        'disable': disable,
        'reason': reason,
      });

  static Future<Map<String, dynamic>> resendAdminCredentials({
    required String schoolId,
    required String reason,
  }) =>
      _call('resendAdminCredentials', {'schoolId': schoolId, 'reason': reason});

  static Future<Map<String, dynamic>> publishAnnouncement({
    required String title,
    required String body,
    required String category,
    DateTime? maintenanceStart,
    DateTime? maintenanceEnd,
    String? announcementId,
  }) =>
      _call('publishAnnouncement', {
        'announcementId': announcementId,
        'title': title,
        'body': body,
        'category': category,
        'maintenanceStart': maintenanceStart?.toUtc().toIso8601String(),
        'maintenanceEnd': maintenanceEnd?.toUtc().toIso8601String(),
      });

  static Future<Map<String, dynamic>> unpublishAnnouncement({
    required String announcementId,
    required String reason,
  }) =>
      _call('unpublishAnnouncement', {
        'announcementId': announcementId,
        'reason': reason,
      });

  static Future<Map<String, dynamic>> replyToTicket({
    required String ticketId,
    required String text,
    String? newStatus,
  }) =>
      _call('replyToSupportTicket', {
        'ticketId': ticketId,
        'text': text,
        'newStatus': newStatus,
      });

  static Future<Map<String, dynamic>> setTicketStatus({
    required String ticketId,
    required String status,
  }) =>
      _call('setSupportTicketStatus', {'ticketId': ticketId, 'status': status});

  static Future<Map<String, dynamic>> retryApplicationEmail({
    required String applicationId,
    required String emailType,
  }) =>
      _call('retryApplicationEmail', {
        'applicationId': applicationId,
        'emailType': emailType,
      });

  static Future<Map<String, dynamic>> reRunOcr({
    required String applicationId,
    required String documentId,
  }) =>
      _call('reRunApplicationOcr', {
        'applicationId': applicationId,
        'documentId': documentId,
      });

  static Future<Map<String, dynamic>> changeMyPassword(String newPassword) =>
      _call('changeMyPassword', {'newPassword': newPassword});

  static Future<Map<String, dynamic>> updateBankingCalendar(List<String> holidays) =>
      _call('updateBankingCalendar', {'holidays': holidays});
}

// ─── Formatting ───────────────────────────────────────────────────────────────

String formatTimestamp(dynamic value, {bool withTime = true}) {
  DateTime? dt;
  if (value is Timestamp) dt = value.toDate();
  if (value is DateTime) dt = value;
  if (dt == null) return '—';
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final d = dt.toLocal();
  final date = '${d.day} ${months[d.month - 1]} ${d.year}';
  if (!withTime) return date;
  final h = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final m = d.minute.toString().padLeft(2, '0');
  final ampm = d.hour < 12 ? 'AM' : 'PM';
  return '$date, $h:$m $ampm';
}

String relativeTime(dynamic value) {
  DateTime? dt;
  if (value is Timestamp) dt = value.toDate();
  if (value is DateTime) dt = value;
  if (dt == null) return '—';
  final diff = DateTime.now().difference(dt.toLocal());
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays < 30) return '${diff.inDays}d ago';
  return formatTimestamp(value, withTime: false);
}

String formatPeso(num? amount) {
  if (amount == null) return '—';
  final s = amount.round().toString();
  final buf = StringBuffer();
  for (int i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
    buf.write(s[i]);
  }
  return '₱$buf';
}
