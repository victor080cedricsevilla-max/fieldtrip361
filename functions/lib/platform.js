/**
 * Platform-level roles, authorization and audit logging.
 *
 * The super admin operates the *platform*: subscribing schools, their admin
 * accounts, announcements and support. It is deliberately NOT a super-set of a
 * school admin — nothing here grants access to students, parents, teachers,
 * rosters, locations, attendance, medical forms or trip chats. The Firestore
 * and Storage rules enforce the same boundary independently of this file.
 */
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

const {
  sanitizeText,
  normEmail,
  isValidEmail,
  checkRateLimit,
  superAdminSetupToken,
} = require("./common");

const ROLES = {
  superAdmin: "super_admin",
  admin: "admin",
  teacher: "teacher",
  student: "student",
  parent: "parent",
  applicant: "applicant",
};

const ACCOUNT_STATUS = {
  active: "active",
  disabled: "disabled",
};

/** Actions recorded in platformAuditLogs. Keep these stable — the UI filters on them. */
const AUDIT = {
  superAdminBootstrapped: "super_admin.bootstrapped",
  superAdminGranted: "super_admin.granted",
  superAdminRevoked: "super_admin.revoked",
  adminDisabled: "school_admin.disabled",
  adminEnabled: "school_admin.enabled",
  adminCredentialsResent: "school_admin.credentials_resent",
  applicationSubmitted: "application.submitted",
  applicationResubmitted: "application.resubmitted",
  applicationApproved: "application.approved",
  applicationRejected: "application.rejected",
  applicationDocsRequested: "application.documents_requested",
  applicationOverride: "application.override",
  schoolProvisioned: "school.provisioned",
  announcementPublished: "announcement.published",
  announcementUnpublished: "announcement.unpublished",
  ticketStatusChanged: "support.status_changed",
  ticketReplied: "support.replied",
  passwordChanged: "account.password_changed",
};

// ─── Authorization ────────────────────────────────────────────────────────────

/**
 * Asserts the caller is signed in and their account has not been disabled.
 *
 * Disabling also calls Auth `disableUser` + `revokeRefreshTokens`, which stops
 * token refresh — but an already-issued ID token stays valid until it expires,
 * so every privileged callable re-checks the stored status here.
 */
async function requireActiveUser(request) {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
  const db = admin.firestore();
  const uid = request.auth.uid;
  const snap = await db.collection("users").doc(uid).get();
  if (!snap.exists) throw new HttpsError("not-found", "User record not found.");
  if (snap.get("accountStatus") === ACCOUNT_STATUS.disabled) {
    throw new HttpsError(
      "permission-denied",
      "This account has been disabled. Contact FieldTrip360 support."
    );
  }
  return { uid, db, snap, data: snap.data() || {} };
}

/**
 * Asserts the caller is a super admin.
 *
 * Authority comes from the `superAdmin` custom claim, never from the user
 * document: a claim cannot be written by any client, whereas a user document
 * is one mis-scoped rule away from being self-assigned.
 */
async function requireSuperAdmin(request) {
  const ctx = await requireActiveUser(request);
  if (request.auth.token.superAdmin !== true) {
    throw new HttpsError("permission-denied", "Super-admin access is required.");
  }
  return ctx;
}

/**
 * Asserts the caller finished first-time setup. A provisioned admin holds a
 * temporary password until they replace it; until then every school operation
 * is refused server-side, not merely hidden in the UI.
 */
function assertPasswordChanged(data) {
  if (data.mustChangePassword === true) {
    throw new HttpsError(
      "failed-precondition",
      "Change your temporary password before continuing."
    );
  }
}

// ─── Audit log ────────────────────────────────────────────────────────────────

/**
 * Appends an immutable platform-management entry. Clients can never write here
 * (rules deny all writes); super admins read it from the dashboard.
 */
async function writeAuditLog(db, {
  action,
  actorUid,
  actorEmail,
  actorRole,
  targetType,
  targetId,
  reason,
  metadata,
}) {
  try {
    await db.collection("platformAuditLogs").add({
      action,
      actorUid: actorUid || null,
      actorEmail: actorEmail || null,
      actorRole: actorRole || null,
      targetType: targetType || null,
      targetId: targetId || null,
      reason: reason ? sanitizeText(reason, 1000) : null,
      metadata: metadata || {},
      at: admin.firestore.FieldValue.serverTimestamp(),
    });
  } catch (e) {
    // An audit write must never take down the action it describes, but it must
    // be visible in logs when it fails.
    console.error("platform audit log write failed:", action, e?.message || e);
  }
}

// ─── Platform configuration ───────────────────────────────────────────────────

const CONFIG_DEFAULTS = {
  billing: {
    // Server-controlled. The client never chooses this: a request that asked
    // for "bypass" would otherwise be a request to skip paying.
    paymentBypassEnabled: true,
    currency: "PHP",
  },
  review: {
    bankingDayTarget: 7,
    calendarDayLimit: 14,
    timezone: "Asia/Manila",
  },
  // Philippine regular + special non-working days when banks are closed.
  // Seeded for 2026; a super admin keeps this current from Settings.
  bankingCalendar: {
    holidays: [
      "2026-01-01", "2026-04-02", "2026-04-03", "2026-04-09", "2026-05-01",
      "2026-06-12", "2026-08-31", "2026-11-30", "2026-12-25", "2026-12-30",
      "2026-12-31",
    ],
  },
};

/** Reads a platformConfig document, merged over its built-in defaults. */
async function getPlatformConfig(db, docId) {
  const defaults = CONFIG_DEFAULTS[docId] || {};
  try {
    const snap = await db.collection("platformConfig").doc(docId).get();
    return snap.exists ? { ...defaults, ...(snap.data() || {}) } : { ...defaults };
  } catch (e) {
    console.error("getPlatformConfig failed:", docId, e?.message || e);
    return { ...defaults };
  }
}

// ─── Callables ────────────────────────────────────────────────────────────────

/**
 * Creates the first super admin.
 *
 * Trusted setup, not registration: it requires the SUPERADMIN_SETUP_TOKEN
 * parameter (unset by default, which disables the endpoint) and refuses to run
 * once any super admin exists. There is no client-side path to this role.
 */
exports.bootstrapSuperAdmin = onRequest(
  { cors: false, region: "us-central1" },
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).json({ error: "Method not allowed." });
      return;
    }
    const configured = superAdminSetupToken.value();
    if (!configured) {
      res.status(404).json({ error: "Not found." });
      return;
    }
    const provided = String(req.get("x-setup-token") || "");
    // Constant-time compare so the token cannot be guessed byte by byte.
    const ok =
      provided.length === configured.length &&
      require("crypto").timingSafeEqual(Buffer.from(provided), Buffer.from(configured));
    if (!ok) {
      res.status(403).json({ error: "Forbidden." });
      return;
    }

    const db = admin.firestore();
    const existing = await db
      .collection("users")
      .where("role", "==", ROLES.superAdmin)
      .limit(1)
      .get();
    if (!existing.empty) {
      res.status(409).json({
        error: "A super admin already exists. Use grantSuperAdmin from that account.",
      });
      return;
    }

    const body = req.body || {};
    const email = normEmail(body.email);
    const name = sanitizeText(body.name, 120) || "Platform Administrator";
    const password = typeof body.password === "string" ? body.password : "";
    if (!isValidEmail(email)) {
      res.status(400).json({ error: "A valid email is required." });
      return;
    }
    if (password.length < 12) {
      res.status(400).json({ error: "Password must be at least 12 characters." });
      return;
    }

    let userRecord;
    try {
      userRecord = await admin.auth().getUserByEmail(email);
      await admin.auth().updateUser(userRecord.uid, { password, emailVerified: true });
    } catch (e) {
      if (e.code !== "auth/user-not-found") throw e;
      userRecord = await admin.auth().createUser({
        email,
        password,
        displayName: name,
        emailVerified: true,
      });
    }

    await admin.auth().setCustomUserClaims(userRecord.uid, { superAdmin: true });
    await db.collection("users").doc(userRecord.uid).set(
      {
        uid: userRecord.uid,
        name,
        email,
        role: ROLES.superAdmin,
        status: "approved",
        accountStatus: ACCOUNT_STATUS.active,
        mustChangePassword: false,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    await writeAuditLog(db, {
      action: AUDIT.superAdminBootstrapped,
      actorUid: userRecord.uid,
      actorEmail: email,
      actorRole: ROLES.superAdmin,
      targetType: "user",
      targetId: userRecord.uid,
      reason: "Initial platform setup",
    });

    res.json({ uid: userRecord.uid, email });
  }
);

/** Grants super-admin rights to an existing account. Super admins only. */
exports.grantSuperAdmin = onCall(async (request) => {
  const { uid: actorUid, db, data: actor } = await requireSuperAdmin(request);
  await checkRateLimit(actorUid, "grant_super_admin", 5);

  const email = normEmail(request.data && request.data.email);
  if (!isValidEmail(email)) {
    throw new HttpsError("invalid-argument", "A valid email is required.");
  }

  let target;
  try {
    target = await admin.auth().getUserByEmail(email);
  } catch (e) {
    throw new HttpsError("not-found", "No account exists with that email.");
  }

  await admin.auth().setCustomUserClaims(target.uid, { superAdmin: true });
  await db.collection("users").doc(target.uid).set(
    {
      uid: target.uid,
      email,
      role: ROLES.superAdmin,
      status: "approved",
      accountStatus: ACCOUNT_STATUS.active,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true }
  );

  await writeAuditLog(db, {
    action: AUDIT.superAdminGranted,
    actorUid,
    actorEmail: actor.email,
    actorRole: ROLES.superAdmin,
    targetType: "user",
    targetId: target.uid,
    reason: sanitizeText(request.data && request.data.reason, 500),
    metadata: { email },
  });

  return { uid: target.uid };
});

/**
 * Disables or re-enables a school-admin account.
 *
 * Disabling revokes the account's sessions immediately and blocks Auth sign-in.
 * It deliberately does NOT touch the school's students, parents or teachers —
 * suspending an administrator must not strand an entire school's users.
 */
exports.setSchoolAdminAccountStatus = onCall(async (request) => {
  const { uid: actorUid, db, data: actor } = await requireSuperAdmin(request);
  await checkRateLimit(actorUid, "set_admin_status", 30);

  const targetUid = sanitizeText(request.data && request.data.uid, 128);
  const disable = request.data && request.data.disable === true;
  const reason = sanitizeText(request.data && request.data.reason, 1000);

  if (!targetUid) throw new HttpsError("invalid-argument", "uid is required.");
  if (!reason || reason.length < 5) {
    throw new HttpsError("invalid-argument", "A reason is required and is recorded in the audit log.");
  }
  if (targetUid === actorUid) {
    throw new HttpsError("failed-precondition", "You cannot change your own account status.");
  }

  const userRef = db.collection("users").doc(targetUid);
  const snap = await userRef.get();
  if (!snap.exists) throw new HttpsError("not-found", "That account does not exist.");
  if (snap.get("role") !== ROLES.admin) {
    // The super admin manages school administrators only. Students, parents and
    // teachers are the school's business, not the platform operator's.
    throw new HttpsError("permission-denied", "Only school-admin accounts can be managed here.");
  }

  const now = admin.firestore.FieldValue.serverTimestamp();
  await userRef.update(
    disable
      ? {
          accountStatus: ACCOUNT_STATUS.disabled,
          disabledReason: reason,
          disabledBy: actorUid,
          disabledAt: now,
          activeSession: admin.firestore.FieldValue.delete(),
        }
      : {
          accountStatus: ACCOUNT_STATUS.active,
          reenabledReason: reason,
          reenabledBy: actorUid,
          reenabledAt: now,
          disabledReason: admin.firestore.FieldValue.delete(),
        }
  );

  await admin.auth().updateUser(targetUid, { disabled: disable });
  if (disable) {
    // Stops refresh-token exchange; the current ID token also fails Firestore
    // rules because they check accountStatus.
    await admin.auth().revokeRefreshTokens(targetUid);
  }

  await writeAuditLog(db, {
    action: disable ? AUDIT.adminDisabled : AUDIT.adminEnabled,
    actorUid,
    actorEmail: actor.email,
    actorRole: ROLES.superAdmin,
    targetType: "user",
    targetId: targetUid,
    reason,
    metadata: { schoolId: snap.get("schoolId") || null, email: snap.get("email") || null },
  });

  return { uid: targetUid, accountStatus: disable ? ACCOUNT_STATUS.disabled : ACCOUNT_STATUS.active };
});

/**
 * Replaces the caller's password and clears the first-login requirement.
 *
 * Done server-side so `mustChangePassword` can only be cleared by an actual
 * password change. Requires a recent sign-in, the same guarantee Firebase asks
 * for before a client-side `updatePassword`.
 */
exports.changeMyPassword = onCall(async (request) => {
  const { uid, db, data } = await requireActiveUser(request);
  await checkRateLimit(uid, "change_password", 10);

  const newPassword = typeof request.data?.newPassword === "string" ? request.data.newPassword : "";
  if (newPassword.length < 8) {
    throw new HttpsError("invalid-argument", "Use at least 8 characters.");
  }
  if (!/[A-Za-z]/.test(newPassword) || !/[0-9]/.test(newPassword)) {
    throw new HttpsError("invalid-argument", "Use at least one letter and one number.");
  }

  // Recent sign-in required: auth_time is seconds since epoch.
  const authTime = Number(request.auth.token.auth_time || 0) * 1000;
  if (!authTime || Date.now() - authTime > 15 * 60 * 1000) {
    throw new HttpsError("failed-precondition", "Please sign in again before changing your password.");
  }

  await admin.auth().updateUser(uid, { password: newPassword });
  await db.collection("users").doc(uid).update({
    mustChangePassword: false,
    passwordChangedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  await writeAuditLog(db, {
    action: AUDIT.passwordChanged,
    actorUid: uid,
    actorEmail: data.email,
    actorRole: data.role,
    targetType: "user",
    targetId: uid,
  });

  return { ok: true };
});

module.exports.ROLES = ROLES;
module.exports.ACCOUNT_STATUS = ACCOUNT_STATUS;
module.exports.AUDIT = AUDIT;
module.exports.requireActiveUser = requireActiveUser;
module.exports.requireSuperAdmin = requireSuperAdmin;
module.exports.assertPasswordChanged = assertPasswordChanged;
module.exports.writeAuditLog = writeAuditLog;
module.exports.getPlatformConfig = getPlatformConfig;
module.exports.CONFIG_DEFAULTS = CONFIG_DEFAULTS;
