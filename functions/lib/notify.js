/**
 * Delivering a message to the people a trip concerns.
 *
 * These four helpers used to live in index.js, where only the triggers in that
 * file could reach them. Attendance moved into lib/attendance.js, and a
 * facilitator's manual override is exactly the kind of event a parent needs to
 * hear about, so they live here now and both sides import them.
 *
 * Every send goes out twice on purpose: a push, which can be missed, muted or
 * arrive on a phone that is switched off, and an inbox document, which does
 * not. A parent who was out of signal still finds the notice waiting.
 *
 * **Scope is the caller's responsibility.** `parentsForStudents` returns the
 * guardians of whichever students it is given: pass one student and only that
 * child's parents are reached; pass the whole passenger list — as the trip-wide
 * arrival and departure notices deliberately do — and every parent on the bus
 * is. Anything about one student must pass a single-element array.
 */
const admin = require("firebase-admin");

if (!admin.apps.length) {
  admin.initializeApp();
}

/**
 * Guardians of the given students, as { parentIds, tokens }.
 *
 * Two paths, because linking has had two shapes: the parent document's
 * `children` array, and the older `parentId` field on the student. Both are
 * consulted so a student linked either way still reaches their guardian.
 */
async function parentsForStudents(studentIds) {
  if (!studentIds.length) return { parentIds: [], tokens: [] };
  const db = admin.firestore();
  const parentIdSet = new Set();
  const tokenSet = new Set();

  for (let i = 0; i < studentIds.length; i += 30) {
    const chunk = studentIds.slice(i, i + 30);
    const snap = await db
      .collection("users")
      .where("role", "==", "parent")
      .where("children", "array-contains-any", chunk)
      .get();
    snap.forEach((d) => {
      parentIdSet.add(d.id);
      (d.get("fcmTokens") || []).forEach((t) => tokenSet.add(t));
    });
  }

  for (const sid of studentIds) {
    const sdoc = await db.collection("users").doc(sid).get();
    const parentId = sdoc.exists && sdoc.get("parentId");
    if (parentId) {
      parentIdSet.add(parentId);
      const pdoc = await db.collection("users").doc(parentId).get();
      (pdoc.get("fcmTokens") || []).forEach((t) => tokenSet.add(t));
    }
  }

  return { parentIds: Array.from(parentIdSet), tokens: Array.from(tokenSet) };
}

/** FCM tokens for a list of student UIDs. */
async function tokensForStudents(studentIds) {
  if (!studentIds.length) return [];
  const db = admin.firestore();
  const tokenSet = new Set();
  for (let i = 0; i < studentIds.length; i += 30) {
    const chunk = studentIds.slice(i, i + 30);
    const snaps = await db
      .collection("users")
      .where(admin.firestore.FieldPath.documentId(), "in", chunk)
      .get();
    snaps.forEach((d) => (d.get("fcmTokens") || []).forEach((t) => tokenSet.add(t)));
  }
  return Array.from(tokenSet);
}

/** Pushes to a token list, chunked to FCM's 500-per-call ceiling. */
async function sendMulticast(tokens, title, body, extra) {
  if (!tokens.length) return;
  for (let i = 0; i < tokens.length; i += 450) {
    const chunk = tokens.slice(i, i + 450);
    await admin.messaging().sendEachForMulticast({
      tokens: chunk,
      notification: { title, body },
      data: Object.fromEntries(
        Object.entries(extra || {}).map(([k, v]) => [k, String(v)])
      ),
      android: {
        priority: "high",
        notification: { channelId: "fieldtrip_high_importance", sound: "default" },
      },
      apns: { payload: { aps: { sound: "default" } } },
    });
  }
}

/** Writes a notification document into each user's inbox sub-collection. */
async function writeUserNotifications(userIds, title, body, type, tripId) {
  if (!userIds.length) return;
  const db = admin.firestore();
  // Firestore caps a batch at 500 writes.
  for (let i = 0; i < userIds.length; i += 400) {
    const batch = db.batch();
    for (const uid of userIds.slice(i, i + 400)) {
      const ref = db.collection("users").doc(uid).collection("notifications").doc();
      batch.set(ref, {
        title,
        body,
        type,
        tripId: tripId || null,
        read: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
  }
}

/**
 * Tells one student's guardians something about that student.
 *
 * A single-element array is passed to parentsForStudents on purpose: a notice
 * naming a child must never reach the other parents on the bus. Delivery is
 * best-effort — a failed push must not roll back the attendance record that
 * prompted it, so the caller is not made to handle it.
 */
async function notifyGuardiansOfStudent(studentId, { title, body, type, tripId, data = {} }) {
  if (!studentId) return { parentIds: [], delivered: false };
  try {
    const { parentIds, tokens } = await parentsForStudents([studentId]);
    if (!parentIds.length && !tokens.length) return { parentIds: [], delivered: false };
    await sendMulticast(tokens, title, body, { tripId: tripId || "", studentId, ...data });
    await writeUserNotifications(parentIds, title, body, type, tripId);
    return { parentIds, delivered: true };
  } catch (e) {
    console.error("guardian notification failed", { studentId, type, error: e?.message || e });
    return { parentIds: [], delivered: false };
  }
}

module.exports = {
  parentsForStudents,
  tokensForStudents,
  sendMulticast,
  writeUserNotifications,
  notifyGuardiansOfStudent,
};
