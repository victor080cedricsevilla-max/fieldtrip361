/**
 * Teaching staff: invitation, redemption, and removal.
 *
 * A teacher used to sign up the way a student did — pick "teacher" from a
 * dropdown and you were one, instantly approved, belonging to no school. That
 * meant anyone at all could become a teacher, and every school's trip planner
 * listed every teacher in the database. Both of those are closed here.
 *
 * The model is the one already used for guardians, and it holds because of
 * where identity comes from: **the school chooses the address**. An
 * administrator invites a named person at a school email; the code goes only to
 * that address; redeeming it creates the account with the school already
 * attached. There is no self-registration to approve, so there is no queue of
 * strangers for an administrator to guess about.
 *
 * Removal ends the *link*, never the account. Attendance entries carry the
 * facilitator's uid, and buses carry their id, so deleting a teacher who has
 * resigned would leave last term's reports unable to say who recorded what.
 * A former teacher keeps their account, loses their access, and can be invited
 * by their next school.
 */
const { onCall, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");
const crypto = require("crypto");

const {
  sanitizeText,
  normEmail,
  isValidEmail,
  checkRateLimit,
  createMailTransport,
  sendMail,
  emailShell,
  escapeHtml,
  appBaseUrl,
  activationPepper,
} = require("./common");

const INVITE_STATUS = {
  unused: "unused",
  used: "used",
  revoked: "revoked",
  expired: "expired",
};

/** How long an invitation stays usable. Long enough for a school holiday. */
const INVITE_TTL_DAYS = 14;

/** Matches the platform minimum used by the super-admin bootstrap. */
const MIN_PASSWORD = 12;

// The code helpers below deliberately mirror the guardian ones rather than
// importing them: index.js owns those, and a staff invite is a different
// object with a different lifetime. Keeping them separate means a change to
// one cannot silently alter the other.

/** Unambiguous alphabet — no O/0, I/1/L, U/V confusion when read off an email. */
const CODE_ALPHABET = "ACDEFGHJKMNPQRTWXY3456789";

function schoolCodePrefix(schoolName) {
  const letters = String(schoolName || "SCHOOL")
    .toUpperCase()
    .replace(/[^A-Z ]/g, "")
    .split(/\s+/)
    .filter(Boolean)
    .map((w) => w[0])
    .join("");
  return (letters || "ST").slice(0, 3);
}

function generateInviteCode(schoolName) {
  const bytes = crypto.randomBytes(8);
  let body = "";
  for (let i = 0; i < 8; i++) body += CODE_ALPHABET[bytes[i] % CODE_ALPHABET.length];
  return `${schoolCodePrefix(schoolName)}-${body.slice(0, 4)}-${body.slice(4)}`;
}

/** Strips formatting so "nu 7k4p92xm" and "NU-7K4P-92XM" hash identically. */
function normalizeCode(raw) {
  return String(raw || "").toUpperCase().replace(/[^A-Z0-9]/g, "");
}

/**
 * Hashes a code for storage. The raw code is emailed and never persisted, so a
 * database leak cannot reveal usable invitations.
 */
function hashCode(raw) {
  const pepper = activationPepper.value() || "";
  return crypto
    .createHash("sha256")
    .update(`staff::${normalizeCode(raw)}::${pepper}`)
    .digest("hex");
}

/** Admins of a school may manage its staff. Teachers may not invite peers. */
async function requireSchoolAdmin(request) {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
  const db = admin.firestore();
  const uid = request.auth.uid;
  const snap = await db.collection("users").doc(uid).get();
  if (!snap.exists) throw new HttpsError("not-found", "User record not found.");
  if (snap.get("role") !== "admin") {
    throw new HttpsError("permission-denied", "Only a school administrator can manage staff.");
  }
  if (snap.get("accountStatus") === "disabled") {
    throw new HttpsError("permission-denied", "This account has been disabled.");
  }
  const schoolId = snap.get("schoolId");
  if (!schoolId) {
    throw new HttpsError("failed-precondition", "Your account is not linked to a school yet.");
  }
  return { uid, db, schoolId, actor: snap.data() || {} };
}

function inviteEmail({ teacherName, schoolName, code }) {
  const base = appBaseUrl.value() || "";
  const text = [
    `Hello ${teacherName || "there"},`,
    "",
    `${schoolName || "Your school"} has invited you to FieldTrip360 as a trip facilitator.`,
    "",
    "Your invitation code is:",
    "",
    code,
    "",
    "Open the FieldTrip360 app, choose \"I have an invitation code\", and enter it to",
    "set your password and finish setting up your account.",
    "",
    `This code expires in ${INVITE_TTL_DAYS} days and can only be used once.`,
    "",
    "If you were not expecting this, please tell your school administrator — someone",
    "used your address to send it.",
    base ? "" : null,
    base ? base : null,
  ].filter((l) => l !== null).join("\n");

  const html = emailShell({
    heading: "You have been invited as a trip facilitator",
    bodyHtml: `
      <p style="margin:0 0 14px;font-size:15px;color:#374151;">Hello ${escapeHtml(teacherName || "there")},</p>
      <p style="margin:0 0 18px;font-size:15px;color:#374151;line-height:1.55;">
        ${escapeHtml(schoolName || "Your school")} has invited you to FieldTrip360 as a trip facilitator.
      </p>
      <div style="background:#F3F4F6;border-radius:12px;padding:18px;text-align:center;margin:0 0 18px;">
        <div style="font-size:12px;color:#6B7280;letter-spacing:.08em;text-transform:uppercase;margin-bottom:6px;">Invitation code</div>
        <div style="font-size:24px;font-weight:700;letter-spacing:.12em;color:#111827;font-family:ui-monospace,Menlo,Consolas,monospace;">${escapeHtml(code)}</div>
      </div>
      <p style="margin:0 0 14px;font-size:14px;color:#4B5563;line-height:1.55;">
        Open the FieldTrip360 app, choose <b>I have an invitation code</b>, and enter it to set
        your password and finish setting up your account.
      </p>
      <p style="margin:0 0 14px;font-size:13px;color:#6B7280;">
        This code expires in ${INVITE_TTL_DAYS} days and can only be used once.
      </p>
      <p style="margin:0;font-size:13px;color:#6B7280;line-height:1.5;">
        If you were not expecting this, please tell your school administrator — someone used
        your address to send it.
      </p>`,
    footerHtml: "You are receiving this because a school administrator entered your address.",
  });

  return { text, html };
}

// ─── Invite ───────────────────────────────────────────────────────────────────

/**
 * Invites one teacher to this administrator's school.
 *
 * The address is the identity. Everything that follows — the code, the account,
 * the school link — is bound to what the administrator typed here, never to
 * anything the recipient supplies later.
 */
exports.inviteTeacher = onCall(async (request) => {
  const { uid, db, schoolId, actor } = await requireSchoolAdmin(request);
  await checkRateLimit(uid, "invite_teacher", 30);

  const name = sanitizeText(request.data?.name, 120);
  const email = normEmail(request.data?.email);

  if (name.length < 2) {
    throw new HttpsError("invalid-argument", "Enter the teacher's name.");
  }
  if (!isValidEmail(email)) {
    throw new HttpsError("invalid-argument", "Enter a valid school email address.");
  }

  // Someone already teaching somewhere cannot be pulled in by a second school.
  // A part-time teacher does not handle a section, so they never facilitate a
  // trip, which is why one school per account is the whole model.
  const existing = await db.collection("users").where("email", "==", email).limit(1).get();
  if (!existing.empty) {
    const doc = existing.docs[0];
    const theirSchool = doc.get("schoolId");
    if (theirSchool && theirSchool !== schoolId) {
      throw new HttpsError(
        "already-exists",
        "That address already belongs to a teacher at another school. They must be removed there first."
      );
    }
    if (theirSchool === schoolId) {
      throw new HttpsError("already-exists", "That teacher is already on your staff list.");
    }
  }

  // One live invitation per address per school; re-inviting replaces the old.
  const prior = await db
    .collection("staffInvites")
    .where("schoolId", "==", schoolId)
    .where("email", "==", email)
    .get();
  const batch = db.batch();
  prior.docs.forEach((d) => {
    if (d.get("status") === INVITE_STATUS.unused) {
      batch.update(d.ref, {
        status: INVITE_STATUS.revoked,
        revokedAt: admin.firestore.FieldValue.serverTimestamp(),
        revokedReason: "Replaced by a new invitation",
      });
    }
  });
  await batch.commit();

  const schoolSnap = await db.collection("schools").doc(schoolId).get();
  const schoolName = schoolSnap.get("name") || "Your school";
  const raw = generateInviteCode(schoolName);
  const expiresAt = admin.firestore.Timestamp.fromMillis(
    Date.now() + INVITE_TTL_DAYS * 24 * 60 * 60 * 1000
  );

  const ref = db.collection("staffInvites").doc();
  await ref.set({
    schoolId,
    schoolName,
    name,
    email,
    role: "teacher",
    codeHash: hashCode(raw),
    status: INVITE_STATUS.unused,
    attempts: 0,
    expiresAt,
    invitedBy: uid,
    invitedByEmail: actor.email || null,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  try {
    const mail = inviteEmail({ teacherName: name, schoolName, code: raw });
    await sendMail({
      to: email,
      subject: "FieldTrip360 — you have been invited as a trip facilitator",
      text: mail.text,
      html: mail.html,
      transporter: createMailTransport(),
    });
  } catch (e) {
    // The invitation exists either way; say so plainly rather than leaving the
    // administrator to wonder whether to send it again.
    console.error("staff invite email failed", e?.message || e);
    await ref.update({ emailError: String(e?.message || e).slice(0, 200) });
    throw new HttpsError(
      "internal",
      "The invitation was created but the email could not be sent. Check the mail settings and resend."
    );
  }

  await db.collection("activity_logs").add({
    action: "Teacher Invited",
    details: `${name} <${email}>`,
    adminEmail: actor.email || uid,
    schoolId,
    timestamp: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { inviteId: ref.id, email };
});

/** Withdraws an invitation that has not been redeemed. */
exports.revokeTeacherInvite = onCall(async (request) => {
  const { uid, db, schoolId, actor } = await requireSchoolAdmin(request);
  const inviteId = sanitizeText(request.data?.inviteId, 64);
  if (!inviteId) throw new HttpsError("invalid-argument", "inviteId is required.");

  const ref = db.collection("staffInvites").doc(inviteId);
  const snap = await ref.get();
  if (!snap.exists || snap.get("schoolId") !== schoolId) {
    throw new HttpsError("not-found", "That invitation was not found.");
  }
  if (snap.get("status") === INVITE_STATUS.used) {
    throw new HttpsError("failed-precondition", "That invitation has already been redeemed.");
  }

  await ref.update({
    status: INVITE_STATUS.revoked,
    revokedAt: admin.firestore.FieldValue.serverTimestamp(),
    revokedBy: uid,
  });

  await db.collection("activity_logs").add({
    action: "Teacher Invitation Revoked",
    details: `${snap.get("name")} <${snap.get("email")}>`,
    adminEmail: actor.email || uid,
    schoolId,
    timestamp: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { ok: true };
});

// ─── Redeem ───────────────────────────────────────────────────────────────────

/**
 * Turns an invitation into an account. Called by someone with no account yet,
 * so it is the one staff endpoint that does not require sign-in.
 *
 * The email is taken from the invitation, never from the request: a caller who
 * holds a valid code still cannot choose which address the account is created
 * for. Everything else the caller sends — the password — is theirs to set.
 */
exports.redeemTeacherInvite = onCall(async (request) => {
  const db = admin.firestore();

  // No uid to throttle against, so throttle the caller's address instead.
  const ip =
    request.rawRequest?.headers?.["x-forwarded-for"]?.split(",")[0]?.trim() ||
    request.rawRequest?.ip ||
    "unknown";
  await checkRateLimit(`ip:${ip}`, "redeem_invite", 10);

  const raw = sanitizeText(request.data?.code, 60);
  const password = typeof request.data?.password === "string" ? request.data.password : "";

  if (normalizeCode(raw).length < 6) {
    throw new HttpsError("invalid-argument", "That does not look like an invitation code.");
  }
  if (password.length < MIN_PASSWORD) {
    throw new HttpsError(
      "invalid-argument",
      `Choose a password of at least ${MIN_PASSWORD} characters.`
    );
  }

  const match = await db
    .collection("staffInvites")
    .where("codeHash", "==", hashCode(raw))
    .limit(1)
    .get();

  // Deliberately uniform wording — a distinct "no such code" reply would let a
  // caller tell a wrong code from a used one.
  if (match.empty) {
    throw new HttpsError("not-found", "That invitation code is not valid.");
  }

  const ref = match.docs[0].ref;
  const invite = match.docs[0].data();

  if (invite.status === INVITE_STATUS.used) {
    throw new HttpsError("failed-precondition", "That invitation has already been used.");
  }
  if (invite.status === INVITE_STATUS.revoked) {
    throw new HttpsError("failed-precondition", "That invitation was withdrawn by the school.");
  }
  if (invite.expiresAt && invite.expiresAt.toMillis() < Date.now()) {
    await ref.update({ status: INVITE_STATUS.expired });
    throw new HttpsError(
      "failed-precondition",
      "That invitation has expired. Ask the school to send a new one."
    );
  }

  const email = normEmail(invite.email);
  const schoolId = invite.schoolId;

  // Create or adopt the Auth account. An address that already exists belongs to
  // someone who left a school and is being taken on again — reuse it, so their
  // history stays attached to one person.
  let userRecord;
  try {
    userRecord = await admin.auth().getUserByEmail(email);
    await admin.auth().updateUser(userRecord.uid, { password, emailVerified: true, disabled: false });
  } catch (e) {
    if (e.code !== "auth/user-not-found") throw e;
    userRecord = await admin.auth().createUser({
      email,
      password,
      displayName: invite.name || undefined,
      emailVerified: true,
    });
  }

  const userRef = db.collection("users").doc(userRecord.uid);
  const existing = await userRef.get();
  await userRef.set(
    {
      uid: userRecord.uid,
      name: invite.name || email.split("@")[0],
      email,
      role: "teacher",
      schoolId,
      status: "approved",
      accountStatus: "active",
      joinedSchoolAt: admin.firestore.FieldValue.serverTimestamp(),
      ...(existing.exists ? {} : { createdAt: admin.firestore.FieldValue.serverTimestamp() }),
    },
    { merge: true }
  );

  await ref.update({
    status: INVITE_STATUS.used,
    usedAt: admin.firestore.FieldValue.serverTimestamp(),
    usedBy: userRecord.uid,
  });

  await db.collection("activity_logs").add({
    action: "Teacher Joined",
    details: `${invite.name} <${email}>`,
    adminEmail: email,
    schoolId,
    timestamp: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { email, name: invite.name || null, schoolName: invite.schoolName || null };
});

// ─── Remove ───────────────────────────────────────────────────────────────────

/**
 * Ends a teacher's link to this school, keeping the account.
 *
 * Deleting would be the obvious move and the wrong one: every attendance entry
 * records the facilitator's uid and every bus records their id, so a deleted
 * teacher turns last term's reports into rows nobody can account for. The
 * account survives, the access does not, and their next school can invite the
 * same address.
 */
exports.removeTeacherFromSchool = onCall(async (request) => {
  const { uid, db, schoolId, actor } = await requireSchoolAdmin(request);
  const teacherUid = sanitizeText(request.data?.uid, 128);
  const reason = sanitizeText(request.data?.reason, 300);
  if (!teacherUid) throw new HttpsError("invalid-argument", "uid is required.");

  const ref = db.collection("users").doc(teacherUid);
  const snap = await ref.get();
  if (!snap.exists || snap.get("role") !== "teacher" || snap.get("schoolId") !== schoolId) {
    throw new HttpsError("not-found", "That teacher is not on your staff list.");
  }

  // A bus mid-route cannot lose its facilitator: nobody would be able to scan,
  // override, or answer an emergency on it.
  const running = await db.collection("trips").where("schoolId", "==", schoolId).get();
  const blocking = running.docs.filter((d) => {
    if (d.get("status") !== "in_progress") return false;
    return (d.get("buses") || []).some(
      (b) => b?.mainTeacher?.id === teacherUid || b?.coTeacher?.id === teacherUid
    );
  });
  if (blocking.length) {
    const names = blocking.map((d) => d.get("title") || "a trip").join(", ");
    throw new HttpsError(
      "failed-precondition",
      `${snap.get("name") || "That teacher"} is facilitating a trip that is running right now (${names}). ` +
        "Complete it, or assign someone else to their bus, before removing them."
    );
  }

  await ref.update({
    schoolId: admin.firestore.FieldValue.delete(),
    leftSchoolId: schoolId,
    leftSchoolAt: admin.firestore.FieldValue.serverTimestamp(),
    leftSchoolBy: uid,
    leftSchoolReason: reason || null,
  });

  // Their sessions still carry the old claim-free token, but every school-scoped
  // rule reads schoolId from the document, so access ends on the next read.
  await db.collection("activity_logs").add({
    action: "Teacher Removed From School",
    details: `${snap.get("name") || teacherUid}${reason ? ` — ${reason}` : ""}`,
    adminEmail: actor.email || uid,
    schoolId,
    timestamp: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { ok: true, name: snap.get("name") || null };
});

module.exports.INVITE_STATUS = INVITE_STATUS;
module.exports.INVITE_TTL_DAYS = INVITE_TTL_DAYS;
module.exports.normalizeCode = normalizeCode;
module.exports.schoolCodePrefix = schoolCodePrefix;
