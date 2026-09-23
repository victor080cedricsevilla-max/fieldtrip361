/**
 * Attendance: scanned, manual, and the geofence-warning exemptions that ride
 * alongside it.
 *
 * Attendance is written here and nowhere else. Security rules stop a client
 * from touching `trips.buses` at all, so a scan cannot skip the token, the
 * assignment checks or the location check by writing the array directly. Every
 * write runs inside a transaction, which is what keeps two facilitators
 * scanning at the same door from overwriting each other.
 *
 * The location that matters is the STUDENT'S. A facilitator standing inside the
 * geofence proves nothing about where the student is, which was the hole the
 * old flow had.
 */
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

const { sanitizeText, checkRateLimit } = require("./common");
const { requireActiveUser, getPlatformConfig } = require("./platform");

const SOURCE = { qr: "qr", manual: "manual" };

/**
 * Thresholds. Deliberately configurable: 100 m is a sensible floor for urban
 * Philippine GPS plus a bus queue, but a school with a large campus stop may
 * need more, and a tighter venue may want less.
 */
const DEFAULTS = {
  tokenTtlSeconds: 30,
  // A fix older than this cannot show where the student is *now*.
  locationMaxAgeSeconds: 120,
  // A fix this vague cannot be compared to a geofence at all.
  maxAccuracyMeters: 100,
  // Added to the stop's radius so ordinary GPS error is not read as absence.
  geofenceSlackMeters: 25,
};

async function attendanceConfig(db) {
  const stored = await getPlatformConfig(db, "attendance");
  return { ...DEFAULTS, ...stored };
}

// ─── Geometry ─────────────────────────────────────────────────────────────────

function distanceMeters(lat1, lng1, lat2, lng2) {
  const R = 6371000;
  const toRad = (d) => (d * Math.PI) / 180;
  const dLat = toRad(lat2 - lat1);
  const dLng = toRad(lng2 - lng1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(a));
}

/**
 * Decides what a student's stored position can and cannot tell us about the
 * active stop.
 *
 * Pure, and separated from the callable, because the ORDER of these checks is
 * the whole point and it deserves to be tested directly.
 *
 * The case that drives it: a student's phone dies at destination 2 and the
 * group moves on to destination 3. The saved position still sits at
 * destination 2. Measured against destination 3 it is kilometres away — but
 * that is not evidence of absence, it is evidence that the phone stopped
 * reporting. Every freshness and quality check therefore runs BEFORE the
 * distance comparison, so a stale fix can only ever come back as
 * `unverifiable`, never as `outside`.
 *
 * Returns `{ verdict, reason, distanceM, ageSeconds, accuracyM }` where verdict
 * is 'inside' | 'outside' | 'unverifiable'.
 */
function evaluateStudentLocation({ loc, stop, radius, config, now = Date.now() }) {
  const observedMs =
    loc?.observedAt?.toMillis?.() ??
    (typeof loc?.observedAtMs === "number" ? loc.observedAtMs : null) ??
    loc?.lastUpdate?.toMillis?.() ??
    null;
  const ageSeconds = observedMs === null ? null : (now - observedMs) / 1000;
  const accuracy = Number(loc?.accuracy);
  const accuracyM = Number.isFinite(accuracy) ? accuracy : null;

  const no = (reason) => ({
    verdict: "unverifiable",
    reason,
    distanceM: null,
    ageSeconds: ageSeconds === null ? null : Math.round(ageSeconds),
    accuracyM: accuracyM === null ? null : Math.round(accuracyM),
  });

  if (!loc || typeof loc.lat !== "number" || typeof loc.lng !== "number") {
    return no("no_fix");
  }
  if (loc.isMocked === true) return no("mocked");
  if (observedMs === null) return no("no_timestamp");
  if (ageSeconds > config.locationMaxAgeSeconds) return no("stale");
  if (accuracyM !== null && accuracyM > config.maxAccuracyMeters) return no("inaccurate");

  // Only now is the position recent and precise enough to mean anything.
  const slack = Math.max(config.geofenceSlackMeters, accuracyM ?? 0);
  const distance = distanceMeters(loc.lat, loc.lng, stop.lat, stop.lng);

  return {
    verdict: distance > radius + slack ? "outside" : "inside",
    reason: null,
    distanceM: Math.round(distance),
    ageSeconds: Math.round(ageSeconds),
    accuracyM: accuracyM === null ? null : Math.round(accuracyM),
  };
}

// ─── Shared checks ────────────────────────────────────────────────────────────

/** Finds a student in a trip's buses. Returns null when they are not on it. */
function findPassenger(buses, studentId) {
  for (let bi = 0; bi < buses.length; bi++) {
    const passengers = buses[bi].passengers || [];
    for (let pi = 0; pi < passengers.length; pi++) {
      if (passengers[pi].id === studentId) {
        return { busIndex: bi, passengerIndex: pi, passenger: passengers[pi] };
      }
    }
  }
  return null;
}

/** True when this uid drives or supervises any bus on the trip. */
function teacherBusIndex(buses, uid) {
  for (let bi = 0; bi < buses.length; bi++) {
    const b = buses[bi] || {};
    if (b.mainTeacher?.id === uid || b.coTeacher?.id === uid) return bi;
  }
  return -1;
}

/**
 * The facilitator of one bus, asserted to be assigned to it.
 *
 * Only a teacher assigned to a bus on this trip reaches attendance. An
 * administrator sets a trip up — buses, stops, assignments, forms — and that is
 * where their part ends: they are not on the bus, so they are in no position to
 * say who boarded it. The security rules enforce the same boundary by refusing
 * an administrator's write to `buses` once a trip has left `pending`.
 *
 * The returned `busIndex` is the bus this teacher runs, and every caller uses it
 * to confine what they may touch to the students on that bus.
 */
async function requireTripFacilitator(request, tripId) {
  const { uid, db, data: user } = await requireActiveUser(request);
  if (user.role !== "teacher") {
    throw new HttpsError(
      "permission-denied",
      user.role === "admin"
        ? "Attendance is recorded by the facilitators on the bus. An administrator sets the trip up but does not mark students present."
        : "Only a trip facilitator can record attendance."
    );
  }
  if (user.mustChangePassword === true) {
    throw new HttpsError(
      "failed-precondition",
      "Change your temporary password before running a trip."
    );
  }

  const tripRef = db.collection("trips").doc(tripId);
  const tripSnap = await tripRef.get();
  if (!tripSnap.exists) throw new HttpsError("not-found", "Trip not found.");
  const trip = tripSnap.data();

  const busIndex = teacherBusIndex(trip.buses || [], uid);
  if (busIndex === -1) {
    throw new HttpsError("permission-denied", "You are not assigned to a bus on this trip.");
  }

  return { uid, db, user, tripRef, trip, busIndex };
}

/**
 * Finds a student on the facilitator's OWN bus, and refuses politely when they
 * are on another one.
 *
 * A Bus 1 teacher knows who is on Bus 1. Letting them record a Bus 2 student
 * would put a name on a roster nobody on that bus checked, and would make two
 * facilitators' counts disagree about the same child.
 */
function requireOwnPassenger(trip, busIndex, studentId) {
  const buses = trip.buses || [];
  const onThisBus = (buses[busIndex]?.passengers || []).findIndex(
    (p) => p && p.id === studentId
  );
  if (onThisBus !== -1) {
    return { busIndex, passengerIndex: onThisBus, passenger: buses[busIndex].passengers[onThisBus] };
  }

  const elsewhere = findPassenger(buses, studentId);
  if (elsewhere) {
    const label =
      buses[elsewhere.busIndex]?.busLabel ?? `${elsewhere.busIndex + 1}`;
    throw new HttpsError(
      "permission-denied",
      `${elsewhere.passenger.name || "That student"} is assigned to Bus ${label}. ` +
        `Their own bus facilitator records their attendance.`
    );
  }
  throw new HttpsError("not-found", "That student is not assigned to this trip.");
}

/** Marks one passenger present, inside a transaction, without clobbering others. */
async function writeAttendance(db, tripRef, { studentId, stopIndex, entry }) {
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(tripRef);
    if (!snap.exists) throw new HttpsError("not-found", "Trip not found.");
    const trip = snap.data();
    const buses = JSON.parse(JSON.stringify(trip.buses || []));

    const found = findPassenger(buses, studentId);
    if (!found) {
      throw new HttpsError("not-found", "That student is not assigned to this trip.");
    }

    const passenger = buses[found.busIndex].passengers[found.passengerIndex];
    const attendance = passenger.attendance || {};
    const key = `stop_${stopIndex}`;
    if (attendance[key] === true) {
      return {
        already: true,
        studentName: passenger.name || "Student",
        busIndex: found.busIndex,
      };
    }

    attendance[key] = true;
    passenger.attendance = attendance;

    // Who recorded it, how, and why — kept beside the boolean so a report can
    // tell a scan from a facilitator's judgement call.
    const meta = passenger.attendanceMeta || {};
    meta[key] = entry;
    passenger.attendanceMeta = meta;

    tx.update(tripRef, {
      buses,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });

    return {
      already: false,
      studentName: passenger.name || "Student",
      busIndex: found.busIndex,
    };
  });
}

// ─── Student: present a code ──────────────────────────────────────────────────

/**
 * Issues a short-lived, single-use attendance token for the calling student.
 *
 * The QR the student shows carries only this token id, so a screenshot is worth
 * nothing a few seconds later — and even inside the window it still has to pass
 * the location check when it is redeemed.
 */
exports.issueAttendanceToken = onCall(async (request) => {
  const { uid, db, data: user } = await requireActiveUser(request);
  if (user.role !== "student") {
    throw new HttpsError("permission-denied", "Only a student presents an attendance code.");
  }
  await checkRateLimit(uid, "attendance_token", 30);

  const tripId = sanitizeText(request.data?.tripId, 64);
  if (!tripId) throw new HttpsError("invalid-argument", "tripId is required.");

  const tripSnap = await db.collection("trips").doc(tripId).get();
  if (!tripSnap.exists) throw new HttpsError("not-found", "Trip not found.");
  const trip = tripSnap.data();

  if (trip.status !== "in_progress") {
    throw new HttpsError("failed-precondition", "This trip is not running right now.");
  }
  const found = findPassenger(trip.buses || [], uid);
  if (!found) {
    throw new HttpsError("permission-denied", "You are not assigned to this trip.");
  }

  const stopIndex = Number.isInteger(trip.activeStopIndex) ? trip.activeStopIndex : -1;
  if (stopIndex < 0) {
    throw new HttpsError(
      "failed-precondition",
      "The trip has not arrived at a destination yet."
    );
  }

  const config = await attendanceConfig(db);
  const now = Date.now();
  const jti = require("crypto").randomBytes(16).toString("hex");

  const ref = db.collection("qrTokens").doc();
  await ref.set({
    studentId: uid,
    tripId,
    stopIndex,
    schoolId: trip.schoolId || null,
    jti,
    used: false,
    exp: now + config.tokenTtlSeconds * 1000,
    issuedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  return {
    tokenId: ref.id,
    jti,
    stopIndex,
    expiresAt: now + config.tokenTtlSeconds * 1000,
    ttlSeconds: config.tokenTtlSeconds,
  };
});

// ─── Facilitator: scan a code ─────────────────────────────────────────────────

/**
 * Redeems a scanned token and records attendance.
 *
 * Refusals are specific on purpose: "not in the vicinity" and "cannot verify
 * the location" are different problems with different fixes, and a facilitator
 * standing in front of the student needs to know which one they have.
 */
exports.recordAttendanceScan = onCall(async (request) => {
  const tripId = sanitizeText(request.data?.tripId, 64);
  const tokenId = sanitizeText(request.data?.tokenId, 64);
  const jti = sanitizeText(request.data?.jti, 64);
  if (!tripId || !tokenId) {
    throw new HttpsError("invalid-argument", "tripId and tokenId are required.");
  }

  const { uid, db, trip, tripRef, busIndex } = await requireTripFacilitator(request, tripId);
  await checkRateLimit(uid, "attendance_scan", 120);

  const config = await attendanceConfig(db);

  if (trip.status !== "in_progress") {
    throw new HttpsError("failed-precondition", "This trip is not running right now.");
  }
  const activeStop = Number.isInteger(trip.activeStopIndex) ? trip.activeStopIndex : -1;
  if (activeStop < 0) {
    throw new HttpsError(
      "failed-precondition",
      "Mark the bus as arrived at a destination before scanning."
    );
  }

  // 1. Consume the token. Single-use is enforced here, not by deletion alone,
  //    so a replay after a partial failure is still refused.
  const tokenRef = db.collection("qrTokens").doc(tokenId);
  const token = await db.runTransaction(async (tx) => {
    const snap = await tx.get(tokenRef);
    if (!snap.exists) {
      throw new HttpsError("not-found", "This code is not valid. Ask the student to refresh it.");
    }
    const data = snap.data();
    if (data.used === true) {
      throw new HttpsError(
        "already-exists",
        "This code has already been used. Ask the student to refresh it."
      );
    }
    if (Date.now() > Number(data.exp || 0)) {
      throw new HttpsError(
        "deadline-exceeded",
        "This code has expired. Ask the student to refresh it."
      );
    }
    if (jti && data.jti && data.jti !== jti) {
      throw new HttpsError("permission-denied", "This code has been altered.");
    }
    if (data.tripId !== tripId) {
      throw new HttpsError("failed-precondition", "This code is for a different trip.");
    }
    if (data.stopIndex !== activeStop) {
      throw new HttpsError(
        "failed-precondition",
        "This code was issued for a different destination. Ask the student to refresh it."
      );
    }
    tx.update(tokenRef, {
      used: true,
      usedAt: admin.firestore.Timestamp.now(),
      usedBy: uid,
    });
    return data;
  });

  const studentId = token.studentId;

  // 2. The student must be on THIS facilitator's bus. Assignment is re-read
  //    here rather than trusted from the token.
  const passenger = requireOwnPassenger(trip, busIndex, studentId);

  // 3. The stop must have a geofence to check against. Without one there is
  //    nothing to verify, and silently accepting would defeat the whole point.
  const stops = trip.stops || [];
  const stop = stops[activeStop];
  const radius = Number(stop?.geofenceRadius);
  if (
    !stop ||
    typeof stop.lat !== "number" ||
    typeof stop.lng !== "number" ||
    !Number.isFinite(radius) ||
    radius <= 0
  ) {
    throw new HttpsError(
      "failed-precondition",
      "This destination has no geofence set, so attendance cannot be verified automatically. " +
        "Use manual attendance and record the reason."
    );
  }

  // 4. The student's own last position.
  const locSnap = await db.collection("locations").doc(studentId).get();
  const loc = locSnap.exists ? locSnap.data() : null;
  const studentName = passenger.passenger.name || "Student";

  // 5. What the student's position can and cannot tell us. The ordering of
  //    these checks lives in evaluateStudentLocation, where it is unit-tested.
  const verdict = evaluateStudentLocation({ loc, stop, radius, config });
  const { distanceM, ageSeconds, accuracyM } = verdict;

  const describeAge = () => {
    if (ageSeconds === null) return "never reported";
    if (ageSeconds < 90) return `${ageSeconds} seconds ago`;
    if (ageSeconds < 5400) return `${Math.round(ageSeconds / 60)} minutes ago`;
    return `${Math.round(ageSeconds / 3600)} hours ago`;
  };

  if (verdict.verdict === "unverifiable") {
    // "We cannot tell where they are" is a different answer from "they are
    // elsewhere", and it is the one a facilitator gets when a phone dies
    // mid-trip. It must never be phrased as absence.
    const detail = {
      no_fix: `Location unavailable for ${studentName} — their device has never reported a position.`,
      mocked: `${studentName}'s device is reporting a simulated location, so it cannot be trusted.`,
      no_timestamp: `Location unavailable for ${studentName} — no reliable timestamp.`,
      stale: `Location unavailable for ${studentName}. Last updated ${describeAge()}, which cannot show where they are now.`,
      inaccurate: `Location unavailable for ${studentName} — accurate only to about ${accuracyM} m, which is too vague to check against this destination.`,
    }[verdict.reason];

    throw new HttpsError(
      "failed-precondition",
      `${detail} Use manual attendance if ${studentName} is with you.`,
      {
        kind: "location_unverifiable",
        reason: verdict.reason,
        studentName,
        lastObservedAgoSeconds: ageSeconds,
        accuracyM,
      }
    );
  }

  if (verdict.verdict === "outside") {
    // Exact wording, kept verbatim for the facilitator-facing message. The
    // supporting numbers travel in `details` so the app can show context
    // without changing the sentence.
    throw new HttpsError("failed-precondition", "Location is not in the vicinity.", {
      kind: "outside_geofence",
      studentName,
      distanceM,
      radiusM: Math.round(radius),
      stopName: stop.name || null,
      lastObservedAgoSeconds: ageSeconds,
      accuracyM,
    });
  }

  const distance = distanceM;

  // 6. Record it.
  const teacherLat = Number(request.data?.teacherLat);
  const teacherLng = Number(request.data?.teacherLng);
  const teacherDistance =
    Number.isFinite(teacherLat) && Number.isFinite(teacherLng)
      ? Math.round(distanceMeters(loc.lat, loc.lng, teacherLat, teacherLng))
      : null;

  const result = await writeAttendance(db, tripRef, {
    studentId,
    stopIndex: activeStop,
    entry: {
      source: SOURCE.qr,
      by: uid,
      at: admin.firestore.Timestamp.now(),
      tokenJti: token.jti || null,
      distanceToStopM: distance,
      accuracyM,
      locationAgeSeconds: ageSeconds,
      distanceToFacilitatorM: teacherDistance,
    },
  });

  return {
    ok: true,
    already: result.already,
    studentName: result.studentName,
    distanceToStopM: Math.round(distance),
  };
});

// ─── Facilitator: mark by hand ────────────────────────────────────────────────

/**
 * Records attendance for a student the facilitator can physically see.
 *
 * This is the answer to a flat battery, a lost phone or a GPS that will not
 * fix — and it is deliberately not a silent alternative: it needs an explicit
 * confirmation of presence and a reason, and it is distinguishable from a scan
 * everywhere it is later read.
 */
exports.recordManualAttendance = onCall(async (request) => {
  const tripId = sanitizeText(request.data?.tripId, 64);
  const studentId = sanitizeText(request.data?.studentId, 128);
  const reason = sanitizeText(request.data?.reason, 500);
  const confirmedPresent = request.data?.confirmedPresent === true;
  const stopIndexInput = request.data?.stopIndex;

  if (!tripId || !studentId) {
    throw new HttpsError("invalid-argument", "tripId and studentId are required.");
  }
  if (!confirmedPresent) {
    throw new HttpsError(
      "failed-precondition",
      "Confirm that you can see the student before marking them present."
    );
  }
  if (reason.length < 3) {
    throw new HttpsError("invalid-argument", "Give a short reason — it appears in the report.");
  }

  const { uid, db, trip, tripRef, busIndex } = await requireTripFacilitator(request, tripId);
  await checkRateLimit(uid, "attendance_manual", 60);

  if (trip.status !== "in_progress") {
    throw new HttpsError("failed-precondition", "This trip is not running right now.");
  }
  // Same confinement as a scan: you may vouch for the students on your bus.
  requireOwnPassenger(trip, busIndex, studentId);
  const stopIndex = Number.isInteger(stopIndexInput)
    ? stopIndexInput
    : Number.isInteger(trip.activeStopIndex)
      ? trip.activeStopIndex
      : -1;
  if (stopIndex < 0 || stopIndex >= (trip.stops || []).length) {
    throw new HttpsError("failed-precondition", "Choose which destination this is for.");
  }

  const result = await writeAttendance(db, tripRef, {
    studentId,
    stopIndex,
    entry: {
      source: SOURCE.manual,
      by: uid,
      at: admin.firestore.Timestamp.now(),
      reason,
      confirmedPresent: true,
    },
  });

  await db.collection("activity_logs").add({
    action: "Manual Attendance",
    details: `${result.studentName} marked present at stop ${stopIndex + 1} — ${reason}`,
    adminEmail: request.auth.token.email || uid,
    tripId,
    studentId,
    timestamp: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { ok: true, already: result.already, studentName: result.studentName };
});

/**
 * Seat assignment, moved off the client so facilitators never write
 * `trips.buses` themselves — which is what makes the attendance lock-down in
 * the security rules possible.
 */
exports.setPassengerSeat = onCall(async (request) => {
  const tripId = sanitizeText(request.data?.tripId, 64);
  const studentId = sanitizeText(request.data?.studentId, 128);
  const seat = request.data?.seatNumber;
  if (!tripId || !studentId) {
    throw new HttpsError("invalid-argument", "tripId and studentId are required.");
  }
  if (seat !== null && !Number.isInteger(seat)) {
    throw new HttpsError("invalid-argument", "seatNumber must be a whole number or null.");
  }

  const { uid, db, trip, tripRef, busIndex } = await requireTripFacilitator(request, tripId);
  await checkRateLimit(uid, "set_seat", 120);
  requireOwnPassenger(trip, busIndex, studentId);

  await db.runTransaction(async (tx) => {
    const snap = await tx.get(tripRef);
    if (!snap.exists) throw new HttpsError("not-found", "Trip not found.");
    const buses = JSON.parse(JSON.stringify(snap.data().buses || []));
    const found = requireOwnPassenger({ buses }, busIndex, studentId);

    const passenger = buses[found.busIndex].passengers[found.passengerIndex];
    if (seat === null) {
      delete passenger.seatNumber;
    } else {
      // A seat already taken by someone else on the same bus is a mistake worth
      // refusing rather than silently double-booking.
      const clash = (buses[found.busIndex].passengers || []).find(
        (p) => p.id !== studentId && p.seatNumber === seat
      );
      if (clash) {
        throw new HttpsError(
          "already-exists",
          `Seat ${seat} is already assigned to ${clash.name || "another student"}.`
        );
      }
      passenger.seatNumber = seat;
    }

    tx.update(tripRef, {
      buses,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });

  return { ok: true };
});

// ─── Geofence-warning exemptions ──────────────────────────────────────────────

/**
 * Turns geofence warnings on or off for one student, for this trip only.
 *
 * This is separate from attendance on purpose: marking someone present does not
 * mute their warnings, and muting warnings does not mark them present. It also
 * never bypasses the automatic geofence check on a QR scan — a muted student
 * still has to be in the vicinity to be scanned in.
 */
exports.setGeofenceExemption = onCall(async (request) => {
  const tripId = sanitizeText(request.data?.tripId, 64);
  const studentId = sanitizeText(request.data?.studentId, 128);
  const warningsEnabled = request.data?.warningsEnabled !== false;
  const reason = sanitizeText(request.data?.reason, 500);

  if (!tripId || !studentId) {
    throw new HttpsError("invalid-argument", "tripId and studentId are required.");
  }
  if (!warningsEnabled && reason.length < 3) {
    throw new HttpsError(
      "invalid-argument",
      "Give a reason for pausing this student's warnings — it is shown on the roster."
    );
  }

  const { uid, db, trip, tripRef, busIndex } = await requireTripFacilitator(request, tripId);
  await checkRateLimit(uid, "geofence_exemption", 60);

  const passenger = requireOwnPassenger(trip, busIndex, studentId);

  const ref = tripRef.collection("geofenceExemptions").doc(studentId);
  const now = admin.firestore.FieldValue.serverTimestamp();

  await ref.set(
    {
      studentId,
      studentName: passenger.passenger.name || "Student",
      warningsEnabled,
      reason: warningsEnabled ? null : reason,
      setBy: uid,
      setByEmail: request.auth.token.email || null,
      setAt: now,
      history: admin.firestore.FieldValue.arrayUnion({
        warningsEnabled,
        reason: warningsEnabled ? "Warnings re-enabled" : reason,
        by: uid,
        at: admin.firestore.Timestamp.now(),
      }),
    },
    { merge: true }
  );

  // Suppressing warnings must also silence what is already ringing. Historical
  // alerts are kept, but the live ones are marked so every client that is
  // listening stops its alarm on the next snapshot.
  if (!warningsEnabled) {
    const pending = await tripRef
      .collection("alerts")
      .where("studentId", "==", studentId)
      .where("status", "==", "pending")
      .get();
    if (!pending.empty) {
      const batch = db.batch();
      pending.docs.forEach((d) =>
        batch.update(d.ref, {
          status: "suppressed",
          suppressedAt: now,
          suppressedBy: uid,
          suppressedReason: reason,
        })
      );
      await batch.commit();
    }
  }

  await db.collection("activity_logs").add({
    action: warningsEnabled ? "Geofence Warnings Enabled" : "Geofence Warnings Paused",
    details: `${passenger.passenger.name || studentId}${warningsEnabled ? "" : ` — ${reason}`}`,
    adminEmail: request.auth.token.email || uid,
    tripId,
    studentId,
    timestamp: now,
  });

  return { ok: true, warningsEnabled };
});

module.exports.SOURCE = SOURCE;
module.exports.distanceMeters = distanceMeters;
module.exports.evaluateStudentLocation = evaluateStudentLocation;
module.exports.findPassenger = findPassenger;
module.exports.requireOwnPassenger = requireOwnPassenger;
module.exports.teacherBusIndex = teacherBusIndex;
module.exports.DEFAULTS = DEFAULTS;
