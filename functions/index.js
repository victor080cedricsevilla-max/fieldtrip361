const { onCall, HttpsError } = require("firebase-functions/v2/https");
const { onDocumentUpdated, onDocumentWritten, onDocumentCreated } = require("firebase-functions/v2/firestore");
const { defineString } = require("firebase-functions/params");
const admin = require("firebase-admin");
const axios = require("axios");

if (!admin.apps.length) {
  admin.initializeApp();
}

const googleMapsKey = defineString("GOOGLE_MAPS_KEY");

// ─── Input sanitization ───────────────────────────────────────────────────────

function sanitizeText(text, maxLen = 2000) {
  if (typeof text !== "string") return "";
  return text
    .replace(/\0/g, "")        // strip null bytes (prompt-injection vector)
    .replace(/[<>]/g, "")      // strip angle brackets (XSS vector)
    .trim()
    .substring(0, maxLen);
}

// ─── Rate limiting ────────────────────────────────────────────────────────────
// Tracks per-user request timestamps in _rateLimits/{uid}_{action}.
// Allows up to `maxReqs` calls per 60-second sliding window.

async function checkRateLimit(uid, action, maxReqs = 30) {
  const db = admin.firestore();
  const ref = db.collection("_rateLimits").doc(`${uid}_${action}`);
  const now = Date.now();
  const windowStart = now - 60_000;

  await db.runTransaction(async (tx) => {
    const doc = await tx.get(ref);
    const prev = doc.exists ? (doc.data().timestamps || []) : [];
    const inWindow = prev.filter((t) => t > windowStart);
    if (inWindow.length >= maxReqs) {
      throw new HttpsError("resource-exhausted", "Too many requests. Please wait a moment.");
    }
    tx.set(ref, { timestamps: [...inWindow, now] });
  });
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function collectStudentIds(tripData) {
  const ids = new Set();
  for (const bus of tripData.buses || []) {
    for (const p of bus.passengers || []) {
      if (p && p.id) ids.add(p.id);
    }
  }
  return Array.from(ids);
}

/**
 * Returns { parentIds: string[], tokens: string[] } for the parents of
 * the given student IDs. Tries both parentOf array on parent doc and
 * parentId field on student doc.
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

/** Write a notification document to each parent's notifications subcollection. */
async function writeParentNotifications(parentIds, title, body, type, tripId) {
  if (!parentIds.length) return;
  const db = admin.firestore();
  const batch = db.batch();
  for (const pid of parentIds) {
    const ref = db
      .collection("users")
      .doc(pid)
      .collection("notifications")
      .doc();
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

// ─── Cloud Functions ──────────────────────────────────────────────────────────

exports.getGoogleDirections = onCall(async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");

  // 20 Directions API calls per minute per user.
  await checkRateLimit(request.auth.uid, "directions", 20);

  try {
    const apiKey = googleMapsKey.value();
    const origin = sanitizeText(request.data.origin || "", 500);
    const destination = sanitizeText(request.data.destination || "", 500);
    const waypoints = (request.data.waypoints || [])
      .map((w) => sanitizeText(w, 500))
      .filter(Boolean);

    if (!origin || !destination) {
      throw new HttpsError("invalid-argument", "origin and destination are required.");
    }

    const params = new URLSearchParams({ origin, destination, key: apiKey });
    if (waypoints.length > 0) params.append("waypoints", waypoints.join("|"));

    const url = `https://maps.googleapis.com/maps/api/directions/json?${params.toString()}`;
    const response = await axios.get(url);
    return response.data;
  } catch (error) {
    if (error instanceof HttpsError) throw error;
    console.error("getGoogleDirections error:", error);
    throw new HttpsError("internal", "Failed to fetch directions.");
  }
});

/**
 * On trip update: push parents on departure / next destination / completion.
 * Also writes notification docs into each parent's notifications subcollection
 * so the in-app bell shows them.
 */
exports.onTripUpdated = onDocumentUpdated("trips/{tripId}", async (event) => {
  const before = event.data.before.data() || {};
  const after = event.data.after.data() || {};
  const tripId = event.params.tripId;

  const studentIds = collectStudentIds(after);
  const { parentIds, tokens } = await parentsForStudents(studentIds);
  if (!tokens.length && !parentIds.length) return;

  const title = after.title || "Field Trip";
  const stops = after.stops || [];

  // 1. Per-stop arrive / depart notifications (driven by stopStatuses array).
  const oldSS = Array.isArray(before.stopStatuses) ? before.stopStatuses : [];
  const newSS = Array.isArray(after.stopStatuses) ? after.stopStatuses : [];
  for (let i = 0; i < newSS.length; i++) {
    const oldS = oldSS[i] || "pending";
    const newS = newSS[i];
    if (newS === oldS) continue;

    if (newS === "in_progress") {
      const stop = stops[i] || {};
      const stopName = stop.name || "destination";
      const isOrigin = i === 0;
      const body = isOrigin
        ? `The trip has started! Bus is at ${stopName}, taking attendance.`
        : `Bus has arrived at ${stopName}.`;
      const notifTitle = isOrigin
        ? `${title}: Trip started`
        : `${title}: Arrived at ${stopName}`;
      await sendMulticast(tokens, notifTitle, body, { tripId, kind: "arrived", stopIndex: String(i) });
      await writeParentNotifications(parentIds, notifTitle, body, "arrived", tripId);
    } else if (newS === "completed") {
      const stop = stops[i] || {};
      const stopName = stop.name || "stop";
      const nextStop = stops[i + 1];
      const body = nextStop
        ? `Bus has departed from ${stopName}, heading to ${nextStop.name || "next stop"}.`
        : `Bus has departed from ${stopName}.`;
      const notifTitle = nextStop
        ? `${title}: Heading to ${nextStop.name || "next stop"}`
        : `${title}: Departed from ${stopName}`;
      await sendMulticast(tokens, notifTitle, body, { tripId, kind: "departed_stop", stopIndex: String(i) });
      await writeParentNotifications(parentIds, notifTitle, body, "next_destination", tripId);
    }
    break; // One status change per Firestore write
  }

  // 2. Completion.
  if (before.status !== "completed" && after.status === "completed") {
    const body = "The field trip has ended. Students are heading home.";
    await sendMulticast(tokens, `${title}: trip completed`, body, { tripId, kind: "completed" });
    await writeParentNotifications(parentIds, `${title}: trip completed`, body, "trip_completed", tripId);
  }
});

/**
 * When a student's background service writes a geofence alert doc, push the
 * teacher(s) on that bus via FCM so they're alerted even when the app is closed.
 */
exports.onGeofenceAlertCreated = onDocumentCreated(
  "trips/{tripId}/alerts/{alertId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const data = snap.data() || {};
    const tripId = event.params.tripId;

    const db = admin.firestore();
    const tripDoc = await db.collection("trips").doc(tripId).get();
    if (!tripDoc.exists) return;
    const tripData = tripDoc.data();
    const tripTitle = tripData.title || "Field Trip";

    const tokens = [];
    for (const bus of tripData.buses || []) {
      for (const ref of [bus.mainTeacher, bus.coTeacher]) {
        if (ref && ref.id) {
          const tDoc = await db.collection("users").doc(ref.id).get();
          (tDoc.get("fcmTokens") || []).forEach((t) => tokens.push(t));
        }
      }
    }
    const studentName = sanitizeText(data.studentName || "A student", 100);

    // Push teachers.
    if (tokens.length) {
      await admin.messaging().sendEachForMulticast({
        tokens,
        notification: {
          title: `${tripTitle}: Geofence Alert`,
          body: `${studentName} has left the designated area.`,
        },
        data: { kind: "geofence_alert", tripId, studentId: data.studentId || "" },
        android: {
          priority: "high",
          notification: { channelId: "fieldtrip_high_importance", sound: "default" },
        },
        apns: { payload: { aps: { sound: "default" } } },
      });
    }

    // Also push the student so they get an OS notification even when the
    // background-service local notification is suppressed by the device.
    const studentId = data.studentId;
    if (studentId) {
      const studentDoc = await db.collection("users").doc(studentId).get();
      const studentTokens = (studentDoc.get("fcmTokens") || []).filter(Boolean);
      if (studentTokens.length) {
        await admin.messaging().sendEachForMulticast({
          tokens: studentTokens,
          notification: {
            title: "⚠️ Geofence Warning",
            body: "You have left the designated area. Return to the group immediately.",
          },
          data: { kind: "geofence_alert_student", tripId },
          android: {
            priority: "high",
            notification: { channelId: "fieldtrip_high_importance", sound: "default" },
          },
          apns: { payload: { aps: { sound: "default" } } },
        });
      }
    }
  }
);

/**
 * Auto-maintain group chats per bus per trip AND keep allMemberIds on the
 * trip document so Firestore security rules can restrict trip reads to
 * enrolled members only.
 */
exports.onTripChatSync = onDocumentWritten("trips/{tripId}", async (event) => {
  const after =
    event.data && event.data.after && event.data.after.exists
      ? event.data.after.data()
      : null;
  if (!after) return;

  const tripId = event.params.tripId;
  const tripTitle = after.title || "Field Trip";
  const buses = after.buses || [];
  const db = admin.firestore();

  // Collect every teacher + student UID across all buses for the trip-level
  // allMemberIds array used by the Firestore read rule.
  const allMemberSet = new Set();

  for (let i = 0; i < buses.length; i++) {
    const bus = buses[i] || {};
    const busLabel = (bus.busLabel || bus.busNo || i + 1).toString();
    const chatId = `${tripId}_${i}`;
    const chatRef = db.collection("chats").doc(chatId);

    const memberIds = new Set();
    const members = [];

    const main = bus.mainTeacher;
    if (main && main.id) {
      memberIds.add(main.id);
      allMemberSet.add(main.id);
      members.push({ id: main.id, name: main.name || "Teacher", role: "teacher" });
    }
    const co = bus.coTeacher;
    if (co && co.id) {
      memberIds.add(co.id);
      allMemberSet.add(co.id);
      members.push({ id: co.id, name: co.name || "Co-Teacher", role: "teacher" });
    }
    for (const p of bus.passengers || []) {
      if (p && p.id) {
        memberIds.add(p.id);
        allMemberSet.add(p.id);
        members.push({ id: p.id, name: p.name || "Student", role: "student" });
      }
    }

    const update = {
      tripId,
      busIndex: i,
      busLabel,
      tripTitle,
      name: `${tripTitle} - Bus ${busLabel}`,
      memberIds: Array.from(memberIds),
      members,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    };

    const existing = await chatRef.get();
    if (!existing.exists) {
      update.createdAt = admin.firestore.FieldValue.serverTimestamp();
      update.lastMessage = "";
      update.lastMessageAt = null;
      update.lastSenderId = null;
    }

    await chatRef.set(update, { merge: true });
  }

  // Write allMemberIds back onto the trip doc so Firestore rules can read it.
  await db.collection("trips").doc(tripId).set(
    { allMemberIds: Array.from(allMemberSet) },
    { merge: true }
  );
});

/**
 * On new chat message: denormalize preview + push all members except sender.
 * Text is sanitized before storing or broadcasting.
 */
exports.onChatMessageCreated = onDocumentCreated(
  "chats/{chatId}/messages/{messageId}",
  async (event) => {
    const snap = event.data;
    if (!snap) return;
    const data = snap.data() || {};
    const chatId = event.params.chatId;

    const text = sanitizeText((data.text || "").toString(), 2000);
    const senderId = data.senderId || null;
    const senderName = sanitizeText((data.senderName || "Someone").toString(), 100);

    const db = admin.firestore();
    const chatRef = db.collection("chats").doc(chatId);

    await chatRef.set(
      {
        lastMessage: text.substring(0, 200),
        lastMessageAt: data.createdAt || admin.firestore.FieldValue.serverTimestamp(),
        lastSenderId: senderId,
        lastSenderName: senderName,
      },
      { merge: true }
    );

    let chatDoc;
    try {
      chatDoc = await chatRef.get();
    } catch (e) {
      console.error("chat fetch failed", e);
      return;
    }
    if (!chatDoc.exists) return;

    const chatName = chatDoc.get("name") || "Chat";
    const memberIds = chatDoc.get("memberIds") || [];

    const tokens = [];
    for (const memberId of memberIds) {
      if (memberId === senderId) continue;
      try {
        const u = await db.collection("users").doc(memberId).get();
        (u.get("fcmTokens") || []).forEach((t) => { if (t) tokens.push(t); });
      } catch (_) {}
    }
    if (!tokens.length) return;

    const body = text.length > 120 ? `${text.substring(0, 117)}…` : text;
    try {
      await admin.messaging().sendEachForMulticast({
        tokens,
        notification: { title: chatName, body: `${senderName}: ${body}` },
        data: { kind: "chat_message", chatId, senderId: senderId || "" },
        android: {
          priority: "high",
          notification: { channelId: "fieldtrip_high_importance", sound: "default" },
        },
        apns: { payload: { aps: { sound: "default" } } },
      });
    } catch (e) {
      console.error("chat fanout failed", e);
    }
  }
);

/**
 * Approve a teacher account — callable by admins only.
 * Sets users/{uid}.status = 'approved' so the teacher can log in.
 */
exports.approveTeacher = onCall(async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
  const db = admin.firestore();
  const callerDoc = await db.collection("users").doc(request.auth.uid).get();
  if (!callerDoc.exists || callerDoc.get("role") !== "admin") {
    throw new HttpsError("permission-denied", "Admins only.");
  }
  const uid = request.data.uid;
  if (!uid || typeof uid !== "string") {
    throw new HttpsError("invalid-argument", "uid is required.");
  }
  await db.collection("users").doc(uid).update({ status: "approved" });
  return { success: true };
});

/**
 * Reject (delete) a pending teacher account — callable by admins only.
 */
exports.rejectTeacher = onCall(async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
  const db = admin.firestore();
  const callerDoc = await db.collection("users").doc(request.auth.uid).get();
  if (!callerDoc.exists || callerDoc.get("role") !== "admin") {
    throw new HttpsError("permission-denied", "Admins only.");
  }
  const uid = request.data.uid;
  if (!uid || typeof uid !== "string") {
    throw new HttpsError("invalid-argument", "uid is required.");
  }
  await admin.auth().deleteUser(uid);
  await db.collection("users").doc(uid).delete();
  return { success: true };
});

/**
 * Generate a short-lived (30 s) attendance QR token for the calling student.
 * Stores the token in users/{uid}/qrTokens/{tokenId} so the teacher's
 * redeemAttendanceToken function can verify it server-side.
 */
exports.generateAttendanceToken = onCall(async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
  await checkRateLimit(request.auth.uid, "qr_gen", 10);

  const uid = request.auth.uid;
  const { tripId, stopIndex } = request.data || {};
  if (!tripId || typeof stopIndex !== "number") {
    throw new HttpsError("invalid-argument", "tripId and stopIndex are required.");
  }

  const db = admin.firestore();
  const expMs = Date.now() + 30_000; // 30-second window
  // Store in top-level qrTokens so redemption only needs the tokenId.
  const ref = db.collection("qrTokens").doc();
  await ref.set({ studentId: uid, tripId, stopIndex, exp: expMs });

  return { tokenId: ref.id };
});

/**
 * Redeem a QR attendance token — called by the teacher's scanner.
 * The teacher only needs the tokenId; everything else is server-verified.
 */
exports.redeemAttendanceToken = onCall(async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
  await checkRateLimit(request.auth.uid, "qr_redeem", 60);

  const { tokenId } = request.data || {};
  if (!tokenId) throw new HttpsError("invalid-argument", "tokenId is required.");

  const db = admin.firestore();
  const tokenRef = db.collection("qrTokens").doc(tokenId);

  const tokenData = await db.runTransaction(async (tx) => {
    const snap = await tx.get(tokenRef);
    if (!snap.exists) throw new HttpsError("not-found", "Invalid QR code.");
    const data = snap.data();
    if (Date.now() > data.exp) throw new HttpsError("deadline-exceeded", "QR code expired.");
    tx.delete(tokenRef);
    return data;
  });

  const { studentId, tripId, stopIndex } = tokenData;

  // Mark attendance on the trip document.
  const tripRef = db.collection("trips").doc(tripId);
  const tripSnap = await tripRef.get();
  if (!tripSnap.exists) throw new HttpsError("not-found", "Trip not found.");

  // Deep-copy buses so we can mutate safely.
  const buses = JSON.parse(JSON.stringify(tripSnap.data().buses || []));
  let studentName = null;
  let alreadyScanned = false;

  outer:
  for (let bi = 0; bi < buses.length; bi++) {
    const passengers = buses[bi].passengers || [];
    for (let pi = 0; pi < passengers.length; pi++) {
      if (passengers[pi].id === studentId) {
        studentName = passengers[pi].name || "Student";
        const attendance = passengers[pi].attendance || {};
        if (attendance[`stop_${stopIndex}`] === true) {
          alreadyScanned = true;
        } else {
          attendance[`stop_${stopIndex}`] = true;
          passengers[pi].attendance = attendance;
          buses[bi].passengers = passengers;
          // Write back the full array — dot-notation on array indices converts
          // arrays to maps in Firestore, which breaks all downstream reads.
          await tripRef.update({
            buses,
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
          });
        }
        break outer;
      }
    }
  }

  if (!studentName) throw new HttpsError("not-found", "Student not found in this trip.");
  return { success: true, alreadyScanned, studentName };
});

/**
 * Approve a parent-student link request — called when the student taps
 * "Approve" in their dashboard. Updates the parent's children[] array.
 */
exports.approveLinkRequest = onCall(async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");

  const { requestId } = request.data || {};
  if (!requestId) throw new HttpsError("invalid-argument", "requestId is required.");

  const db = admin.firestore();
  const reqRef = db.collection("linkRequests").doc(requestId);

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(reqRef);
    if (!snap.exists) throw new HttpsError("not-found", "Request not found.");
    const data = snap.data();
    if (data.studentId !== request.auth.uid) {
      throw new HttpsError("permission-denied", "Only the student can approve this.");
    }
    if (data.status !== "pending") {
      throw new HttpsError("failed-precondition", "Request is no longer pending.");
    }
    // Mark approved and add student to parent's children array.
    tx.update(reqRef, { status: "approved" });
    tx.update(db.collection("users").doc(data.parentId), {
      children: admin.firestore.FieldValue.arrayUnion(data.studentId),
    });
  });

  return { success: true };
});
