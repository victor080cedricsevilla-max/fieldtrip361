/**
 * Customer support tickets.
 *
 * A ticket carries the least the operator needs to answer it: who is asking,
 * in what role, at which school, and what they chose to write. The requester's
 * identity is resolved on the server from their own account — never from what
 * the client sends — and opening a ticket grants no access to their profile or
 * their school's records.
 *
 * A requester sees only their own tickets. A school administrator does not
 * automatically see a student's, parent's or teacher's conversation.
 */
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

const { sanitizeText, checkRateLimit } = require("./common");
const {
  ROLES,
  AUDIT,
  requireActiveUser,
  requireSuperAdmin,
  writeAuditLog,
} = require("./platform");

const STATUS = {
  open: "open",
  inProgress: "in_progress",
  waitingForRequester: "waiting_for_requester",
  resolved: "resolved",
  closed: "closed",
};

const CATEGORIES = ["question", "bug", "feedback", "billing", "account", "other"];

/** Sequential, quotable ticket reference: SUP-2026-0001. */
async function nextReference(db) {
  const ref = db.collection("platformConfig").doc("counters");
  const year = new Date().getUTCFullYear();
  const field = `ticket_${year}`;
  const n = await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const next = ((snap.exists ? snap.get(field) : 0) || 0) + 1;
    tx.set(ref, { [field]: next }, { merge: true });
    return next;
  });
  return `SUP-${year}-${String(n).padStart(4, "0")}`;
}

/**
 * The minimum identity a ticket carries. Read from the requester's own user
 * document, so a crafted request cannot impersonate a different role or school.
 */
async function requesterIdentity(db, uid, userData) {
  let schoolName = null;
  const schoolId = userData.schoolId || null;
  if (schoolId) {
    try {
      const s = await db.collection("schools").doc(schoolId).get();
      schoolName = s.exists ? s.get("name") : null;
    } catch (_) {
      // A missing school name is cosmetic; the ticket still needs to go through.
    }
  }
  return {
    uid,
    name: sanitizeText(userData.name, 120) || "FieldTrip360 user",
    email: sanitizeText(userData.email, 160),
    role: userData.role || "user",
    schoolId,
    schoolName,
  };
}

/** Writes a notification into a user's in-app inbox and pushes it if possible. */
async function notifyUser(db, uid, { title, body, ticketId }) {
  try {
    await db.collection("users").doc(uid).collection("notifications").add({
      title,
      body,
      type: "support",
      ticketId,
      read: false,
      createdAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    const snap = await db.collection("users").doc(uid).get();
    const tokens = (snap.get("fcmTokens") || []).filter(Boolean);
    if (tokens.length) {
      await admin.messaging().sendEachForMulticast({
        tokens,
        notification: { title, body },
        data: { kind: "support_ticket", ticketId },
        android: {
          priority: "high",
          notification: { channelId: "fieldtrip_high_importance", sound: "default" },
        },
        apns: { payload: { aps: { sound: "default" } } },
      });
    }
  } catch (e) {
    console.error("support notification failed:", e?.message || e);
  }
}

exports.createSupportTicket = onCall(async (request) => {
  const { uid, db, data: userData } = await requireActiveUser(request);
  await checkRateLimit(uid, "create_ticket", 5);

  const subject = sanitizeText(request.data?.subject, 160);
  const category = sanitizeText(request.data?.category, 40);
  const description = sanitizeText(request.data?.description, 5000);
  const attachments = Array.isArray(request.data?.attachments)
    ? request.data.attachments.slice(0, 3).map((a) => ({
        storagePath: sanitizeText(a?.storagePath, 500),
        downloadUrl: sanitizeText(a?.downloadUrl, 1000),
        fileName: sanitizeText(a?.fileName, 200),
        contentType: sanitizeText(a?.contentType, 100),
      }))
    : [];

  if (subject.length < 4) {
    throw new HttpsError("invalid-argument", "Give your request a short subject.");
  }
  if (!CATEGORIES.includes(category)) {
    throw new HttpsError("invalid-argument", "Choose a category.");
  }
  if (description.length < 10) {
    throw new HttpsError("invalid-argument", "Describe what you need help with.");
  }
  for (const a of attachments) {
    if (a.storagePath && !a.storagePath.startsWith(`support_attachments/${uid}/`)) {
      throw new HttpsError("permission-denied", "That attachment does not belong to you.");
    }
  }

  const reference = await nextReference(db);
  const now = admin.firestore.FieldValue.serverTimestamp();
  const ref = db.collection("supportTickets").doc();

  await ref.set({
    reference,
    subject,
    category,
    description,
    attachments,
    status: STATUS.open,
    requester: await requesterIdentity(db, uid, userData),
    createdAt: now,
    updatedAt: now,
    lastMessageAt: now,
    lastMessageBy: "requester",
    unreadForSupport: true,
    unreadForRequester: false,
  });

  return { ticketId: ref.id, reference };
});

exports.replyToSupportTicket = onCall(async (request) => {
  const { uid, db, data: userData } = await requireActiveUser(request);
  await checkRateLimit(uid, "reply_ticket", 30);

  const ticketId = sanitizeText(request.data?.ticketId, 64);
  const text = sanitizeText(request.data?.text, 5000);
  const newStatus = sanitizeText(request.data?.newStatus, 40);
  if (!ticketId) throw new HttpsError("invalid-argument", "ticketId is required.");
  if (text.length < 2) throw new HttpsError("invalid-argument", "Write a message before sending.");

  const ref = db.collection("supportTickets").doc(ticketId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Ticket not found.");

  const isSuperAdmin = request.auth.token.superAdmin === true;
  const isRequester = snap.get("requester")?.uid === uid;
  if (!isSuperAdmin && !isRequester) {
    throw new HttpsError("permission-denied", "This ticket belongs to someone else.");
  }
  if ([STATUS.closed].includes(snap.get("status")) && !isSuperAdmin) {
    throw new HttpsError("failed-precondition", "This ticket is closed. Open a new one.");
  }

  const side = isSuperAdmin ? "support" : "requester";
  const now = admin.firestore.FieldValue.serverTimestamp();

  await ref.collection("messages").add({
    senderUid: uid,
    senderSide: side,
    senderName: isSuperAdmin
      ? "FieldTrip360 support"
      : sanitizeText(userData.name, 120) || "Requester",
    text,
    createdAt: now,
  });

  // A reviewer may set the status explicitly; otherwise the side that replied
  // implies it — support asking a question puts the ball back with the
  // requester, and a requester replying reopens the ticket.
  const status = Object.values(STATUS).includes(newStatus)
    ? newStatus
    : isSuperAdmin
      ? STATUS.waitingForRequester
      : STATUS.open;

  await ref.update({
    status,
    updatedAt: now,
    lastMessageAt: now,
    lastMessageBy: side,
    unreadForSupport: side === "requester",
    unreadForRequester: side === "support",
  });

  if (side === "support") {
    await notifyUser(db, snap.get("requester").uid, {
      title: "FieldTrip360 support replied",
      body: `Re: ${snap.get("subject")}`,
      ticketId,
    });
    await writeAuditLog(db, {
      action: AUDIT.ticketReplied,
      actorUid: uid,
      actorEmail: userData.email,
      actorRole: ROLES.superAdmin,
      targetType: "ticket",
      targetId: ticketId,
      metadata: { status },
    });
  }

  return { ok: true, status };
});

exports.setSupportTicketStatus = onCall(async (request) => {
  const { uid, db, data: actor } = await requireSuperAdmin(request);
  const ticketId = sanitizeText(request.data?.ticketId, 64);
  const status = sanitizeText(request.data?.status, 40);
  if (!ticketId) throw new HttpsError("invalid-argument", "ticketId is required.");
  if (!Object.values(STATUS).includes(status)) {
    throw new HttpsError("invalid-argument", "Unknown status.");
  }

  const ref = db.collection("supportTickets").doc(ticketId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Ticket not found.");

  await ref.update({
    status,
    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    unreadForRequester: true,
  });

  await notifyUser(db, snap.get("requester").uid, {
    title: "Your support request was updated",
    body: `${snap.get("subject")} — ${status.replace(/_/g, " ")}`,
    ticketId,
  });

  await writeAuditLog(db, {
    action: AUDIT.ticketStatusChanged,
    actorUid: uid,
    actorEmail: actor.email,
    actorRole: ROLES.superAdmin,
    targetType: "ticket",
    targetId: ticketId,
    metadata: { status },
  });

  return { ok: true };
});

/** Clears the unread flag for whichever side is looking. */
exports.markTicketRead = onCall(async (request) => {
  const { uid, db } = await requireActiveUser(request);
  const ticketId = sanitizeText(request.data?.ticketId, 64);
  if (!ticketId) throw new HttpsError("invalid-argument", "ticketId is required.");

  const ref = db.collection("supportTickets").doc(ticketId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Ticket not found.");

  const isSuperAdmin = request.auth.token.superAdmin === true;
  const isRequester = snap.get("requester")?.uid === uid;
  if (!isSuperAdmin && !isRequester) {
    throw new HttpsError("permission-denied", "This ticket belongs to someone else.");
  }

  await ref.update(
    isSuperAdmin ? { unreadForSupport: false } : { unreadForRequester: false }
  );
  return { ok: true };
});

module.exports.TICKET_STATUS = STATUS;
