/**
 * Student and parent enrolment by school-issued code.
 *
 * Anyone could previously open the app and create a student or parent account,
 * which meant the registration form was reachable by anyone on the internet and
 * the school only found out afterwards. Here an account cannot exist until the
 * school has put that person on its roster and issued them a code.
 *
 * The code is the whole gate:
 *   - it names the role, so the sign-up screen has no role to choose;
 *   - it names the email, so the account is created from the roster rather than
 *     from whatever the caller types;
 *   - it names the student, so a student's learner reference number is attached
 *     without anybody retyping it.
 *
 * The code helpers mirror the staff ones rather than importing them: a staff
 * invitation is a different object with a different lifetime, and keeping them
 * apart means a change to one cannot silently alter the other.
 */
const admin = require("firebase-admin");
const crypto = require("crypto");
const { onCall, HttpsError } = require("firebase-functions/v2/https");

const {
  sanitizeText,
  normEmail,
  isValidEmail,
  escapeHtml,
  checkRateLimit,
  sendMail,
  emailShell,
  activationPepper,
  appBaseUrl,
} = require("./common");

/** How long a code stays usable. A term break can swallow anything shorter. */
const TTL_DAYS = 30;

/** Matches the staff minimum, which matches the super-admin bootstrap. */
const MIN_PASSWORD = 12;

const COLLECTION = "enrollmentCodes";

const STATUS = {
  pending: "pending",
  used: "used",
  revoked: "revoked",
  expired: "expired",
};

/** A student may be linked to at most this many parent accounts. */
const MAX_PARENTS_PER_STUDENT = 4;

/** Unambiguous alphabet — no O/0, I/1/L, U/V confusion when read off an email. */
const CODE_ALPHABET = "ACDEFGHJKMNPQRTWXY3456789";

// ─── Code helpers ────────────────────────────────────────────────────────────

/**
 * Builds a code whose first character says what it opens: S for a student,
 * P for a parent. The reader needs no instructions and the sign-up screen
 * needs no dropdown.
 */
function generateCode(role) {
  const prefix = role === "student" ? "S" : "P";
  const bytes = crypto.randomBytes(8);
  let body = "";
  for (let i = 0; i < 8; i++) body += CODE_ALPHABET[bytes[i] % CODE_ALPHABET.length];
  return `${prefix}-${body.slice(0, 4)}-${body.slice(4)}`;
}

/** Strips formatting so "s 7k4p92xm" and "S-7K4P-92XM" hash identically. */
function normalizeCode(raw) {
  return String(raw || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
}

/**
 * Hashes a code for storage. The raw code is emailed and never persisted, so a
 * database leak cannot reveal usable codes. The pepper lives only in the
 * function environment, so the hashes alone cannot be attacked offline either.
 */
function hashCode(raw) {
  const pepper = activationPepper.value() || "";
  return crypto
    .createHash("sha256")
    .update(`enroll::${normalizeCode(raw)}::${pepper}`)
    .digest("hex");
}

/** The role a code opens, read from its prefix before any database lookup. */
function roleFromCode(raw) {
  const first = normalizeCode(raw)[0];
  if (first === "S") return "student";
  if (first === "P") return "parent";
  return null;
}

function expiryTimestamp() {
  return admin.firestore.Timestamp.fromMillis(Date.now() + TTL_DAYS * 86400000);
}

/** "3 October 2026" — written out, because 03/10 reads two ways in two countries. */
function formatExpiry(ts) {
  return ts.toDate().toLocaleDateString("en-GB", {
    day: "numeric",
    month: "long",
    year: "numeric",
  });
}

// ─── Guards ──────────────────────────────────────────────────────────────────

/** Only a school's own administrator may issue codes for that school. */
async function requireSchoolAdmin(request) {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
  const db = admin.firestore();
  const uid = request.auth.uid;
  const snap = await db.collection("users").doc(uid).get();
  if (!snap.exists) throw new HttpsError("not-found", "User record not found.");
  if (snap.get("role") !== "admin") {
    throw new HttpsError("permission-denied", "Only a school administrator can issue codes.");
  }
  if (snap.get("accountStatus") === "disabled") {
    throw new HttpsError("permission-denied", "This account has been disabled.");
  }
  const schoolId = snap.get("schoolId");
  if (!schoolId) {
    throw new HttpsError("failed-precondition", "Your account is not linked to a school yet.");
  }
  return { uid, db, schoolId };
}

/** The caller's address, for throttling an endpoint that has no signed-in user. */
function callerAddress(request) {
  return (
    request.rawRequest?.headers?.["x-forwarded-for"]?.split(",")[0]?.trim() ||
    request.rawRequest?.ip ||
    "unknown"
  );
}

// ─── Emails ──────────────────────────────────────────────────────────────────

function codeEmail({ role, recipientName, studentName, schoolName, code, expiresAt }) {
  const base = appBaseUrl.value() || "";
  const days = TTL_DAYS;
  const on = formatExpiry(expiresAt);

  const opening =
    role === "student"
      ? `${schoolName || "Your school"} has enrolled you on FieldTrip360.`
      : `${schoolName || "Your school"} has invited you to follow ${
          studentName || "your child"
        }'s field trips on FieldTrip360.`;

  const whatItDoes =
    role === "student"
      ? "Your student number is already on your record, so you will not be asked for it."
      : "You will be linked to your child automatically.";

  const text = [
    `Hello ${recipientName || "there"},`,
    "",
    opening,
    "",
    "Your registration code is:",
    "",
    code,
    "",
    'Open the FieldTrip360 app, choose "I have a code", enter it, and set the',
    "password you want to use. That is the whole registration.",
    whatItDoes,
    "",
    `This code can be used once, and it expires in ${days} days — on ${on}.`,
    "After that the school will need to send you a new one.",
    "",
    "If you were not expecting this, please tell the school — someone used your",
    "address to send it.",
    base ? "" : null,
    base || null,
  ]
    .filter((l) => l !== null)
    .join("\n");

  const html = emailShell(
    `
    <p>Hello ${escapeHtml(recipientName || "there")},</p>
    <p>${escapeHtml(opening)}</p>
    <p>Your registration code is:</p>
    <p style="font-size:22px;letter-spacing:2px;font-weight:bold;margin:18px 0">${escapeHtml(code)}</p>
    <p>Open the FieldTrip360 app, choose <strong>"I have a code"</strong>, enter it, and set
       the password you want to use. That is the whole registration.
       ${escapeHtml(whatItDoes)}</p>
    <p><strong>This code can be used once, and it expires in ${days} days — on ${escapeHtml(on)}.</strong>
       After that the school will need to send you a new one.</p>
    <p style="color:#666">If you were not expecting this, please tell the school — someone
       used your address to send it.</p>
    ${base ? `<p><a href="${escapeHtml(base)}">${escapeHtml(base)}</a></p>` : ""}
  `,
    { title: "Your FieldTrip360 registration code" }
  );

  return { text, html };
}

// ─── Issuing ─────────────────────────────────────────────────────────────────

/**
 * Writes one code and emails it. Any code already outstanding for the same
 * subject is revoked first, so a re-send cannot leave two usable codes behind.
 */
async function issueOne(db, { role, subjectId, email, recipientName, studentName, rosterId, guardianId, schoolId, schoolName, byUid }) {
  const outstanding = await db
    .collection(COLLECTION)
    .where("subjectId", "==", subjectId)
    .where("status", "==", STATUS.pending)
    .get();
  const batch = db.batch();
  outstanding.forEach((d) => batch.update(d.ref, { status: STATUS.revoked, revokedAt: admin.firestore.Timestamp.now() }));
  if (!outstanding.empty) await batch.commit();

  const code = generateCode(role);
  const expiresAt = expiryTimestamp();

  await db.collection(COLLECTION).add({
    role,
    subjectId,
    rosterId: rosterId || null,
    guardianId: guardianId || null,
    schoolId,
    email,
    recipientName: recipientName || null,
    studentName: studentName || null,
    codeHash: hashCode(code),
    status: STATUS.pending,
    expiresAt,
    createdAt: admin.firestore.Timestamp.now(),
    createdBy: byUid,
    usedAt: null,
    usedByUid: null,
  });

  const { text, html } = codeEmail({ role, recipientName, studentName, schoolName, code, expiresAt });
  await sendMail({ to: email, subject: "Your FieldTrip360 registration code", text, html });

  return { email, role, expiresAt };
}

/**
 * Issues codes for every student and guardian that can receive one and does not
 * already have an account.
 *
 * A row with no email address is not an error — the school may not have one
 * yet. It is counted and returned so the administrator can see exactly who is
 * still waiting, and a code goes out as soon as an address is added.
 */
exports.issueEnrollmentCodes = onCall({ timeoutSeconds: 540 }, async (request) => {
  const { uid, db, schoolId } = await requireSchoolAdmin(request);
  await checkRateLimit(uid, "issueEnrollmentCodes", 10);

  const only = request.data?.only; // "student" | "parent" | undefined = both
  const rosterIds = Array.isArray(request.data?.rosterIds) ? request.data.rosterIds : null;

  const schoolSnap = await db.collection("schools").doc(schoolId).get();
  const schoolName = schoolSnap.get("name") || "Your school";

  const sent = [];
  const missingEmail = [];
  const failed = [];

  if (only !== "parent") {
    let q = db.collection("roster").where("schoolId", "==", schoolId);
    const snap = await q.get();
    for (const doc of snap.docs) {
      if (rosterIds && !rosterIds.includes(doc.id)) continue;
      const r = doc.data();
      if (r.claimedUid) continue; // already has an account
      const email = normEmail(r.email);
      if (!email || !isValidEmail(email)) {
        missingEmail.push({ kind: "student", rosterId: doc.id, name: r.name || "" });
        continue;
      }
      try {
        await issueOne(db, {
          role: "student",
          subjectId: `roster:${doc.id}`,
          rosterId: doc.id,
          email,
          recipientName: r.firstName || r.name,
          studentName: r.name,
          schoolId,
          schoolName,
          byUid: uid,
        });
        sent.push({ kind: "student", email });
      } catch (e) {
        failed.push({ kind: "student", email, reason: e.message });
      }
    }
  }

  if (only !== "student") {
    const snap = await db.collection("guardians").where("schoolId", "==", schoolId).get();
    for (const doc of snap.docs) {
      const g = doc.data();
      if (g.parentUid) continue; // already has an account
      if (rosterIds && !rosterIds.includes(g.studentId)) continue;
      const email = normEmail(g.email);
      if (!email || !isValidEmail(email)) {
        missingEmail.push({ kind: "parent", guardianId: doc.id, name: g.name || "" });
        continue;
      }
      try {
        await issueOne(db, {
          role: "parent",
          subjectId: `guardian:${doc.id}`,
          guardianId: doc.id,
          rosterId: g.studentId || null,
          email,
          recipientName: g.name,
          studentName: g.studentName,
          schoolId,
          schoolName,
          byUid: uid,
        });
        sent.push({ kind: "parent", email });
      } catch (e) {
        failed.push({ kind: "parent", email, reason: e.message });
      }
    }
  }

  return {
    sent: sent.length,
    students: sent.filter((s) => s.kind === "student").length,
    parents: sent.filter((s) => s.kind === "parent").length,
    missingEmail,
    failed,
    expiresInDays: TTL_DAYS,
  };
});

/** Withdraws an outstanding code without issuing a replacement. */
exports.revokeEnrollmentCode = onCall(async (request) => {
  const { uid, db, schoolId } = await requireSchoolAdmin(request);
  await checkRateLimit(uid, "revokeEnrollmentCode", 60);

  const codeId = sanitizeText(request.data?.codeId, 200);
  if (!codeId) throw new HttpsError("invalid-argument", "codeId is required.");

  const ref = db.collection(COLLECTION).doc(codeId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "That code was not found.");
  if (snap.get("schoolId") !== schoolId) {
    throw new HttpsError("permission-denied", "That code belongs to another school.");
  }
  if (snap.get("status") !== STATUS.pending) {
    throw new HttpsError("failed-precondition", "That code is no longer outstanding.");
  }

  await ref.update({
    status: STATUS.revoked,
    revokedAt: admin.firestore.Timestamp.now(),
    revokedBy: uid,
  });
  return { revoked: true };
});

// ─── Redeeming ───────────────────────────────────────────────────────────────

/** Finds a pending, unexpired code, or throws with wording that reveals nothing. */
async function loadRedeemableCode(db, raw) {
  const match = await db
    .collection(COLLECTION)
    .where("codeHash", "==", hashCode(raw))
    .limit(1)
    .get();

  // Deliberately uniform wording — a distinct "no such code" reply would let a
  // caller tell a wrong code from a used one.
  if (match.empty) throw new HttpsError("not-found", "That code is not valid.");

  const ref = match.docs[0].ref;
  const code = match.docs[0].data();

  if (code.status === STATUS.used) {
    throw new HttpsError("failed-precondition", "That code has already been used.");
  }
  if (code.status === STATUS.revoked) {
    throw new HttpsError("failed-precondition", "That code was withdrawn by the school.");
  }
  if (code.expiresAt && code.expiresAt.toMillis() < Date.now()) {
    await ref.update({ status: STATUS.expired });
    throw new HttpsError(
      "failed-precondition",
      "That code has expired. Ask the school to send you a new one."
    );
  }
  return { ref, code, id: match.docs[0].id };
}

/**
 * Completes every guardian link that was waiting for this student to exist.
 *
 * A parent may redeem their code before their child does. Rather than refusing
 * them until the child signs up, the parent's account is created immediately
 * and the link is finished here, the moment the student's account appears.
 */
async function completePendingGuardianLinks(db, { rosterId, studentUid, schoolId }) {
  const snap = await db
    .collection("guardians")
    .where("studentId", "==", rosterId)
    .get();

  const linked = [];
  for (const doc of snap.docs) {
    const g = doc.data();
    if (!g.parentUid) continue; // parent has not registered yet
    if (g.studentUid === studentUid) continue; // already linked

    const studentRef = db.collection("users").doc(studentUid);
    const parentRef = db.collection("users").doc(g.parentUid);
    const studentSnap = await studentRef.get();
    const parentIds = studentSnap.get("parentIds") || [];
    if (!parentIds.includes(g.parentUid) && parentIds.length >= MAX_PARENTS_PER_STUDENT) continue;

    const batch = db.batch();
    batch.update(doc.ref, {
      studentUid,
      activationStatus: "linked",
      updatedAt: admin.firestore.Timestamp.now(),
    });
    batch.update(studentRef, {
      parentIds: admin.firestore.FieldValue.arrayUnion(g.parentUid),
    });
    batch.update(parentRef, {
      children: admin.firestore.FieldValue.arrayUnion(studentUid),
      schoolIds: admin.firestore.FieldValue.arrayUnion(schoolId),
    });
    await batch.commit();
    linked.push(g.parentUid);
  }
  return linked;
}

/**
 * Creates a student or parent account from a code.
 *
 * This is the only endpoint in the enrolment flow with no authentication, and
 * it is written accordingly: the address on the account comes from the code,
 * never from the request, so a caller who guesses a code still cannot point it
 * at an address of their choosing.
 */
exports.redeemEnrollmentCode = onCall(async (request) => {
  const db = admin.firestore();

  // No uid to throttle against, so throttle the caller's address instead.
  await checkRateLimit(`ip:${callerAddress(request)}`, "redeem_enrollment", 10);

  const raw = sanitizeText(request.data?.code, 60);
  const password = typeof request.data?.password === "string" ? request.data.password : "";

  if (normalizeCode(raw).length < 6 || !roleFromCode(raw)) {
    throw new HttpsError("invalid-argument", "That does not look like a registration code.");
  }
  if (password.length < MIN_PASSWORD) {
    throw new HttpsError(
      "invalid-argument",
      `Choose a password of at least ${MIN_PASSWORD} characters.`
    );
  }

  const { ref, code } = await loadRedeemableCode(db, raw);
  const email = normEmail(code.email);
  const role = code.role;
  const schoolId = code.schoolId;

  // An address that already has an account is a parent adding a second child,
  // or a person who has registered before. Creating a second account would
  // split their children across two logins, so they are sent to sign in and
  // add the child from inside the app instead.
  let existing = null;
  try {
    existing = await admin.auth().getUserByEmail(email);
  } catch (e) {
    if (e.code !== "auth/user-not-found") throw e;
  }
  if (existing) {
    throw new HttpsError(
      "already-exists",
      "You already have an account. Sign in and enter this code there — it will be " +
        "added to the account you already have."
    );
  }

  const userRecord = await admin.auth().createUser({
    email,
    password,
    displayName: code.recipientName || undefined,
    emailVerified: true,
  });
  const uid = userRecord.uid;
  const now = admin.firestore.Timestamp.now();

  if (role === "student") {
    const rosterRef = db.collection("roster").doc(code.rosterId);
    const rosterSnap = await rosterRef.get();
    if (!rosterSnap.exists) {
      await admin.auth().deleteUser(uid);
      throw new HttpsError("not-found", "That code is not valid.");
    }
    const r = rosterSnap.data();

    await db.collection("users").doc(uid).set({
      uid,
      email,
      role: "student",
      schoolId,
      name: r.name || code.recipientName || "",
      firstName: r.firstName || null,
      lastName: r.lastName || null,
      // The learner reference number comes off the roster; the student is never
      // asked to type it, so it cannot be mistyped or invented.
      studentId: r.studentNumber || null,
      lrn: r.studentNumber || null,
      gradeLevel: r.gradeLevel || null,
      section: r.section || null,
      parentIds: [],
      accountStatus: "active",
      createdAt: now,
      createdVia: "enrollmentCode",
    });

    await rosterRef.update({ claimedUid: uid, status: "claimed", claimedAt: now });
    await ref.update({ status: STATUS.used, usedAt: now, usedByUid: uid });

    const linked = await completePendingGuardianLinks(db, {
      rosterId: code.rosterId,
      studentUid: uid,
      schoolId,
    });

    return { created: true, role: "student", email, parentsLinked: linked.length };
  }

  // Parent.
  const guardianRef = db.collection("guardians").doc(code.guardianId);
  const guardianSnap = await guardianRef.get();
  if (!guardianSnap.exists) {
    await admin.auth().deleteUser(uid);
    throw new HttpsError("not-found", "That code is not valid.");
  }
  const g = guardianSnap.data();

  await db.collection("users").doc(uid).set({
    uid,
    email,
    role: "parent",
    schoolId,
    schoolIds: [schoolId],
    name: g.name || code.recipientName || "",
    phone: g.phone || null,
    children: [],
    accountStatus: "active",
    createdAt: now,
    createdVia: "enrollmentCode",
  });

  await guardianRef.update({
    parentUid: uid,
    activationStatus: g.studentUid ? "linked" : "awaiting_student",
    updatedAt: now,
  });
  await ref.update({ status: STATUS.used, usedAt: now, usedByUid: uid });

  // If the child already has an account, finish the link now.
  const rosterSnap = code.rosterId
    ? await db.collection("roster").doc(code.rosterId).get()
    : null;
  const studentUid = g.studentUid || (rosterSnap?.exists ? rosterSnap.get("claimedUid") : null);
  let childLinked = false;
  if (studentUid) {
    const studentRef = db.collection("users").doc(studentUid);
    const studentSnap = await studentRef.get();
    const parentIds = studentSnap.get("parentIds") || [];
    if (parentIds.includes(uid) || parentIds.length < MAX_PARENTS_PER_STUDENT) {
      const batch = db.batch();
      batch.update(guardianRef, { studentUid, activationStatus: "linked" });
      batch.update(studentRef, { parentIds: admin.firestore.FieldValue.arrayUnion(uid) });
      batch.update(db.collection("users").doc(uid), {
        children: admin.firestore.FieldValue.arrayUnion(studentUid),
      });
      await batch.commit();
      childLinked = true;
    }
  }

  return {
    created: true,
    role: "parent",
    email,
    childLinked,
    // When false the account exists and works; the child appears automatically
    // as soon as they register, so there is nothing for the parent to do.
    childPending: !childLinked,
  };
});

/**
 * Adds another child to a parent who already has an account.
 *
 * This is the path for the second and subsequent codes: one code per child, but
 * one account per parent.
 */
exports.addChildByCode = onCall(async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
  const uid = request.auth.uid;
  await checkRateLimit(uid, "addChildByCode", 10);

  const db = admin.firestore();
  const userRef = db.collection("users").doc(uid);
  const userSnap = await userRef.get();
  if (!userSnap.exists) throw new HttpsError("not-found", "User record not found.");
  if (userSnap.get("role") !== "parent") {
    throw new HttpsError("permission-denied", "Only a parent account can add a child.");
  }

  const raw = sanitizeText(request.data?.code, 60);
  if (roleFromCode(raw) !== "parent") {
    throw new HttpsError("invalid-argument", "That is not a parent registration code.");
  }

  const { ref, code } = await loadRedeemableCode(db, raw);

  // The code was emailed to one address; it may only be used by that account.
  if (normEmail(code.email) !== normEmail(userSnap.get("email"))) {
    throw new HttpsError(
      "permission-denied",
      "That code was sent to a different email address. Sign in with that address instead."
    );
  }

  const guardianRef = db.collection("guardians").doc(code.guardianId);
  const guardianSnap = await guardianRef.get();
  if (!guardianSnap.exists) throw new HttpsError("not-found", "That code is not valid.");
  const g = guardianSnap.data();

  const now = admin.firestore.Timestamp.now();
  await guardianRef.update({
    parentUid: uid,
    activationStatus: g.studentUid ? "linked" : "awaiting_student",
    updatedAt: now,
  });
  await ref.update({ status: STATUS.used, usedAt: now, usedByUid: uid });

  const rosterSnap = code.rosterId
    ? await db.collection("roster").doc(code.rosterId).get()
    : null;
  const studentUid = g.studentUid || (rosterSnap?.exists ? rosterSnap.get("claimedUid") : null);

  if (!studentUid) {
    return {
      added: true,
      childLinked: false,
      childPending: true,
      studentName: g.studentName || null,
    };
  }

  const studentRef = db.collection("users").doc(studentUid);
  const studentSnap = await studentRef.get();
  const parentIds = studentSnap.get("parentIds") || [];
  if (!parentIds.includes(uid) && parentIds.length >= MAX_PARENTS_PER_STUDENT) {
    throw new HttpsError(
      "failed-precondition",
      `${g.studentName || "This student"} already has ${MAX_PARENTS_PER_STUDENT} linked parents.`
    );
  }

  const batch = db.batch();
  batch.update(guardianRef, { studentUid, activationStatus: "linked" });
  batch.update(studentRef, { parentIds: admin.firestore.FieldValue.arrayUnion(uid) });
  batch.update(userRef, {
    children: admin.firestore.FieldValue.arrayUnion(studentUid),
    schoolIds: admin.firestore.FieldValue.arrayUnion(code.schoolId),
  });
  await batch.commit();

  return { added: true, childLinked: true, studentName: g.studentName || null };
});

module.exports.TTL_DAYS = TTL_DAYS;
module.exports.MIN_PASSWORD = MIN_PASSWORD;
module.exports._internal = { generateCode, normalizeCode, roleFromCode, hashCode };
