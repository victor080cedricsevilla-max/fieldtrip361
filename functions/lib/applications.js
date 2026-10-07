/**
 * School subscription applications: intake, review and provisioning.
 *
 * The rule the whole module is built around: an application never becomes an
 * account on its own. A super admin decides, their reason is recorded, and only
 * then is a school created. Payment bypass is a server-side setting that skips
 * *collecting money* — it never skips the review.
 */
const { onCall, onRequest, HttpsError } = require("firebase-functions/v2/https");
const admin = require("firebase-admin");

const {
  sanitizeText,
  normEmail,
  isValidEmail,
  checkRateLimit,
  generateTempPassword,
} = require("./common");
const { TIERS, monthlyPriceFor } = require("./pricing");
const { reviewDeadlines } = require("./banking_days");
const {
  ROLES,
  ACCOUNT_STATUS,
  AUDIT,
  requireSuperAdmin,
  writeAuditLog,
  getPlatformConfig,
} = require("./platform");
const {
  EMAIL_TYPE,
  acknowledgementEmail,
  documentsRequestedEmail,
  rejectedEmail,
  approvalEmail,
  paymentRequestEmail,
  sendApplicationEmail,
  statusUrl,
} = require("./application_email");
const paymongo = require("./paymongo");

const STATUS = {
  draft: "draft",
  submitted: "submitted",
  underReview: "under_review",
  needsMoreDocuments: "needs_more_documents",
  // Approved by a reviewer; the school is created once PayMongo confirms payment.
  awaitingPayment: "awaiting_payment",
  approved: "approved",
  rejected: "rejected",
};

/**
 * How an approval activates the school: "paymongo" collects the first payment
 * through a PayMongo test-mode checkout before provisioning; "bypass" provisions
 * at once. Bypass applies when no PayMongo test key is configured, when an
 * operator has switched it on in platformConfig/billing, and to plans with no
 * listed price (Enterprise is quoted by hand).
 */
async function paymentModeFor(db, plan) {
  if (!paymongo.isConfigured()) return "bypass";
  const billing = await getPlatformConfig(db, "billing");
  if (billing.paymentBypassEnabled === true) return "bypass";
  if (paymongo.chargeFor(plan).centavos < paymongo.MIN_CENTAVOS) return "bypass";
  return "paymongo";
}

const DOC = {
  secRegistration: "sec_registration",
  depedPermit: "deped_permit",
  chedRecognition: "ched_recognition",
  tesdaRegistration: "tesda_registration",
  governmentEstablishment: "government_establishment",
  authorizationLetter: "authorization_letter",
  articlesOfIncorporation: "articles_of_incorporation",
  schoolIdentifier: "school_identifier",
  addressProof: "address_proof",
  other: "other",
};

const DOC_LABELS = {
  [DOC.secRegistration]: "SEC Certificate of Registration / Incorporation",
  [DOC.depedPermit]: "DepEd permit or recognition",
  [DOC.chedRecognition]: "CHED authority / recognition",
  [DOC.tesdaRegistration]: "TESDA program registration certificate",
  [DOC.governmentEstablishment]: "Charter, ordinance or establishment document",
  [DOC.authorizationLetter]: "Authorization letter for the representative",
  [DOC.articlesOfIncorporation]: "Articles of Incorporation",
  [DOC.schoolIdentifier]: "Official school ID / directory reference",
  [DOC.addressProof]: "Proof of school address",
  [DOC.other]: "Supporting document",
};

/**
 * What each kind of institution must provide.
 *
 * A public school has no SEC registration, so requiring one of every applicant
 * would be a wall rather than a check. Each type therefore has its own required
 * set and its own alternative path, and none of them asks for anything about a
 * student: no rosters, no student numbers, no attendance, no medical records.
 */
const INSTITUTION_REQUIREMENTS = {
  private_incorporated: {
    label: "Private school (incorporated)",
    required: [DOC.secRegistration, DOC.depedPermit, DOC.authorizationLetter],
    optional: [DOC.articlesOfIncorporation, DOC.schoolIdentifier, DOC.addressProof],
  },
  public_school: {
    label: "Public school (DepEd)",
    required: [DOC.governmentEstablishment, DOC.authorizationLetter],
    optional: [DOC.schoolIdentifier, DOC.addressProof, DOC.depedPermit],
  },
  state_university: {
    label: "State university or local college",
    required: [DOC.governmentEstablishment, DOC.authorizationLetter],
    optional: [DOC.chedRecognition, DOC.schoolIdentifier, DOC.addressProof],
  },
  tvet: {
    label: "TVET institution",
    required: [DOC.tesdaRegistration, DOC.authorizationLetter],
    optional: [DOC.secRegistration, DOC.schoolIdentifier, DOC.addressProof],
  },
  other: {
    label: "Other institution",
    // Nothing fixed: the reviewer asks for what fits, rather than the applicant
    // guessing which of the other four boxes they belong in.
    required: [DOC.authorizationLetter],
    optional: Object.values(DOC),
  },
};

const MAX_DOCUMENTS = 12;

// ─── Helpers ──────────────────────────────────────────────────────────────────

/** Sequential, human-quotable reference: FT-2026-0001. */
async function nextCounter(db, key, prefix) {
  const ref = db.collection("platformConfig").doc("counters");
  const year = new Date().getUTCFullYear();
  const field = `${key}_${year}`;
  const n = await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    const current = (snap.exists ? snap.get(field) : 0) || 0;
    const next = current + 1;
    tx.set(ref, { [field]: next }, { merge: true });
    return next;
  });
  return `${prefix}-${year}-${String(n).padStart(4, "0")}`;
}

/**
 * The applicant's session.
 *
 * Applying does not create a login. The browser signs in anonymously, which
 * gives a uid that Storage rules can scope an upload to — so a file can only be
 * attached to the application that uploaded it — without asking a registrar to
 * invent a password for an account they will never use again. The account they
 * eventually receive is provisioned on approval, with its own credentials.
 *
 * Someone already signed in as a school user is refused: applying from a
 * teacher's browser would otherwise attach the application to their account.
 */
async function requireApplicantSession(request) {
  if (!request.auth) {
    throw new HttpsError(
      "unauthenticated",
      "Your session expired. Reload the page and try again."
    );
  }
  const db = admin.firestore();
  const uid = request.auth.uid;

  const snap = await db.collection("users").doc(uid).get();
  const role = snap.exists ? snap.get("role") : null;
  if (role && role !== ROLES.applicant) {
    throw new HttpsError(
      "failed-precondition",
      "You are signed in to a FieldTrip360 account. Sign out before applying for a new school."
    );
  }

  return { uid, db };
}

/** A key that lets the applicant reopen their application from an emailed link. */
function generateAccessKey() {
  return require("crypto").randomBytes(24).toString("base64url");
}

/** Loads an application the caller owns, or throws. */
async function loadOwnApplication(db, uid, applicationId) {
  const ref = db.collection("schoolApplications").doc(applicationId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Application not found.");
  if (snap.get("applicantUid") !== uid) {
    throw new HttpsError("permission-denied", "That application belongs to someone else.");
  }
  return { ref, snap, data: snap.data() };
}

function requirementsFor(institutionType) {
  return INSTITUTION_REQUIREMENTS[institutionType] || INSTITUTION_REQUIREMENTS.other;
}

function planFromTier(tierKey, billingCycle) {
  const tier = TIERS[tierKey];
  if (!tier) throw new HttpsError("invalid-argument", "Choose a valid subscription plan.");
  const cycle = billingCycle === "annual" ? "annual" : "monthly";
  return {
    tier: tierKey,
    tierLabel: tier.label,
    capacity: tier.capacity,
    billingCycle: cycle,
    priceMonthly: monthlyPriceFor(tier, cycle),
  };
}

function sanitizeApplicationInput(body) {
  const schoolName = sanitizeText(body.schoolName, 160);
  const legalName = sanitizeText(body.legalName, 200) || schoolName;
  const institutionType = sanitizeText(body.institutionType, 40);
  const address = sanitizeText(body.address, 300);
  const rep = body.representative || {};

  if (!schoolName || schoolName.length < 2) {
    throw new HttpsError("invalid-argument", "Enter the school's name.");
  }
  if (!INSTITUTION_REQUIREMENTS[institutionType]) {
    throw new HttpsError("invalid-argument", "Choose the kind of institution this is.");
  }
  const repName = sanitizeText(rep.name, 120);
  if (!repName) {
    throw new HttpsError("invalid-argument", "Enter the authorized representative's name.");
  }
  const repEmail = normEmail(rep.email);
  if (repEmail && !isValidEmail(repEmail)) {
    throw new HttpsError("invalid-argument", "The representative's email is not valid.");
  }

  return {
    schoolName,
    legalName,
    institutionType,
    address,
    representative: {
      name: repName,
      position: sanitizeText(rep.position, 120),
      email: repEmail,
      phone: sanitizeText(rep.phone, 40),
    },
  };
}

// ─── Applicant-facing callables ───────────────────────────────────────────────

/**
 * Creates or updates the caller's draft application.
 *
 * The applicant's own account is created here with the `applicant` role, which
 * carries no access to any school's data. Nothing they send can set a role,
 * a status or a school id — those are written only by this function.
 */
exports.saveSchoolApplication = onCall(async (request) => {
  const { uid, db } = await requireApplicantSession(request);
  await checkRateLimit(uid, "save_application", 20);

  const input = sanitizeApplicationInput(request.data || {});
  const plan = planFromTier(
    sanitizeText(request.data?.tier, 30).toLowerCase(),
    request.data?.billingCycle
  );
  const requirements = requirementsFor(input.institutionType);

  // Where every message about this application goes, including the decision
  // and, if approved, the sign-in details.
  const email = normEmail(request.data?.email);
  if (!isValidEmail(email)) {
    throw new HttpsError(
      "invalid-argument",
      "Enter the email address we should send the decision to."
    );
  }

  const existing = await db
    .collection("schoolApplications")
    .where("applicantUid", "==", uid)
    .where("status", "in", [STATUS.draft, STATUS.needsMoreDocuments])
    .limit(1)
    .get();

  const now = admin.firestore.FieldValue.serverTimestamp();
  const payload = {
    ...input,
    email,
    plan,
    requiredDocTypes: requirements.required,
    optionalDocTypes: requirements.optional,
    updatedAt: now,
  };

  if (!existing.empty) {
    const ref = existing.docs[0].ref;
    await ref.update(payload);
    return { applicationId: ref.id, reference: existing.docs[0].get("reference") };
  }

  // Refuse a second live application from the same account: two open
  // applications for one school is a review problem, not a feature.
  const live = await db
    .collection("schoolApplications")
    .where("applicantUid", "==", uid)
    .where("status", "in", [STATUS.submitted, STATUS.underReview, STATUS.approved])
    .limit(1)
    .get();
  if (!live.empty) {
    throw new HttpsError(
      "failed-precondition",
      "You already have an application in progress. Open it to check its status."
    );
  }

  const reference = await nextCounter(db, "application", "FT");
  const ref = db.collection("schoolApplications").doc();
  await ref.set({
    ...payload,
    reference,
    applicantUid: uid,
    // Lets them reopen the application from the link in our email, on any
    // device — an anonymous session only lives in the browser that started it.
    accessKey: generateAccessKey(),
    status: STATUS.draft,
    submittedAt: null,
    documentsCompletedAt: null,
    reviewTargetAt: null,
    processingDeadlineAt: null,
    decision: null,
    reviewerNotes: null,
    provisioning: { status: "none" },
    emails: [],
    createdAt: now,
  });

  return { applicationId: ref.id, reference };
});

/**
 * Records a file the applicant has already uploaded to their own Storage
 * folder. Storage rules restrict that folder to the owner, and this function
 * re-checks the path so a crafted request cannot register someone else's file.
 */
exports.attachApplicationDocument = onCall(async (request) => {
  const { uid, db } = await requireApplicantSession(request);
  await checkRateLimit(uid, "attach_document", 40);

  const applicationId = sanitizeText(request.data?.applicationId, 64);
  const type = sanitizeText(request.data?.type, 60);
  const storagePath = sanitizeText(request.data?.storagePath, 500);
  const fileName = sanitizeText(request.data?.fileName, 200);
  const contentType = sanitizeText(request.data?.contentType, 100);
  const size = Number(request.data?.size || 0);

  if (!applicationId || !storagePath) {
    throw new HttpsError("invalid-argument", "applicationId and storagePath are required.");
  }
  if (!DOC_LABELS[type]) {
    throw new HttpsError("invalid-argument", "Choose what kind of document this is.");
  }
  const expectedPrefix = `school_applications/${applicationId}/${uid}/`;
  if (!storagePath.startsWith(expectedPrefix)) {
    throw new HttpsError("permission-denied", "That file does not belong to this application.");
  }
  const allowed = ["application/pdf", "image/jpeg", "image/jpg", "image/png"];
  if (!allowed.includes(contentType)) {
    throw new HttpsError("invalid-argument", "Upload a PDF, JPG or PNG file.");
  }
  if (size > 10 * 1024 * 1024) {
    throw new HttpsError("invalid-argument", "Each file must be 10 MB or smaller.");
  }

  const { ref, data } = await loadOwnApplication(db, uid, applicationId);
  if (![STATUS.draft, STATUS.needsMoreDocuments].includes(data.status)) {
    throw new HttpsError(
      "failed-precondition",
      "This application is being reviewed. You cannot change its documents right now."
    );
  }

  // Confirm the object really exists and matches what was declared, so the
  // reviewer never opens a document entry that points at nothing.
  let metadata;
  try {
    [metadata] = await admin.storage().bucket().file(storagePath).getMetadata();
  } catch (e) {
    throw new HttpsError("not-found", "That upload could not be found. Try uploading again.");
  }

  const docsRef = ref.collection("documents");
  const existing = await docsRef.where("type", "==", type).get();
  const version = existing.size + 1;
  if (existing.size + 1 > MAX_DOCUMENTS) {
    throw new HttpsError("resource-exhausted", "Too many versions of this document.");
  }
  const total = await docsRef.count().get();
  if (total.data().count >= MAX_DOCUMENTS * 2) {
    throw new HttpsError("resource-exhausted", "This application has too many files attached.");
  }

  // Supersede the previous version of the same document type rather than
  // deleting it: the reviewer needs to see what changed between submissions.
  const batch = db.batch();
  existing.docs.forEach((d) => batch.update(d.ref, { superseded: true }));

  const docRef = docsRef.doc();
  batch.set(docRef, {
    type,
    storagePath,
    fileName: fileName || metadata.name?.split("/").pop() || "document",
    contentType,
    size: Number(metadata.size || size),
    version,
    superseded: false,
    uploadedBy: uid,
    uploadedAt: admin.firestore.FieldValue.serverTimestamp(),
    ocr: { status: "pending" },
    reviewHints: [],
  });
  batch.update(ref, { updatedAt: admin.firestore.FieldValue.serverTimestamp() });
  await batch.commit();

  return { documentId: docRef.id, version };
});

exports.removeApplicationDocument = onCall(async (request) => {
  const { uid, db } = await requireApplicantSession(request);
  const applicationId = sanitizeText(request.data?.applicationId, 64);
  const documentId = sanitizeText(request.data?.documentId, 64);
  if (!applicationId || !documentId) {
    throw new HttpsError("invalid-argument", "applicationId and documentId are required.");
  }

  const { ref, data } = await loadOwnApplication(db, uid, applicationId);
  if (![STATUS.draft, STATUS.needsMoreDocuments].includes(data.status)) {
    throw new HttpsError("failed-precondition", "This application can no longer be edited.");
  }

  const docRef = ref.collection("documents").doc(documentId);
  const docSnap = await docRef.get();
  if (!docSnap.exists) return { ok: true };

  const storagePath = docSnap.get("storagePath");
  await docRef.delete();
  if (storagePath) {
    // Best effort: an orphaned object costs pennies, a failed delete must not
    // block the applicant from fixing their submission.
    admin.storage().bucket().file(storagePath).delete().catch(() => {});
  }
  return { ok: true };
});

/**
 * Submits, or resubmits after documents were requested.
 *
 * The original submission time is written once and never moved. The review
 * clock, on the other hand, is re-counted from the day the documents became
 * complete — which is what the applicant was told would happen.
 */
exports.submitSchoolApplication = onCall(async (request) => {
  const { uid, db } = await requireApplicantSession(request);
  await checkRateLimit(uid, "submit_application", 10);

  const applicationId = sanitizeText(request.data?.applicationId, 64);
  if (!applicationId) throw new HttpsError("invalid-argument", "applicationId is required.");

  const { ref, data } = await loadOwnApplication(db, uid, applicationId);
  if (![STATUS.draft, STATUS.needsMoreDocuments].includes(data.status)) {
    throw new HttpsError(
      "failed-precondition",
      "This application has already been submitted."
    );
  }

  const docsSnap = await ref.collection("documents").where("superseded", "==", false).get();
  const presentTypes = new Set(docsSnap.docs.map((d) => d.get("type")));
  const required = data.requestedDocTypes?.length
    ? data.requestedDocTypes
    : data.requiredDocTypes || [];
  const missing = required.filter((t) => !presentTypes.has(t));
  if (missing.length) {
    throw new HttpsError(
      "failed-precondition",
      `Still missing: ${missing.map((m) => DOC_LABELS[m] || m).join(", ")}.`
    );
  }

  // A file that is not a document — a photograph of a pet, a person, a
  // screenshot — is refused here rather than left in the queue for a reviewer to
  // discover. The upload is kept, marked, and the school is told exactly which
  // one and what it actually shows, so the fix is to replace that one file.
  const current = docsSnap.docs.map((d) => ({ id: d.id, ...d.data() }));
  const refused = current.filter((d) => d.autoRejected === true);
  if (refused.length) {
    const list = refused
      .map((d) => `${DOC_LABELS[d.type] || d.type}: ${d.autoRejectedReason || "not a document"}`)
      .join(" ");
    throw new HttpsError(
      "failed-precondition",
      `These uploads are not accepted — replace them and submit again. ${list}`
    );
  }

  // The check runs a few seconds after an upload. Submitting inside that window
  // would slip a file past it, so wait for a verdict — but only for a file that
  // is genuinely still being checked. One whose check never ran is left to a
  // human reviewer, as before, rather than blocking the school indefinitely.
  const STILL_CHECKING_MS = 3 * 60 * 1000;
  const checking = current.filter((d) => {
    if (d.ocr?.status !== "pending") return false;
    const at = d.uploadedAt?.toMillis?.();
    return at && Date.now() - at < STILL_CHECKING_MS;
  });
  if (checking.length) {
    throw new HttpsError(
      "failed-precondition",
      "We are still checking " +
        checking.map((d) => DOC_LABELS[d.type] || d.type).join(", ") +
        ". Give it a few seconds and submit again."
    );
  }

  const config = {
    ...(await getPlatformConfig(db, "review")),
    ...(await getPlatformConfig(db, "bankingCalendar")),
  };
  const completedAt = new Date();
  const { reviewTargetAt, processingDeadlineAt } = reviewDeadlines(completedAt, config);

  const isResubmission = data.status === STATUS.needsMoreDocuments;
  const now = admin.firestore.FieldValue.serverTimestamp();

  await ref.update({
    status: STATUS.submitted,
    // Written once: a resubmission is still the same application.
    submittedAt: data.submittedAt || now,
    documentsCompletedAt: admin.firestore.Timestamp.fromDate(completedAt),
    reviewTargetAt: admin.firestore.Timestamp.fromDate(reviewTargetAt),
    processingDeadlineAt: admin.firestore.Timestamp.fromDate(processingDeadlineAt),
    requestedDocTypes: admin.firestore.FieldValue.delete(),
    updatedAt: now,
  });

  await ref.collection("events").add({
    type: isResubmission ? "resubmitted" : "submitted",
    actorUid: uid,
    actorEmail: data.email,
    at: now,
    reason: null,
  });

  const fresh = (await ref.get()).data();
  const email = await sendApplicationEmail(db, {
    applicationRef: ref,
    to: data.email,
    type: EMAIL_TYPE.acknowledgement,
    message: acknowledgementEmail({ application: fresh, applicationId }),
  });

  await writeAuditLog(db, {
    action: isResubmission ? AUDIT.applicationResubmitted : AUDIT.applicationSubmitted,
    actorUid: uid,
    actorEmail: data.email,
    actorRole: ROLES.applicant,
    targetType: "application",
    targetId: applicationId,
    metadata: { reference: data.reference, schoolName: data.schoolName },
  });

  return {
    ok: true,
    emailSent: email.sent,
    emailError: email.error || null,
    reviewTargetAt: reviewTargetAt.toISOString(),
    processingDeadlineAt: processingDeadlineAt.toISOString(),
  };
});

/**
 * A short-lived link to one uploaded document.
 *
 * The URL is minted on demand and never stored: a Firebase download URL is a
 * bearer link, so writing one into Firestore would make every verification
 * document readable by anyone who ever saw the record. This hands one out only
 * to the reviewer or the applicant who uploaded it, and only for as long as it
 * takes to read the page.
 */
exports.getApplicationDocumentUrl = onCall(async (request) => {
  if (!request.auth) throw new HttpsError("unauthenticated", "Sign in required.");
  const db = admin.firestore();
  const uid = request.auth.uid;
  await checkRateLimit(uid, "application_doc_url", 120);

  const applicationId = sanitizeText(request.data?.applicationId, 64);
  const documentId = sanitizeText(request.data?.documentId, 64);
  if (!applicationId || !documentId) {
    throw new HttpsError("invalid-argument", "applicationId and documentId are required.");
  }

  const appRef = db.collection("schoolApplications").doc(applicationId);
  const appSnap = await appRef.get();
  if (!appSnap.exists) throw new HttpsError("not-found", "Application not found.");

  const isSuperAdmin = request.auth.token.superAdmin === true;
  if (!isSuperAdmin && appSnap.get("applicantUid") !== uid) {
    throw new HttpsError("permission-denied", "That application belongs to someone else.");
  }

  const docSnap = await appRef.collection("documents").doc(documentId).get();
  if (!docSnap.exists) throw new HttpsError("not-found", "That document is not attached.");
  const storagePath = docSnap.get("storagePath");
  if (!storagePath) throw new HttpsError("not-found", "That document has no file.");

  const file = admin.storage().bucket().file(storagePath);
  const expires = Date.now() + 15 * 60 * 1000;

  try {
    const [url] = await file.getSignedUrl({ action: "read", expires, version: "v4" });
    return { url, expiresAt: expires, contentType: docSnap.get("contentType") || null };
  } catch (e) {
    // Signing needs the runtime service account to be able to sign for itself,
    // which is not granted on every project. Fall back to the bucket's own
    // download token, which carries no expiry of its own and so is the second
    // choice rather than the first.
    console.warn("signed URL unavailable, using download token:", e?.message || e);
    try {
      // A download token never expires on its own, so issuing one and leaving
      // it in place would create exactly the durable public link this feature
      // is supposed to avoid. Rotating it on every request keeps at most one
      // live link per document: the moment the reviewer asks again, every URL
      // handed out earlier stops working.
      const token = require("crypto").randomUUID();
      await file.setMetadata({ metadata: { firebaseStorageDownloadTokens: token } });
      const bucket = admin.storage().bucket().name;
      const url =
        `https://firebasestorage.googleapis.com/v0/b/${bucket}/o/` +
        `${encodeURIComponent(storagePath)}?alt=media&token=${token}`;
      return { url, expiresAt: null, contentType: docSnap.get("contentType") || null };
    } catch (inner) {
      throw new HttpsError(
        "internal",
        `The file could not be opened (${String(inner?.message || inner).slice(0, 160)}).`
      );
    }
  }
});

/**
 * Reopens an application from the link in our email.
 *
 * An anonymous session lives in one browser, so a registrar who opens the
 * "we need more documents" email on their phone would otherwise be locked out
 * of their own application. The key in that link re-binds the application to
 * whatever session is asking, which is safe because the key is unguessable and
 * only ever travels to the address on the application.
 */
exports.openApplicationWithKey = onCall(async (request) => {
  const { uid, db } = await requireApplicantSession(request);
  await checkRateLimit(uid, "open_application", 20);

  const applicationId = sanitizeText(request.data?.applicationId, 64);
  const accessKey = sanitizeText(request.data?.accessKey, 80);
  if (!applicationId || !accessKey) {
    throw new HttpsError("invalid-argument", "This link is incomplete.");
  }

  const ref = db.collection("schoolApplications").doc(applicationId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "That application no longer exists.");

  const stored = snap.get("accessKey");
  const ok =
    typeof stored === "string" &&
    stored.length === accessKey.length &&
    require("crypto").timingSafeEqual(Buffer.from(stored), Buffer.from(accessKey));
  if (!ok) {
    throw new HttpsError("permission-denied", "This link is no longer valid.");
  }

  if (snap.get("applicantUid") !== uid) {
    await ref.update({ applicantUid: uid, reboundAt: admin.firestore.FieldValue.serverTimestamp() });
  }

  return { applicationId, status: snap.get("status"), reference: snap.get("reference") };
});

// ─── Reviewer-facing callables ────────────────────────────────────────────────

/** Marks an application as being looked at, so two reviewers do not collide. */
exports.claimApplicationForReview = onCall(async (request) => {
  const { uid, db, data: actor } = await requireSuperAdmin(request);
  const applicationId = sanitizeText(request.data?.applicationId, 64);
  if (!applicationId) throw new HttpsError("invalid-argument", "applicationId is required.");

  const ref = db.collection("schoolApplications").doc(applicationId);
  await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw new HttpsError("not-found", "Application not found.");
    if (snap.get("status") !== STATUS.submitted) return; // already claimed or decided
    tx.update(ref, {
      status: STATUS.underReview,
      reviewClaimedBy: uid,
      reviewClaimedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
  });

  await ref.collection("events").add({
    type: "claimed",
    actorUid: uid,
    actorEmail: actor.email,
    at: admin.firestore.FieldValue.serverTimestamp(),
  });

  return { ok: true };
});

/**
 * Creates the school and its administrator account.
 *
 * Safe to call twice with the same application: everything keys off ids already
 * written to the application document, so a retry after a timeout resumes
 * rather than duplicating. Nothing here runs unless a decision to approve has
 * already been committed.
 *
 * `payment` is the confirmed PayMongo payment when the school paid before
 * activation, or absent when payment was bypassed.
 */
async function provisionSchool(db, { applicationRef, application, actorUid, payment }) {
  const existing = application.provisioning || {};
  const plan = application.plan || {};
  const now = admin.firestore.FieldValue.serverTimestamp();
  const paid = !!payment;

  // 1. School document.
  let schoolId = existing.schoolId || null;
  if (!schoolId) {
    const schoolRef = db.collection("schools").doc();
    await schoolRef.set({
      name: application.schoolName,
      legalName: application.legalName || application.schoolName,
      adminEmail: application.email,
      applicationId: applicationRef.id,
      institutionType: application.institutionType,
      tier: plan.tier,
      tierLabel: plan.tierLabel,
      capacity: plan.capacity,
      billingCycle: plan.billingCycle,
      priceMonthly: plan.priceMonthly,
      studentCount: 0,
      status: "active",
      // Set here, by the server; the client has no way to ask for either.
      // "paid_test_mode" means PayMongo's test environment confirmed the
      // payment — no real money moved.
      paymentStatus: paid ? "paid_test_mode" : "test_mode",
      activationMode: paid ? "paymongo_test" : "payment_bypass",
      ...(paid ? { paymongoPaymentId: payment.paymentId, paidThrough: "paymongo" } : {}),
      activatedAt: now,
      currentPeriodStart: now,
      createdAt: now,
    });
    schoolId = schoolRef.id;
    await applicationRef.update({ "provisioning.schoolId": schoolId });
  }

  // 2. Administrator account. The applicant's own account is upgraded when the
  //    addresses match, so the school does not end up with two logins for one
  //    person; otherwise a fresh account is created.
  const adminEmail = normEmail(application.adminEmail || application.email);
  const tempPassword = generateTempPassword();
  let adminUid = existing.adminUid || null;

  if (!adminUid) {
    try {
      const found = await admin.auth().getUserByEmail(adminEmail);
      adminUid = found.uid;
    } catch (e) {
      if (e.code !== "auth/user-not-found") throw e;
    }
  }

  if (adminUid) {
    await admin.auth().updateUser(adminUid, {
      password: tempPassword,
      emailVerified: true,
      disabled: false,
    });
  } else {
    const created = await admin.auth().createUser({
      email: adminEmail,
      password: tempPassword,
      displayName: `${application.schoolName} Admin`,
      emailVerified: true,
    });
    adminUid = created.uid;
  }

  await db.collection("users").doc(adminUid).set(
    {
      uid: adminUid,
      email: adminEmail,
      name: application.representative?.name || `${application.schoolName} Admin`,
      role: ROLES.admin,
      status: "approved",
      accountStatus: ACCOUNT_STATUS.active,
      schoolId,
      applicationId: applicationRef.id,
      mustChangePassword: true,
      credentialsIssuedAt: now,
      updatedAt: now,
    },
    { merge: true }
  );
  // Any session held by the applicant account ends here: it is a different
  // account now, with a different password and different access.
  await admin.auth().revokeRefreshTokens(adminUid);
  await applicationRef.update({ "provisioning.adminUid": adminUid });

  // 3. Receipt — a PayMongo test-mode payment, or an activation record that
  //    says on its face that no payment was taken.
  let receiptId = existing.receiptId || null;
  let receiptNumber = existing.receiptNumber || null;
  const receiptAmount = paid ? payment.amount : plan.priceMonthly;
  if (!receiptId) {
    receiptNumber = await nextCounter(db, "receipt", "RCPT");
    const receiptRef = db.collection("receipts").doc();
    await receiptRef.set({
      number: receiptNumber,
      schoolId,
      applicationId: applicationRef.id,
      tier: plan.tier,
      tierLabel: plan.tierLabel,
      capacity: plan.capacity,
      billingCycle: plan.billingCycle,
      amount: receiptAmount,
      currency: "PHP",
      ...(paid
        ? {
            paymentStatus: "paid_test_mode",
            amountCollected: payment.amount,
            monthsCovered: payment.months,
            provider: "paymongo",
            paymongoPaymentId: payment.paymentId,
            paymongoCheckoutSessionId: payment.checkoutSessionId,
            paymentMethod: payment.method || null,
            note: "Paid through PayMongo's test environment — no real money moved.",
          }
        : {
            paymentStatus: "bypassed_test_mode",
            amountCollected: 0,
            note: "Payment bypassed — test mode. No payment was processed or is due.",
          }),
      issuedAt: now,
      issuedBy: actorUid,
    });
    receiptId = receiptRef.id;
    await applicationRef.update({
      "provisioning.receiptId": receiptId,
      "provisioning.receiptNumber": receiptNumber,
    });
  }

  return {
    schoolId,
    adminUid,
    adminEmail,
    tempPassword,
    receipt: {
      number: receiptNumber,
      amount: receiptAmount,
      billingCycle: plan.billingCycle,
      paymentStatus: paid ? "paid_test_mode" : "bypassed_test_mode",
      paymentReference: paid ? payment.paymentId : null,
    },
  };
}

// ─── PayMongo (test mode) ─────────────────────────────────────────────────────

/** Where PayMongo sends the payer back: the applicant's own status page. */
function paymentReturnUrl(applicationId, application, outcome) {
  return statusUrl(applicationId, application.accessKey).replace(
    "#/apply",
    `&payment=${outcome}#/apply`
  );
}

/**
 * After an approval that collects payment: creates the PayMongo checkout once
 * (a replay reuses it) and emails the link. The school is not created here —
 * that waits for PayMongo to confirm the payment.
 */
async function requestApplicationPayment(db, { ref, applicationId, uid, actor, reason }) {
  const application = (await ref.get()).data();
  let payment = application.payment || {};
  const now = admin.firestore.FieldValue.serverTimestamp();

  if (!payment.checkoutSessionId || !payment.checkoutUrl) {
    let session;
    try {
      session = await paymongo.createCheckoutSession({
        applicationId,
        application,
        successUrl: paymentReturnUrl(applicationId, application, "success"),
        cancelUrl: paymentReturnUrl(applicationId, application, "cancelled"),
      });
    } catch (e) {
      await ref.update({
        "payment.status": "link_failed",
        "payment.error": String(e?.message || e).slice(0, 500),
      });
      throw new HttpsError(
        "internal",
        `Approved, but the PayMongo payment link could not be created: ${e?.message || e}. Retry to resume.`
      );
    }
    payment = {
      ...payment,
      provider: "paymongo",
      mode: "test",
      status: "pending",
      checkoutSessionId: session.id,
      checkoutUrl: session.url,
      amount: session.amount,
      amountCentavos: session.centavos,
      months: session.months,
      currency: "PHP",
      error: null,
    };
    await ref.update({ payment: { ...payment, createdAt: now }, updatedAt: now });

    await writeAuditLog(db, {
      action: AUDIT.applicationApproved,
      actorUid: uid,
      actorEmail: actor.email,
      actorRole: ROLES.superAdmin,
      targetType: "application",
      targetId: applicationId,
      reason,
      metadata: { awaitingPayment: true, checkoutSessionId: session.id, amount: session.amount },
    });
  }

  const email = await sendApplicationEmail(db, {
    applicationRef: ref,
    to: application.email,
    type: EMAIL_TYPE.paymentRequested,
    message: paymentRequestEmail({
      application,
      applicationId,
      checkoutUrl: payment.checkoutUrl,
      amount: payment.amount,
      months: payment.months,
    }),
  });

  return {
    ok: true,
    awaitingPayment: true,
    checkoutUrl: payment.checkoutUrl,
    amount: payment.amount,
    emailSent: email.sent,
    emailError: email.error || null,
  };
}

/**
 * Provisions an application whose PayMongo checkout has been paid.
 *
 * Called by the webhook and by "Check payment". Whether the session is paid is
 * read back from PayMongo with the secret key — never taken from the browser or
 * the webhook body — and a transaction lets only one caller provision, so a
 * webhook and a button press arriving together create one school, one
 * password and one email.
 */
async function finalizePaidApplication(db, applicationId, { source }) {
  const ref = db.collection("schoolApplications").doc(applicationId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Application not found.");
  const app = snap.data();
  const pay = app.payment || {};

  if (app.status === STATUS.approved && app.provisioning?.status === "done") {
    return { state: "active" };
  }
  if (!pay.checkoutSessionId) return { state: "no_payment" };
  if (![STATUS.awaitingPayment, STATUS.approved].includes(app.status)) {
    return { state: app.status };
  }

  const session = await paymongo.retrieveCheckoutSession(pay.checkoutSessionId);
  const sessionApp = session?.attributes?.metadata?.applicationId;
  if (sessionApp && sessionApp !== applicationId) {
    throw new Error("The checkout session belongs to a different application.");
  }
  const paid = paymongo.paidPaymentFrom(session);
  if (!paid) return { state: "unpaid" };
  if (paid.livemode) throw new Error("A live-mode payment reached a test-mode build.");
  const expected = Number(pay.amountCentavos || paymongo.chargeFor(app.plan).centavos);
  if (paid.centavos < expected) {
    throw new Error(`PayMongo reports ${paid.centavos} centavos paid; ${expected} were due.`);
  }

  const STALE_MS = 5 * 60 * 1000;
  const claim = await db.runTransaction(async (tx) => {
    const d = (await tx.get(ref)).data();
    const prov = d.provisioning || {};
    if (prov.status === "done") return "done";
    const claimedAt = prov.claimedAt?.toMillis?.() || 0;
    if (prov.status === "in_progress" && Date.now() - claimedAt < STALE_MS) return "busy";
    tx.update(ref, {
      status: STATUS.approved,
      "payment.status": "paid",
      "payment.paymentId": paid.paymentId,
      "payment.method": paid.method,
      "payment.amountPaid": paid.centavos / 100,
      "payment.paidAt": paid.paidAtSeconds
        ? admin.firestore.Timestamp.fromMillis(paid.paidAtSeconds * 1000)
        : admin.firestore.Timestamp.now(),
      "payment.confirmedBy": source,
      "provisioning.status": "in_progress",
      "provisioning.claimedAt": admin.firestore.Timestamp.now(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    return d.payment?.status === "paid" ? "resumed" : "claimed";
  });
  if (claim === "done") return { state: "active" };
  if (claim === "busy") return { state: "activating" };

  const actorUid = app.decision?.by || null;
  const actorEmail = app.decision?.byEmail || null;
  if (claim === "claimed") {
    await ref.collection("events").add({
      type: "payment_received",
      actorUid,
      actorEmail,
      reason: `PayMongo test payment ${paid.paymentId} (${paid.method || "unknown method"}), PHP ${paid.centavos / 100}.`,
      at: admin.firestore.FieldValue.serverTimestamp(),
    });
  }

  const fresh = (await ref.get()).data();
  let provisioned;
  try {
    provisioned = await provisionSchool(db, {
      applicationRef: ref,
      application: fresh,
      actorUid,
      payment: {
        paymentId: paid.paymentId,
        amount: paid.centavos / 100,
        months: pay.months || paymongo.chargeFor(app.plan).months,
        method: paid.method,
        checkoutSessionId: pay.checkoutSessionId,
      },
    });
    await ref.update({
      "provisioning.status": "done",
      "provisioning.completedAt": admin.firestore.FieldValue.serverTimestamp(),
    });
  } catch (e) {
    await ref.update({
      "provisioning.status": "failed",
      "provisioning.error": String(e?.message || e).slice(0, 500),
    });
    throw e;
  }

  const email = await sendApplicationEmail(db, {
    applicationRef: ref,
    to: provisioned.adminEmail,
    type: EMAIL_TYPE.credentials,
    message: approvalEmail({
      application: fresh,
      adminEmail: provisioned.adminEmail,
      tempPassword: provisioned.tempPassword,
      receipt: provisioned.receipt,
    }),
  });

  await writeAuditLog(db, {
    action: AUDIT.schoolProvisioned,
    actorUid,
    actorEmail,
    actorRole: ROLES.superAdmin,
    targetType: "school",
    targetId: provisioned.schoolId,
    metadata: {
      applicationId,
      receipt: provisioned.receipt.number,
      paymongoPaymentId: paid.paymentId,
      confirmedBy: source,
      emailSent: email.sent,
    },
  });

  return { state: "active", schoolId: provisioned.schoolId, emailSent: email.sent };
}

/**
 * "Check payment" — asks PayMongo whether the checkout was paid and, if so,
 * activates the school. For the applicant on their status page and for super
 * admins; it works without the webhook, so a missed webhook never strands a
 * paid school.
 */
exports.confirmApplicationPayment = onCall({ timeoutSeconds: 120 }, async (request) => {
  if (!request.auth) {
    throw new HttpsError("unauthenticated", "Your session expired. Reload the page and try again.");
  }
  const db = admin.firestore();
  const uid = request.auth.uid;
  const applicationId = sanitizeText(request.data?.applicationId, 64);
  if (!applicationId) throw new HttpsError("invalid-argument", "applicationId is required.");

  const snap = await db.collection("schoolApplications").doc(applicationId).get();
  if (!snap.exists) throw new HttpsError("not-found", "Application not found.");
  if (snap.get("applicantUid") !== uid) await requireSuperAdmin(request);
  await checkRateLimit(uid, "confirm_payment", 20);

  try {
    return await finalizePaidApplication(db, applicationId, { source: "check" });
  } catch (e) {
    if (e instanceof HttpsError) throw e;
    console.error("confirmApplicationPayment failed:", applicationId, e?.message || e);
    throw new HttpsError("internal", `The payment could not be confirmed: ${e?.message || e}`);
  }
});

/**
 * PayMongo webhook (checkout_session.payment.paid).
 *
 * Accepted only with a valid test-mode signature. The event says *which*
 * application to look at; whether it was paid is then read from PayMongo
 * itself, so a forged or replayed body cannot activate anything.
 */
exports.paymongoWebhook = onRequest(
  { cors: false, region: "us-central1", timeoutSeconds: 120 },
  async (req, res) => {
    if (req.method !== "POST") {
      res.status(405).send("Method not allowed");
      return;
    }
    if (!paymongo.verifyWebhookSignature(req.rawBody, req.get("Paymongo-Signature"))) {
      res.status(401).send("Invalid signature");
      return;
    }

    const event = req.body?.data;
    const type = event?.attributes?.type;
    if (type !== "checkout_session.payment.paid") {
      res.status(200).json({ received: true, ignored: type || null });
      return;
    }
    const session = event.attributes.data;
    const applicationId = sanitizeText(session?.attributes?.metadata?.applicationId, 64);
    if (!applicationId) {
      res.status(200).json({ received: true, ignored: "no applicationId" });
      return;
    }

    const db = admin.firestore();
    const eventRef = db.collection("paymentEvents").doc(sanitizeText(String(event.id || ""), 80) || db.collection("paymentEvents").doc().id);
    await eventRef.set(
      {
        provider: "paymongo",
        type,
        applicationId,
        checkoutSessionId: session?.id || null,
        receivedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true }
    );

    try {
      const result = await finalizePaidApplication(db, applicationId, { source: "webhook" });
      await eventRef.set({ result: result.state, processedAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
      res.status(200).json({ received: true, state: result.state });
    } catch (e) {
      console.error("paymongoWebhook failed:", applicationId, e?.message || e);
      await eventRef.set({ error: String(e?.message || e).slice(0, 500) }, { merge: true });
      // A 5xx makes PayMongo retry later.
      res.status(500).json({ error: "processing failed" });
    }
  }
);

/**
 * Approve, reject, or ask for more documents.
 *
 * Concurrency and retries are handled by moving the status inside a
 * transaction, keyed on the caller's idempotency key: a second click replays
 * the same key and returns, a different reviewer arriving late is told the
 * application was already decided.
 */
exports.decideSchoolApplication = onCall({ timeoutSeconds: 120 }, async (request) => {
  const { uid, db, data: actor } = await requireSuperAdmin(request);
  await checkRateLimit(uid, "decide_application", 30);

  const applicationId = sanitizeText(request.data?.applicationId, 64);
  const decision = sanitizeText(request.data?.decision, 30);
  const reason = sanitizeText(request.data?.reason, 2000);
  const reviewerNote = sanitizeText(request.data?.reviewerNote, 2000);
  const idempotencyKey = sanitizeText(request.data?.idempotencyKey, 120);
  const overrideWarnings = request.data?.overrideWarnings === true;
  const overrideReason = sanitizeText(request.data?.overrideReason, 1000);
  const requestedDocTypes = Array.isArray(request.data?.requestedDocTypes)
    ? request.data.requestedDocTypes
        .map((t) => sanitizeText(t, 60))
        .filter((t) => DOC_LABELS[t])
    : [];

  if (!applicationId) throw new HttpsError("invalid-argument", "applicationId is required.");
  if (!["approve", "reject", "request_documents"].includes(decision)) {
    throw new HttpsError("invalid-argument", "Unknown decision.");
  }
  if (reason.length < 10) {
    throw new HttpsError(
      "invalid-argument",
      "Give a reason of at least 10 characters — it is recorded and, for a rejection, sent to the applicant."
    );
  }
  if (!idempotencyKey) {
    throw new HttpsError("invalid-argument", "idempotencyKey is required.");
  }
  if (decision === "request_documents" && requestedDocTypes.length === 0) {
    throw new HttpsError("invalid-argument", "Name at least one document to request.");
  }
  if (overrideWarnings && overrideReason.length < 10) {
    throw new HttpsError(
      "invalid-argument",
      "Overriding a review warning needs its own reason."
    );
  }

  const ref = db.collection("schoolApplications").doc(applicationId);
  const now = admin.firestore.FieldValue.serverTimestamp();

  // Whether approval collects a PayMongo payment first. Decided on the server
  // from configuration, never from the request.
  const pre = await ref.get();
  if (!pre.exists) throw new HttpsError("not-found", "Application not found.");
  const mode = decision === "approve" ? await paymentModeFor(db, pre.get("plan") || {}) : null;

  // Claim the decision. A replay of the same key is allowed through so a
  // half-finished approval can be resumed.
  const { application, replay } = await db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw new HttpsError("not-found", "Application not found.");
    const data = snap.data();
    const prior = data.decision || {};

    if (prior.idempotencyKey && prior.idempotencyKey === idempotencyKey) {
      return { application: data, replay: true };
    }
    if ([STATUS.approved, STATUS.rejected, STATUS.awaitingPayment].includes(data.status)) {
      throw new HttpsError(
        "failed-precondition",
        "This application has already been decided."
      );
    }
    if (![STATUS.submitted, STATUS.underReview].includes(data.status)) {
      throw new HttpsError(
        "failed-precondition",
        "This application is with the applicant and cannot be decided yet."
      );
    }

    const nextStatus = decision === "approve"
      ? (mode === "paymongo" ? STATUS.awaitingPayment : STATUS.approved)
      : decision === "reject"
        ? STATUS.rejected
        : STATUS.needsMoreDocuments;

    tx.update(ref, {
      status: nextStatus,
      decision: {
        outcome: decision,
        by: uid,
        byEmail: actor.email || null,
        at: admin.firestore.Timestamp.now(),
        reason,
        idempotencyKey,
        overrodeWarnings: overrideWarnings,
        overrideReason: overrideWarnings ? overrideReason : null,
      },
      reviewerNotes: reviewerNote || data.reviewerNotes || null,
      requestedDocTypes: decision === "request_documents" ? requestedDocTypes : null,
      updatedAt: now,
      ...(decision === "approve"
        ? mode === "paymongo"
          ? { "payment.provider": "paymongo", "payment.mode": "test", "payment.status": "creating" }
          : { "provisioning.status": "in_progress" }
        : {}),
    });
    return { application: { ...data, status: nextStatus }, replay: false };
  });

  if (!replay) {
    await ref.collection("events").add({
      type: decision === "approve"
        ? "approved"
        : decision === "reject"
          ? "rejected"
          : "documents_requested",
      actorUid: uid,
      actorEmail: actor.email,
      reason,
      requestedDocTypes,
      at: now,
    });
    if (overrideWarnings) {
      await ref.collection("events").add({
        type: "override",
        actorUid: uid,
        actorEmail: actor.email,
        reason: overrideReason,
        at: now,
      });
      await writeAuditLog(db, {
        action: AUDIT.applicationOverride,
        actorUid: uid,
        actorEmail: actor.email,
        actorRole: ROLES.superAdmin,
        targetType: "application",
        targetId: applicationId,
        reason: overrideReason,
      });
    }
  }

  // ── Approve with payment: send the PayMongo link; provisioning waits. ──────
  if (decision === "approve" && application.status === STATUS.awaitingPayment) {
    return requestApplicationPayment(db, { ref, applicationId, uid, actor, reason });
  }

  // ── Approve: provision, then email the credentials. ────────────────────────
  if (decision === "approve") {
    let provisioned;
    try {
      const fresh = (await ref.get()).data();
      provisioned = await provisionSchool(db, {
        applicationRef: ref,
        application: fresh,
        actorUid: uid,
      });
      await ref.update({ "provisioning.status": "done", "provisioning.completedAt": now });
    } catch (e) {
      await ref.update({
        "provisioning.status": "failed",
        "provisioning.error": String(e?.message || e).slice(0, 500),
      });
      throw new HttpsError(
        "internal",
        `The school could not be provisioned: ${e?.message || e}. The decision is recorded; retry to resume.`
      );
    }

    const email = await sendApplicationEmail(db, {
      applicationRef: ref,
      to: provisioned.adminEmail,
      type: EMAIL_TYPE.credentials,
      message: approvalEmail({
        application,
        adminEmail: provisioned.adminEmail,
        tempPassword: provisioned.tempPassword,
        receipt: provisioned.receipt,
      }),
    });

    await writeAuditLog(db, {
      action: AUDIT.applicationApproved,
      actorUid: uid,
      actorEmail: actor.email,
      actorRole: ROLES.superAdmin,
      targetType: "application",
      targetId: applicationId,
      reason,
      metadata: {
        schoolId: provisioned.schoolId,
        adminUid: provisioned.adminUid,
        emailSent: email.sent,
      },
    });
    await writeAuditLog(db, {
      action: AUDIT.schoolProvisioned,
      actorUid: uid,
      actorEmail: actor.email,
      actorRole: ROLES.superAdmin,
      targetType: "school",
      targetId: provisioned.schoolId,
      metadata: { applicationId, receipt: provisioned.receipt.number },
    });

    return {
      ok: true,
      schoolId: provisioned.schoolId,
      emailSent: email.sent,
      emailError: email.error || null,
    };
  }

  // ── Reject / request documents: email the applicant. ───────────────────────
  const message = decision === "reject"
    ? rejectedEmail({ application, reason })
    : documentsRequestedEmail({
        application,
        applicationId,
        reason,
        requestedDocTypes,
        docLabels: DOC_LABELS,
      });

  const email = await sendApplicationEmail(db, {
    applicationRef: ref,
    to: application.email,
    type: decision === "reject" ? EMAIL_TYPE.rejected : EMAIL_TYPE.documentsRequested,
    message,
  });

  await writeAuditLog(db, {
    action: decision === "reject" ? AUDIT.applicationRejected : AUDIT.applicationDocsRequested,
    actorUid: uid,
    actorEmail: actor.email,
    actorRole: ROLES.superAdmin,
    targetType: "application",
    targetId: applicationId,
    reason,
    metadata: { requestedDocTypes, emailSent: email.sent },
  });

  return { ok: true, emailSent: email.sent, emailError: email.error || null };
});

/** Re-sends an application email that failed to go out. */
exports.retryApplicationEmail = onCall(async (request) => {
  const { uid, db, data: actor } = await requireSuperAdmin(request);
  const applicationId = sanitizeText(request.data?.applicationId, 64);
  const emailType = sanitizeText(request.data?.emailType, 40);
  if (!applicationId) throw new HttpsError("invalid-argument", "applicationId is required.");

  const ref = db.collection("schoolApplications").doc(applicationId);
  const snap = await ref.get();
  if (!snap.exists) throw new HttpsError("not-found", "Application not found.");
  const application = snap.data();

  let message;
  let to = application.email;
  switch (emailType) {
    case EMAIL_TYPE.acknowledgement:
      message = acknowledgementEmail({ application, applicationId });
      break;
    case EMAIL_TYPE.rejected:
      message = rejectedEmail({
        application,
        reason: application.decision?.reason || "No reason recorded.",
      });
      break;
    case EMAIL_TYPE.documentsRequested:
      message = documentsRequestedEmail({
        application,
        applicationId,
        reason: application.decision?.reason || "",
        requestedDocTypes: application.requestedDocTypes || [],
        docLabels: DOC_LABELS,
      });
      break;
    case EMAIL_TYPE.paymentRequested: {
      const payment = application.payment || {};
      if (application.status !== STATUS.awaitingPayment || !payment.checkoutUrl) {
        throw new HttpsError("failed-precondition", "This application is not waiting for payment.");
      }
      message = paymentRequestEmail({
        application,
        applicationId,
        checkoutUrl: payment.checkoutUrl,
        amount: payment.amount,
        months: payment.months,
      });
      break;
    }
    case EMAIL_TYPE.credentials:
      throw new HttpsError(
        "failed-precondition",
        "Credentials cannot be re-sent from here — use Resend credentials, which issues a new password."
      );
    default:
      throw new HttpsError("invalid-argument", "Unknown email type.");
  }

  const result = await sendApplicationEmail(db, {
    applicationRef: ref,
    to,
    type: emailType,
    message,
  });

  await writeAuditLog(db, {
    action: "application.email_retried",
    actorUid: uid,
    actorEmail: actor.email,
    actorRole: ROLES.superAdmin,
    targetType: "application",
    targetId: applicationId,
    metadata: { emailType, sent: result.sent },
  });

  return { emailSent: result.sent, emailError: result.error || null };
});

/**
 * Issues a fresh temporary password for a school's administrator and emails it.
 * The previous temporary password stops working the moment this runs.
 */
exports.resendAdminCredentials = onCall(async (request) => {
  const { uid, db, data: actor } = await requireSuperAdmin(request);
  await checkRateLimit(uid, "resend_credentials", 10);

  const schoolId = sanitizeText(request.data?.schoolId, 64);
  const reason = sanitizeText(request.data?.reason, 1000);
  if (!schoolId) throw new HttpsError("invalid-argument", "schoolId is required.");
  if (reason.length < 5) throw new HttpsError("invalid-argument", "A reason is required.");

  const schoolSnap = await db.collection("schools").doc(schoolId).get();
  if (!schoolSnap.exists) throw new HttpsError("not-found", "School not found.");
  const school = schoolSnap.data();

  const adminsSnap = await db
    .collection("users")
    .where("schoolId", "==", schoolId)
    .where("role", "==", ROLES.admin)
    .limit(1)
    .get();
  if (adminsSnap.empty) {
    throw new HttpsError("not-found", "This school has no administrator account.");
  }
  const adminDoc = adminsSnap.docs[0];
  const adminEmail = normEmail(adminDoc.get("email"));
  const tempPassword = generateTempPassword();

  await admin.auth().updateUser(adminDoc.id, { password: tempPassword, disabled: false });
  await admin.auth().revokeRefreshTokens(adminDoc.id);
  await adminDoc.ref.update({
    mustChangePassword: true,
    accountStatus: ACCOUNT_STATUS.active,
    credentialsIssuedAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  const applicationId = school.applicationId;
  const applicationRef = applicationId
    ? db.collection("schoolApplications").doc(applicationId)
    : db.collection("schools").doc(schoolId); // fall back to recording on the school

  const receiptSnap = await db
    .collection("receipts")
    .where("schoolId", "==", schoolId)
    .limit(1)
    .get();
  const receipt = receiptSnap.empty
    ? { number: "—", amount: school.priceMonthly, billingCycle: school.billingCycle }
    : {
        number: receiptSnap.docs[0].get("number"),
        amount: receiptSnap.docs[0].get("amount"),
        billingCycle: receiptSnap.docs[0].get("billingCycle"),
        paymentStatus: receiptSnap.docs[0].get("paymentStatus") || null,
        paymentReference: receiptSnap.docs[0].get("paymongoPaymentId") || null,
      };

  const email = await sendApplicationEmail(db, {
    applicationRef,
    to: adminEmail,
    type: EMAIL_TYPE.credentials,
    message: approvalEmail({
      application: {
        schoolName: school.name,
        plan: {
          tierLabel: school.tierLabel,
          capacity: school.capacity,
          billingCycle: school.billingCycle,
        },
      },
      adminEmail,
      tempPassword,
      receipt,
    }),
  });

  await writeAuditLog(db, {
    action: AUDIT.adminCredentialsResent,
    actorUid: uid,
    actorEmail: actor.email,
    actorRole: ROLES.superAdmin,
    targetType: "user",
    targetId: adminDoc.id,
    reason,
    metadata: { schoolId, emailSent: email.sent },
  });

  return { emailSent: email.sent, emailError: email.error || null, email: adminEmail };
});

/** Replaces the banking-holiday list the review target is measured against. */
exports.updateBankingCalendar = onCall(async (request) => {
  const { uid, db, data: actor } = await requireSuperAdmin(request);
  const holidays = Array.isArray(request.data?.holidays) ? request.data.holidays : [];
  const clean = holidays
    .map((h) => sanitizeText(h, 10))
    .filter((h) => /^\d{4}-\d{2}-\d{2}$/.test(h));
  if (clean.length !== holidays.length) {
    throw new HttpsError("invalid-argument", "Dates must be formatted YYYY-MM-DD.");
  }
  if (clean.length > 400) {
    throw new HttpsError("invalid-argument", "That is more holidays than a calendar has days.");
  }

  await db.collection("platformConfig").doc("bankingCalendar").set(
    {
      holidays: clean,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedBy: uid,
    },
    { merge: true }
  );

  await writeAuditLog(db, {
    action: "platform.banking_calendar_updated",
    actorUid: uid,
    actorEmail: actor.email,
    actorRole: ROLES.superAdmin,
    targetType: "config",
    targetId: "bankingCalendar",
    metadata: { count: clean.length },
  });

  return { count: clean.length };
});

module.exports.STATUS = STATUS;
module.exports.DOC = DOC;
module.exports.DOC_LABELS = DOC_LABELS;
module.exports.INSTITUTION_REQUIREMENTS = INSTITUTION_REQUIREMENTS;
module.exports.provisionSchool = provisionSchool;
