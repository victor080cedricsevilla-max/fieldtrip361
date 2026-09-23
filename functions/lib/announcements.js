/**
 * Platform announcements.
 *
 * An announcement is one document that every school administrator may read.
 * There is no recipient list and no per-recipient copy, so publishing one can
 * never disclose which other schools subscribe. Whether a given administrator
 * has read it is stored under that administrator's own account.
 */
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

const { sanitizeText, checkRateLimit } = require("./common");
const { ROLES, AUDIT, requireSuperAdmin, writeAuditLog } = require("./platform");

const CATEGORIES = ["maintenance", "feature", "update", "policy"];

function parseDate(value) {
  if (!value) return null;
  const d = new Date(value);
  return Number.isNaN(d.getTime()) ? null : d;
}

exports.publishAnnouncement = onCall(async (request) => {
  const { uid, db, data: actor } = await requireSuperAdmin(request);
  await checkRateLimit(uid, "publish_announcement", 20);

  const announcementId = sanitizeText(request.data?.announcementId, 64);
  const title = sanitizeText(request.data?.title, 160);
  const body = sanitizeText(request.data?.body, 4000);
  const category = sanitizeText(request.data?.category, 40);
  const maintenanceStart = parseDate(request.data?.maintenanceStart);
  const maintenanceEnd = parseDate(request.data?.maintenanceEnd);

  if (title.length < 4) throw new HttpsError("invalid-argument", "Give the announcement a title.");
  if (body.length < 10) throw new HttpsError("invalid-argument", "Write the message body.");
  if (!CATEGORIES.includes(category)) {
    throw new HttpsError("invalid-argument", "Choose a valid category.");
  }
  if (category === "maintenance" && !maintenanceStart) {
    throw new HttpsError("invalid-argument", "A maintenance announcement needs a start time.");
  }
  if (maintenanceStart && maintenanceEnd && maintenanceEnd <= maintenanceStart) {
    throw new HttpsError("invalid-argument", "The maintenance window must end after it starts.");
  }

  const now = admin.firestore.FieldValue.serverTimestamp();
  const payload = {
    title,
    body,
    category,
    status: "published",
    maintenanceStart: maintenanceStart ? admin.firestore.Timestamp.fromDate(maintenanceStart) : null,
    maintenanceEnd: maintenanceEnd ? admin.firestore.Timestamp.fromDate(maintenanceEnd) : null,
    publishedAt: now,
    publishedBy: uid,
    publishedByEmail: actor.email || null,
    updatedAt: now,
  };

  const ref = announcementId
    ? db.collection("announcements").doc(announcementId)
    : db.collection("announcements").doc();

  if (announcementId) {
    const snap = await ref.get();
    if (!snap.exists) throw new HttpsError("not-found", "Announcement not found.");
    await ref.update(payload);
  } else {
    await ref.set({ ...payload, createdAt: now });
  }

  await writeAuditLog(db, {
    action: AUDIT.announcementPublished,
    actorUid: uid,
    actorEmail: actor.email,
    actorRole: ROLES.superAdmin,
    targetType: "announcement",
    targetId: ref.id,
    metadata: { title, category, edited: !!announcementId },
  });

  return { announcementId: ref.id };
});

exports.unpublishAnnouncement = onCall(async (request) => {
  const { uid, db, data: actor } = await requireSuperAdmin(request);
  const announcementId = sanitizeText(request.data?.announcementId, 64);
  const reason = sanitizeText(request.data?.reason, 1000);
  if (!announcementId) throw new HttpsError("invalid-argument", "announcementId is required.");
  if (reason.length < 5) throw new HttpsError("invalid-argument", "A reason is required.");

  const ref = db.collection("announcements").doc(announcementId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Announcement not found.");

  await ref.update({
    status: "withdrawn",
    withdrawnAt: admin.firestore.FieldValue.serverTimestamp(),
    withdrawnBy: uid,
    withdrawnReason: reason,
  });

  await writeAuditLog(db, {
    action: AUDIT.announcementUnpublished,
    actorUid: uid,
    actorEmail: actor.email,
    actorRole: ROLES.superAdmin,
    targetType: "announcement",
    targetId: announcementId,
    reason,
  });

  return { ok: true };
});
