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
const { Timestamp, FieldValue } = require("firebase-admin/firestore");
const crypto = require("crypto");
const { onCall, HttpsError } = require("firebase-functions/v2/https");

const {
  sanitizeText,
  normEmail,
  isValidEmail,
  escapeHtml,
  checkRateLimit,
  sendMail,
  createMailTransport,
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

/**
 * A student may be linked to at most this many parent accounts.
 *
 * Kept equal to the limit index.js applies to the older activation path, so a
 * student cannot end up with more guardians through one route than the other.
 */
const MAX_PARENTS_PER_STUDENT = 2;

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
  return Timestamp.fromMillis(Date.now() + TTL_DAYS * 86400000);
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
    role === "parent"
      ? 'Already have an account for another child? Sign in, choose "Add a child", and enter this code there.'
      : null,
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

  const html = emailShell({
    heading: "Your FieldTrip360 registration code",
    bodyHtml: `
      <p style="margin:0 0 14px;font-size:15px;color:#374151;">Hello ${escapeHtml(recipientName || "there")},</p>
      <p style="margin:0 0 18px;font-size:15px;color:#374151;line-height:1.55;">${escapeHtml(opening)}</p>
      <div style="background:#F3F4F6;border-radius:12px;padding:18px;text-align:center;margin:0 0 18px;">
        <div style="font-size:12px;color:#6B7280;letter-spacing:.08em;text-transform:uppercase;margin-bottom:6px;">Registration code</div>
        <div style="font-size:24px;font-weight:700;letter-spacing:2px;color:#111827;">${escapeHtml(code)}</div>
      </div>
      <p style="margin:0 0 14px;font-size:14px;color:#374151;line-height:1.55;">
        Open the FieldTrip360 app, choose <b>I have a code</b>, enter it, and set the password
        you want to use. That is the whole registration. ${escapeHtml(whatItDoes)}
      </p>
      ${
        role === "parent"
          ? `<p style="margin:0 0 14px;font-size:13.5px;color:#6B7280;line-height:1.55;">
        Already have a FieldTrip360 account for another child? Sign in and choose
        <b>Add a child</b>, then enter this code there.
      </p>`
          : ""
      }
      <p style="margin:0 0 14px;font-size:14px;color:#111827;line-height:1.55;">
        <b>This code can be used once, and it expires in ${days} days — on ${escapeHtml(on)}.</b>
        After that the school will need to send you a new one.
      </p>
      <p style="margin:0;font-size:13px;color:#6B7280;line-height:1.55;">
        If you were not expecting this, please tell the school — someone used your address to send it.
      </p>
      ${base ? `<p style="margin:14px 0 0;font-size:13px;"><a href="${escapeHtml(base)}">${escapeHtml(base)}</a></p>` : ""}
    `,
  });

  return { text, html };
}

// ─── Issuing ─────────────────────────────────────────────────────────────────

/**
 * Writes one code and emails it. Any code already outstanding for the same
 * subject is revoked first, so a re-send cannot leave two usable codes behind.
 */
async function issueOne(
  db,
  { role, subjectId, email, recipientName, studentName, rosterId, guardianId, schoolId, schoolName, byUid, transporter }
) {
  const outstanding = await db
    .collection(COLLECTION)
    .where("subjectId", "==", subjectId)
    .where("status", "==", STATUS.pending)
    .get();
  const batch = db.batch();
  outstanding.forEach((d) =>
    batch.update(d.ref, { status: STATUS.revoked, revokedAt: Timestamp.now() })
  );
  if (!outstanding.empty) await batch.commit();

  const code = generateCode(role);
  const expiresAt = expiryTimestamp();

  const codeRef = await db.collection(COLLECTION).add({
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
    createdAt: Timestamp.now(),
    createdBy: byUid,
    usedAt: null,
    usedByUid: null,
  });

  // The administrator's lists read this off the guardian and roster records, so
  // "a code is out" is visible where they already look rather than only here.
  const holder =
    role === "student" && rosterId
      ? db.collection("roster").doc(rosterId)
      : role === "parent" && guardianId
        ? db.collection("guardians").doc(guardianId)
        : null;
  const mark = async (fields) => {
    if (holder) await holder.update(fields).catch(() => {});
  };
  const sentAt = Timestamp.now();
  await mark(
    role === "student"
      ? { codeStatus: "sent", codeSentAt: sentAt, codeExpiresAt: expiresAt }
      : { activationStatus: "sent", activationSentAt: sentAt, updatedAt: sentAt }
  );

  const { text, html } = codeEmail({ role, recipientName, studentName, schoolName, code, expiresAt });
  try {
    await sendMail({
      to: email,
      subject: "Your FieldTrip360 registration code",
      text,
      html,
      transporter,
    });
  } catch (e) {
    // A code that was never delivered must not sit there looking usable: it
    // would be the only one outstanding for this person, and nobody holds it.
    await codeRef.update({ status: STATUS.revoked, revokedAt: Timestamp.now() });
    await mark(
      role === "student"
        ? { codeStatus: null, codeSentAt: null, codeExpiresAt: null }
        : { activationStatus: null, activationSentAt: null }
    );
    throw e;
  }

  return { email, role, expiresAt };
}

/**
 * Issues a code to each student and guardian handed in, skipping anyone who
 * already has an account.
 *
 * Shared by the import, which sends as it writes, and by the administrator's
 * own button, which sends to whoever is still waiting — so the two can never
 * disagree about who gets a code or what it says.
 *
 * A person with no email address is not an error. The school may not have one
 * yet. They are returned in `missingEmail` so the administrator can see exactly
 * who is waiting, and they get a code as soon as an address is added.
 *
 * Capped per run so a two-thousand-row file cannot outlast the function's
 * timeout; whatever is left is reported as `remaining` and sent on the next run.
 */
async function issueBatch(db, { students = [], guardians = [], schoolId, schoolName, byUid }) {
  const MAX_PER_RUN = 300;

  const sent = [];
  const missingEmail = [];
  const failed = [];

  let transporter;
  try {
    transporter = createMailTransport();
  } catch (_) {
    // SMTP unconfigured: every attempt below reports its own failure.
  }

  let attempted = 0;
  let remaining = 0;

  const work = [
    ...students.map((s) => ({ kind: "student", ...s })),
    ...guardians.map((g) => ({ kind: "parent", ...g })),
  ];

  for (const item of work) {
    const email = normEmail(item.email);
    if (!email || !isValidEmail(email)) {
      missingEmail.push({
        kind: item.kind,
        rosterId: item.rosterId || null,
        guardianId: item.guardianId || null,
        name: item.recipientName || "",
        studentName: item.studentName || "",
      });
      continue;
    }
    if (attempted >= MAX_PER_RUN) {
      remaining++;
      continue;
    }
    attempted++;
    try {
      await issueOne(db, {
        role: item.kind,
        subjectId: item.kind === "student" ? `roster:${item.rosterId}` : `guardian:${item.guardianId}`,
        rosterId: item.rosterId,
        guardianId: item.guardianId,
        email,
        recipientName: item.recipientName,
        studentName: item.studentName,
        schoolId,
        schoolName,
        byUid,
        transporter,
      });
      sent.push({ kind: item.kind, email });
    } catch (e) {
      console.error("enrollment: code not sent", { kind: item.kind, error: e.message });
      failed.push({
        kind: item.kind,
        email,
        name: item.recipientName || "",
        reason: e.message,
      });
    }
  }

  try {
    if (transporter) transporter.close();
  } catch (_) {
    /* pool already torn down */
  }

  return {
    sent: sent.length,
    students: sent.filter((s) => s.kind === "student").length,
    parents: sent.filter((s) => s.kind === "parent").length,
    missingEmail,
    failed,
    remaining,
    expiresInDays: TTL_DAYS,
  };
}

/**
 * Sends codes to everyone at the administrator's school who has an email on
 * record and no account yet.
 *
 * Also the way to re-send: issuing again revokes whatever was outstanding for
 * that person, so a lost or expired code is replaced rather than duplicated.
 */
exports.issueEnrollmentCodes = onCall({ timeoutSeconds: 540 }, async (request) => {
  const { uid, db, schoolId } = await requireSchoolAdmin(request);
  await checkRateLimit(uid, "issueEnrollmentCodes", 10);

  const only = request.data?.only; // "student" | "parent" | undefined = both
  const rosterIds = Array.isArray(request.data?.rosterIds) ? request.data.rosterIds : null;
  const guardianIds = Array.isArray(request.data?.guardianIds) ? request.data.guardianIds : null;

  const schoolSnap = await db.collection("schools").doc(schoolId).get();
  const schoolName = schoolSnap.get("name") || "Your school";

  const students = [];
  // Naming specific guardians means exactly those guardians; the students on the
  // same rows were not asked for.
  if (only !== "parent" && !guardianIds) {
    const snap = await db.collection("roster").where("schoolId", "==", schoolId).get();
    for (const doc of snap.docs) {
      if (rosterIds && !rosterIds.includes(doc.id)) continue;
      const r = doc.data();
      if (r.claimedUid) continue; // already has an account
      students.push({
        rosterId: doc.id,
        email: r.email,
        recipientName: r.firstName || r.name,
        studentName: r.name,
      });
    }
  }

  const guardians = [];
  if (only !== "student") {
    const snap = await db.collection("guardians").where("schoolId", "==", schoolId).get();
    for (const doc of snap.docs) {
      const g = doc.data();
      if (g.parentUid) continue; // already has an account
      if (guardianIds && !guardianIds.includes(doc.id)) continue;
      if (rosterIds && !rosterIds.includes(g.studentId)) continue;
      guardians.push({
        guardianId: doc.id,
        rosterId: g.studentId || null,
        email: g.email,
        recipientName: g.name,
        studentName: g.studentName,
      });
    }
  }

  return issueBatch(db, { students, guardians, schoolId, schoolName, byUid: uid });
});

/** Withdraws an outstanding code without issuing a replacement. */
exports.revokeEnrollmentCode = onCall(async (request) => {
  const { uid, db, schoolId } = await requireSchoolAdmin(request);
  await checkRateLimit(uid, "revokeEnrollmentCode", 60);

  // Named either by the code itself or by the person it was issued to — the
  // administrator's lists know the guardian or the student, not a code id.
  const codeId = sanitizeText(request.data?.codeId, 200);
  const guardianId = sanitizeText(request.data?.guardianId, 200);
  const rosterId = sanitizeText(request.data?.rosterId, 200);
  if (!codeId && !guardianId && !rosterId) {
    throw new HttpsError("invalid-argument", "Say whose code to withdraw.");
  }

  let refs;
  if (codeId) {
    refs = [db.collection(COLLECTION).doc(codeId)];
  } else {
    const subjectId = guardianId ? `guardian:${guardianId}` : `roster:${rosterId}`;
    const open = await db
      .collection(COLLECTION)
      .where("subjectId", "==", subjectId)
      .where("status", "==", STATUS.pending)
      .get();
    refs = open.docs.map((d) => d.ref);
  }

  let revoked = 0;
  const now = Timestamp.now();
  for (const ref of refs) {
    const snap = await ref.get();
    if (!snap.exists) continue;
    if (snap.get("schoolId") !== schoolId) {
      throw new HttpsError("permission-denied", "That code belongs to another school.");
    }
    if (snap.get("status") !== STATUS.pending) continue;
    await ref.update({ status: STATUS.revoked, revokedAt: now, revokedBy: uid });
    revoked++;

    // Put the list back the way it was, or it keeps saying a code is out.
    if (snap.get("role") === "parent" && snap.get("guardianId")) {
      await db
        .collection("guardians")
        .doc(snap.get("guardianId"))
        .update({ activationStatus: null, activationSentAt: null, updatedAt: now })
        .catch(() => {});
    } else if (snap.get("role") === "student" && snap.get("rosterId")) {
      await db
        .collection("roster")
        .doc(snap.get("rosterId"))
        .update({ codeStatus: null, codeSentAt: null, codeExpiresAt: null })
        .catch(() => {});
    }
  }

  if (!revoked && codeId) {
    throw new HttpsError("failed-precondition", "That code is no longer outstanding.");
  }
  return { revoked };
});

/**
 * Sets or corrects the email address on a student who has not registered, and
 * sends them a code straight away.
 *
 * An import may carry a student with no address; that row is not refused, it
 * waits. This is how it stops waiting. The address is the only place the code
 * goes, so it is checked against the school's own roster and against existing
 * accounts before anything is sent.
 */
exports.setRosterEmail = onCall(async (request) => {
  const { uid, db, schoolId } = await requireSchoolAdmin(request);
  await checkRateLimit(uid, "setRosterEmail", 60);

  const rosterId = sanitizeText(request.data?.rosterId, 200);
  const email = normEmail(request.data?.email);
  const sendCode = request.data?.sendCode !== false;
  if (!rosterId) throw new HttpsError("invalid-argument", "rosterId is required.");
  if (!email || !isValidEmail(email)) {
    throw new HttpsError("invalid-argument", "Enter a valid email address.");
  }

  const ref = db.collection("roster").doc(rosterId);
  const snap = await ref.get();
  if (!snap.exists || snap.get("schoolId") !== schoolId) {
    throw new HttpsError("not-found", "Student not found on your roster.");
  }
  if (snap.get("claimedUid")) {
    throw new HttpsError(
      "failed-precondition",
      "This student already has an account, so the address they registered with stays."
    );
  }

  // Two students on one address would make one code open the wrong account.
  const dup = await db
    .collection("roster")
    .where("schoolId", "==", schoolId)
    .where("email", "==", email)
    .limit(2)
    .get();
  if (dup.docs.some((d) => d.id !== rosterId)) {
    throw new HttpsError(
      "already-exists",
      "Another student on your roster already uses that address."
    );
  }
  try {
    await admin.auth().getUserByEmail(email);
    throw new HttpsError(
      "already-exists",
      "That address already belongs to an account, so a registration code cannot be sent to it."
    );
  } catch (e) {
    if (e instanceof HttpsError) throw e;
    if (e.code !== "auth/user-not-found") throw e;
  }

  await ref.update({ email });

  if (!sendCode) return { saved: true, sent: false };

  const schoolSnap = await db.collection("schools").doc(schoolId).get();
  const r = await issueBatch(db, {
    students: [
      {
        rosterId,
        email,
        recipientName: snap.get("firstName") || snap.get("name"),
        studentName: snap.get("name"),
      },
    ],
    schoolId,
    schoolName: schoolSnap.get("name") || "Your school",
    byUid: uid,
  });
  return { saved: true, sent: r.sent > 0, failed: r.failed };
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
      updatedAt: Timestamp.now(),
    });
    batch.update(studentRef, {
      parentIds: FieldValue.arrayUnion(g.parentUid),
    });
    batch.update(parentRef, {
      children: FieldValue.arrayUnion(studentUid),
      schoolIds: FieldValue.arrayUnion(schoolId),
    });
    await batch.commit();
    linked.push(g.parentUid);
  }
  return linked;
}

/**
 * Finds the student a guardian record points at, if that student has an
 * account, and refuses early when the student already has their full complement
 * of parents.
 *
 * This runs before anything is created. A parent turned away at the last step
 * would otherwise be left with a half-built account and a code that still
 * reads as unused.
 */
async function studentForGuardian(db, guardian, parentUid) {
  const rosterSnap = guardian.studentId
    ? await db.collection("roster").doc(guardian.studentId).get()
    : null;
  const studentUid =
    guardian.studentUid || (rosterSnap?.exists ? rosterSnap.get("claimedUid") : null) || null;
  if (!studentUid) return null;

  const studentSnap = await db.collection("users").doc(studentUid).get();
  const parentIds = studentSnap.get("parentIds") || [];
  if (!parentIds.includes(parentUid) && parentIds.length >= MAX_PARENTS_PER_STUDENT) {
    throw new HttpsError(
      "failed-precondition",
      `${guardian.studentName || "This student"} already has ${MAX_PARENTS_PER_STUDENT} linked parents.`
    );
  }
  return studentUid;
}

/**
 * Attaches a parent account to the guardian record a code named, and to the
 * student when that student already has an account.
 *
 * Shared by first-time registration and by adding a further child, so the two
 * cannot drift apart on what "linked" means. The guardian record is marked in
 * the same terms the older activation path used, because the administrator's
 * guardian list reads those fields.
 *
 * A parent whose child has not registered yet is not an error. The guardian
 * record already names the parent, and completePendingGuardianLinks finishes
 * the link the moment the student arrives.
 */
async function linkGuardianToParent(db, { guardianRef, guardian, parentUid, codeRef, schoolId }) {
  const now = Timestamp.now();
  const studentUid = await studentForGuardian(db, guardian, parentUid);

  const parentUpdate = {
    schoolIds: FieldValue.arrayUnion(schoolId),
  };
  if (studentUid) parentUpdate.children = FieldValue.arrayUnion(studentUid);

  const batch = db.batch();
  batch.update(guardianRef, {
    parentUid,
    studentUid: studentUid || null,
    status: "activated",
    activationStatus: "used",
    activatedAt: now,
    updatedAt: now,
  });
  batch.update(codeRef, { status: STATUS.used, usedAt: now, usedByUid: parentUid });
  batch.update(db.collection("users").doc(parentUid), parentUpdate);
  if (studentUid) {
    batch.update(db.collection("users").doc(studentUid), {
      parentIds: FieldValue.arrayUnion(parentUid),
    });
  }
  await batch.commit();

  return { childLinked: !!studentUid, studentUid };
}

/**
 * Creates a student, parent or — through the older path — teacher account from a
 * code.
 *
 * This is the only endpoint in the enrolment flow with no authentication, and
 * it is written accordingly: the address on the account comes from the code,
 * never from the request, so a caller who guesses a code still cannot point it
 * at an address of their choosing.
 *
 * The caller also sends the version of the Terms and Privacy Notice they agreed
 * to. Registration used to record that on the account; it still must, because
 * the consent is what makes holding this data lawful.
 */
exports.redeemEnrollmentCode = onCall(async (request) => {
  const db = admin.firestore();

  // No uid to throttle against, so throttle the caller's address instead.
  await checkRateLimit(`ip:${callerAddress(request)}`, "redeem_enrollment", 10);

  const raw = sanitizeText(request.data?.code, 60);
  const password = typeof request.data?.password === "string" ? request.data.password : "";
  const acceptedTermsVersion = sanitizeText(request.data?.acceptedTermsVersion, 20);

  if (normalizeCode(raw).length < 6 || !roleFromCode(raw)) {
    throw new HttpsError("invalid-argument", "That does not look like a registration code.");
  }
  // The consent is checked on the server as well as in the screen. A screen can
  // be skipped; this cannot.
  if (!acceptedTermsVersion) {
    throw new HttpsError(
      "failed-precondition",
      "Please read and accept the Terms & Conditions and Privacy Notice to continue."
    );
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
      "You already have an account. Sign in, choose \"Add a child\", and enter this code " +
        "there — it will be added to the account you already have."
    );
  }

  // Everything that can refuse someone happens before the account exists, so a
  // refusal never leaves a half-built account behind.
  let rosterRef = null;
  let roster = null;
  let guardianRef = null;
  let guardian = null;
  if (role === "student") {
    rosterRef = db.collection("roster").doc(code.rosterId);
    const snap = await rosterRef.get();
    if (!snap.exists) throw new HttpsError("not-found", "That code is not valid.");
    roster = snap.data();
  } else {
    guardianRef = db.collection("guardians").doc(code.guardianId);
    const snap = await guardianRef.get();
    if (!snap.exists) throw new HttpsError("not-found", "That code is not valid.");
    guardian = snap.data();
    await studentForGuardian(db, guardian, null);
  }

  const schoolSnap = await db.collection("schools").doc(schoolId).get();
  const schoolName = schoolSnap.exists ? schoolSnap.get("name") || null : null;

  const userRecord = await admin.auth().createUser({
    email,
    password,
    displayName: code.recipientName || undefined,
    emailVerified: true,
  });
  const uid = userRecord.uid;
  const now = Timestamp.now();

  // A failure past this point must not strand the person: the account would
  // exist, the code would still read as unused, and their next attempt would be
  // told they already have an account. So it is taken back out.
  const rollback = async () => {
    await db.collection("users").doc(uid).delete().catch(() => {});
    await admin.auth().deleteUser(uid).catch(() => {});
  };

  const consent = {
    termsAcceptedVersion: acceptedTermsVersion,
    termsAcceptedAt: now,
  };

  let linked = null;
  try {
    if (role === "student") {
      await db.collection("users").doc(uid).set({
        uid,
        email,
        role: "student",
        status: "approved",
        schoolId,
        rosterId: rosterRef.id,
        name: roster.name || code.recipientName || "",
        firstName: roster.firstName || null,
        surname: roster.lastName || null,
        // The learner reference number comes off the roster; the student is never
        // asked to type it, so it cannot be mistyped or invented.
        studentId: roster.studentNumber || null,
        lrn: roster.studentNumber || null,
        gradeLevel: roster.gradeLevel || null,
        section: roster.section || null,
        parentIds: [],
        ...consent,
        createdAt: now,
        createdVia: "enrollmentCode",
      });

      const batch = db.batch();
      batch.update(rosterRef, { claimedUid: uid, status: "claimed", claimedAt: now });
      batch.update(ref, { status: STATUS.used, usedAt: now, usedByUid: uid });
      await batch.commit();
    } else {
      await db.collection("users").doc(uid).set({
        uid,
        email,
        role: "parent",
        status: "approved",
        name: guardian.name || code.recipientName || "",
        phone: guardian.phone || null,
        schoolIds: [schoolId],
        children: [],
        ...consent,
        createdAt: now,
        createdVia: "enrollmentCode",
      });

      linked = await linkGuardianToParent(db, {
        guardianRef,
        guardian,
        parentUid: uid,
        codeRef: ref,
        schoolId,
      });
    }
  } catch (e) {
    await rollback();
    throw e;
  }

  if (role === "student") {
    // The account and the code are settled; attaching parents who registered
    // first is best-effort, and a failure here must not undo the student.
    let parentsLinked = 0;
    try {
      parentsLinked = (
        await completePendingGuardianLinks(db, {
          rosterId: code.rosterId,
          studentUid: uid,
          schoolId,
        })
      ).length;
    } catch (e) {
      console.error("enrollment: pending guardian links not completed", { uid, error: e.message });
    }
    return { created: true, role, email, schoolName, parentsLinked };
  }

  return {
    created: true,
    role,
    email,
    schoolName,
    childLinked: linked.childLinked,
    // When false the account exists and works; the child appears automatically
    // as soon as they register, so there is nothing for the parent to do.
    childPending: !linked.childLinked,
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
  const userSnap = await db.collection("users").doc(uid).get();
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
  const guardian = guardianSnap.data();

  if (guardian.parentUid && guardian.parentUid !== uid) {
    throw new HttpsError(
      "failed-precondition",
      "That child is already linked to a different parent account."
    );
  }

  const linked = await linkGuardianToParent(db, {
    guardianRef,
    guardian,
    parentUid: uid,
    codeRef: ref,
    schoolId: code.schoolId,
  });

  return {
    added: true,
    childLinked: linked.childLinked,
    childPending: !linked.childLinked,
    studentName: guardian.studentName || null,
  };
});

module.exports.TTL_DAYS = TTL_DAYS;
module.exports.issueBatch = issueBatch;
module.exports.MIN_PASSWORD = MIN_PASSWORD;
module.exports._internal = { generateCode, normalizeCode, roleFromCode, hashCode, codeEmail };
