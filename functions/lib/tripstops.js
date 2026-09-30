/**
 * Unscheduled stops — the things that happen between the planned ones.
 *
 * A bus pulls into a petrol station so the students can use the toilet. It is
 * not on the itinerary, nobody is in danger, and until now nobody outside the
 * bus knew it had happened: a parent watching the map saw the marker stop
 * moving in a place that was not a destination, and had to guess why.
 *
 * So the facilitator logs it, and the record answers the question the map
 * raises. Two kinds, with deliberately different reach:
 *
 *   stopover  — routine. The administrator and the parents are both told,
 *               always. It is information, and withholding it is what caused
 *               the worry in the first place.
 *
 *   emergency — the administrator is told, always and immediately. The parents
 *               are told only if the facilitator chooses to tell them. That is
 *               not secrecy: it is the recognition that the first minutes of an
 *               incident are the minutes when the facts are least reliable, and
 *               that forty families acting on a half-formed report can make a
 *               situation harder to manage. The school decides when to speak.
 *
 * This is separate from the student SOS in index.js. That is a student saying
 * something is wrong with them; this is a facilitator reporting something about
 * the journey. They need different responses, so they are different records.
 */
const admin = require("firebase-admin");
const { Timestamp, FieldValue } = require("firebase-admin/firestore");
const { onCall, HttpsError } = require("firebase-functions/v2/https");

const { sanitizeText, checkRateLimit } = require("./common");
const { teacherBusIndex } = require("./attendance");
const { sendMulticast, writeUserNotifications, parentsForStudents } = require("./notify");

const KIND = { stopover: "stopover", emergency: "emergency" };

/** School administrators, with their device tokens, for one school. */
async function schoolAdmins(db, schoolId) {
  if (!schoolId) return { adminIds: [], tokens: [] };
  const snap = await db
    .collection("users")
    .where("schoolId", "==", schoolId)
    .where("role", "==", "admin")
    .get();
  const adminIds = [];
  const tokens = new Set();
  snap.forEach((d) => {
    adminIds.push(d.id);
    (d.get("fcmTokens") || []).forEach((t) => tokens.add(t));
  });
  return { adminIds, tokens: Array.from(tokens) };
}

/**
 * Records an unscheduled stop and tells the people entitled to know.
 *
 * The bus is taken from the caller's own assignment rather than from the
 * request, so a facilitator can only report a stop for the bus they are on.
 */
exports.logUnscheduledStop = onCall(async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
  const uid = request.auth.uid;
  await checkRateLimit(uid, "logUnscheduledStop", 20);

  const db = admin.firestore();

  const tripId = sanitizeText(request.data?.tripId, 200);
  if (!tripId) throw new HttpsError("invalid-argument", "tripId is required.");

  const kind = request.data?.kind === KIND.emergency ? KIND.emergency : KIND.stopover;
  const reason = sanitizeText(request.data?.reason, 500);
  const place = sanitizeText(request.data?.place, 200);

  // Only meaningful for an emergency; a stopover always reaches the parents.
  // For an emergency it must be said outright — an absent or unclear value means
  // "do not", because a message to forty families cannot be taken back.
  const notifyParents =
    kind === KIND.stopover ? true : request.data?.notifyParents === true;

  const lat = Number(request.data?.lat);
  const lng = Number(request.data?.lng);
  const hasPosition = Number.isFinite(lat) && Number.isFinite(lng);

  const tripRef = db.collection("trips").doc(tripId);
  const tripSnap = await tripRef.get();
  if (!tripSnap.exists) throw new HttpsError("not-found", "Trip not found.");
  const trip = tripSnap.data();

  // A stop belongs to a journey that is under way. Before departure there is no
  // bus on the road to have stopped, and after it a late entry would tell
  // parents something that is no longer true.
  if (trip.status !== "in_progress") {
    throw new HttpsError(
      "failed-precondition",
      "A stop can only be logged while the trip is in progress."
    );
  }

  const buses = trip.buses || [];
  const busIndex = teacherBusIndex(buses, uid);
  if (busIndex < 0) {
    throw new HttpsError(
      "permission-denied",
      "Only a facilitator assigned to a bus on this trip can log a stop."
    );
  }

  const bus = buses[busIndex] || {};
  const busLabel = bus.busLabel ?? String(busIndex + 1);
  const passengers = (bus.passengers || []).map((p) => p && p.id).filter(Boolean);

  const now = Timestamp.now();
  const eventRef = db.collection("tripEvents").doc();
  await eventRef.set({
    tripId,
    schoolId: trip.schoolId || null,
    tripTitle: trip.title || null,
    kind,
    reason: reason || null,
    place: place || null,
    busIndex,
    busLabel,
    loggedBy: uid,
    loggedByName: bus.mainTeacher?.id === uid
      ? bus.mainTeacher?.name || null
      : bus.coTeacher?.name || null,
    lat: hasPosition ? lat : null,
    lng: hasPosition ? lng : null,
    parentsNotified: notifyParents,
    passengerCount: passengers.length,
    createdAt: now,
  });

  const where = place ? ` at ${place}` : "";
  const title =
    kind === KIND.emergency
      ? `Emergency reported — Bus ${busLabel}`
      : `Unscheduled stop — Bus ${busLabel}`;
  const body =
    kind === KIND.emergency
      ? `${trip.title || "The trip"}: the facilitator has reported an emergency${where}.` +
        (reason ? ` ${reason}` : "")
      : `${trip.title || "The trip"}: the bus has made an unscheduled stop${where}.` +
        (reason ? ` ${reason}` : "");

  const type = kind === KIND.emergency ? "trip_emergency" : "trip_stopover";

  // The administrator is told either way, and is told first.
  const { adminIds, tokens: adminTokens } = await schoolAdmins(db, trip.schoolId);
  if (adminIds.length || adminTokens.length) {
    await sendMulticast(adminTokens, title, body, { tripId, kind, busLabel });
    await writeUserNotifications(adminIds, title, body, type, tripId);
  } else {
    console.warn("unscheduled stop: no administrator to notify", {
      tripId,
      schoolId: trip.schoolId,
    });
  }

  let parentsReached = 0;
  if (notifyParents && passengers.length) {
    const { parentIds, tokens } = await parentsForStudents(passengers);
    if (parentIds.length || tokens.length) {
      await sendMulticast(tokens, title, body, { tripId, kind, busLabel });
      await writeUserNotifications(parentIds, title, body, type, tripId);
      parentsReached = parentIds.length;
    } else {
      console.warn("unscheduled stop: no linked guardian on this bus", {
        tripId,
        busIndex,
      });
    }
  }

  console.log("unscheduled stop logged", {
    tripId,
    kind,
    busLabel,
    admins: adminIds.length,
    parentsNotified: notifyParents,
    parentsReached,
  });

  return {
    logged: true,
    eventId: eventRef.id,
    kind,
    busLabel,
    adminsNotified: adminIds.length,
    parentsNotified: notifyParents,
    parentsReached,
  };
});

module.exports.KIND = KIND;
module.exports._internal = { schoolAdmins };
