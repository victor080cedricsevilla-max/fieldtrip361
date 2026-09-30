/**
 * End-to-end check of registration by code, against the local emulators.
 *
 *   npm run test:enrollment
 *
 * The unit tests cover how codes are built and read. This covers what happens
 * when one is redeemed: the account is created from the code, never from the
 * request; the student's LRN arrives from the roster; parents and children link
 * whichever registers first; a second child goes onto the first account; and a
 * used, withdrawn or expired code is refused.
 *
 * Codes are seeded directly rather than issued, because issuing sends email and
 * this must never reach a real mailbox. The hash uses the same pepper the
 * function reads, taken from the env file without being printed.
 */
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

// ── Pepper: read the way the functions emulator will, never logged ───────────
const PROJECT = process.env.GCLOUD_PROJECT || "pildtrip360";
for (const name of [`.env.${PROJECT}`, ".env"]) {
  const file = path.join(__dirname, "..", "..", name);
  if (!fs.existsSync(file)) continue;
  for (const line of fs.readFileSync(file, "utf8").split(/\r?\n/)) {
    const m = /^ACTIVATION_PEPPER=(.*)$/.exec(line.trim());
    if (m && process.env.ACTIVATION_PEPPER === undefined) {
      process.env.ACTIVATION_PEPPER = m[1].replace(/^["']|["']$/g, "");
    }
  }
}

const admin = require("firebase-admin");
admin.initializeApp({ projectId: PROJECT });
const db = admin.firestore();

const { _internal } = require("../../lib/enrollment");
const { generateCode, hashCode } = _internal;

const FN = `http://127.0.0.1:5001/${PROJECT}/us-central1`;
const PASSWORD = "a-long-enough-password";

// ── Helpers ──────────────────────────────────────────────────────────────────

let ipCounter = 0;

/**
 * Calls a callable over HTTP, optionally as a signed-in user.
 *
 * Each call comes from its own address. Redeeming is throttled per address, and
 * that throttle is exactly what should happen to one client hammering it — but
 * these tests are many different people, not one.
 */
async function call(name, data, idToken) {
  const n = ipCounter++;
  const res = await fetch(`${FN}/${name}`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-Forwarded-For": `10.77.${Math.floor(n / 250)}.${(n % 250) + 1}`,
      ...(idToken ? { Authorization: `Bearer ${idToken}` } : {}),
    },
    body: JSON.stringify({ data }),
  });
  const body = await res.json();
  return body.error ? { error: body.error } : { result: body.result };
}

/** An ID token for a user the emulator already knows. */
async function tokenFor(uid) {
  const custom = await admin.auth().createCustomToken(uid);
  const res = await fetch(
    "http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=demo",
    {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ token: custom, returnSecureToken: true }),
    }
  );
  return (await res.json()).idToken;
}

let counter = 0;
const uniq = () => `${Date.now()}${counter++}`;

async function seedSchool() {
  const id = `school_${uniq()}`;
  await db.collection("schools").doc(id).set({ name: "Test School" });
  return id;
}

async function seedStudent(schoolId, over = {}) {
  const ref = db.collection("roster").doc();
  const n = uniq();
  await ref.set({
    schoolId,
    studentNumber: `2024-${n}`,
    firstName: "Juan",
    lastName: "Dela Cruz",
    name: "Juan Dela Cruz",
    email: `juan.${n}@student.test`,
    gradeLevel: "Grade 10",
    section: "St. Peter",
    status: "pending",
    claimedUid: null,
    ...over,
  });
  return { id: ref.id, data: (await ref.get()).data() };
}

async function seedGuardian(schoolId, student, over = {}) {
  const ref = db.collection("guardians").doc();
  await ref.set({
    schoolId,
    studentId: student.id,
    studentName: student.data.name,
    studentUid: null,
    name: "Pedro Dela Cruz",
    relationship: "Father",
    email: `pedro.${uniq()}@parent.test`,
    status: "activation_ready",
    parentUid: null,
    activationStatus: null,
    ...over,
  });
  return { id: ref.id, data: (await ref.get()).data() };
}

/** A pending code, written the way issueOne writes it. */
async function seedCode({ role, schoolId, email, rosterId, guardianId, studentName, expiresInMs = 30 * 864e5, status = "pending" }) {
  const code = generateCode(role);
  await db.collection("enrollmentCodes").add({
    role,
    subjectId: role === "student" ? `roster:${rosterId}` : `guardian:${guardianId}`,
    rosterId: rosterId || null,
    guardianId: guardianId || null,
    schoolId,
    email,
    recipientName: role === "student" ? "Juan" : "Pedro Dela Cruz",
    studentName: studentName || null,
    codeHash: hashCode(code),
    status,
    expiresAt: admin.firestore.Timestamp.fromMillis(Date.now() + expiresInMs),
    createdAt: admin.firestore.Timestamp.now(),
    createdBy: "test",
    usedAt: null,
    usedByUid: null,
  });
  return code;
}

const redeem = (code, extra = {}) =>
  call("redeemEnrollmentCode", {
    code,
    password: PASSWORD,
    acceptedTermsVersion: "1.0",
    ...extra,
  });

// ── Tests ────────────────────────────────────────────────────────────────────

test("a student registers with a code alone, and the LRN comes off the roster", async () => {
  const schoolId = await seedSchool();
  const s = await seedStudent(schoolId);
  const code = await seedCode({ role: "student", schoolId, email: s.data.email, rosterId: s.id });

  const res = await redeem(code);
  assert.equal(res.error, undefined, JSON.stringify(res.error));
  assert.equal(res.result.role, "student");
  assert.equal(res.result.email, s.data.email);
  assert.equal(res.result.schoolName, "Test School");

  const auth = await admin.auth().getUserByEmail(s.data.email);
  assert.equal(auth.emailVerified, true);

  const user = (await db.collection("users").doc(auth.uid).get()).data();
  assert.equal(user.role, "student");
  assert.equal(user.schoolId, schoolId);
  assert.equal(user.lrn, s.data.studentNumber);
  assert.equal(user.studentId, s.data.studentNumber);
  assert.equal(user.termsAcceptedVersion, "1.0");
  assert.ok(user.termsAcceptedAt);

  const roster = (await db.collection("roster").doc(s.id).get()).data();
  assert.equal(roster.status, "claimed");
  assert.equal(roster.claimedUid, auth.uid);
});

test("the account is created for the address in the code, whatever the caller sends", async () => {
  const schoolId = await seedSchool();
  const s = await seedStudent(schoolId);
  const code = await seedCode({ role: "student", schoolId, email: s.data.email, rosterId: s.id });

  const res = await redeem(code, { email: "attacker@evil.test", role: "admin", schoolId: "other" });
  assert.equal(res.error, undefined);
  assert.equal(res.result.email, s.data.email);
  await assert.rejects(admin.auth().getUserByEmail("attacker@evil.test"));
  const auth = await admin.auth().getUserByEmail(s.data.email);
  const user = (await db.collection("users").doc(auth.uid).get()).data();
  assert.equal(user.role, "student");
  assert.equal(user.schoolId, schoolId);
});

test("registration is refused without agreement to the terms", async () => {
  const schoolId = await seedSchool();
  const s = await seedStudent(schoolId);
  const code = await seedCode({ role: "student", schoolId, email: s.data.email, rosterId: s.id });

  const res = await redeem(code, { acceptedTermsVersion: "" });
  assert.ok(res.error);
  assert.match(res.error.message, /Terms/);
  await assert.rejects(admin.auth().getUserByEmail(s.data.email));
});

test("a short password is refused and leaves the code unused", async () => {
  const schoolId = await seedSchool();
  const s = await seedStudent(schoolId);
  const code = await seedCode({ role: "student", schoolId, email: s.data.email, rosterId: s.id });

  const bad = await redeem(code, { password: "short" });
  assert.ok(bad.error);
  const good = await redeem(code);
  assert.equal(good.error, undefined);
});

test("a code works once", async () => {
  const schoolId = await seedSchool();
  const s = await seedStudent(schoolId);
  const code = await seedCode({ role: "student", schoolId, email: s.data.email, rosterId: s.id });

  assert.equal((await redeem(code)).error, undefined);
  const again = await redeem(code);
  assert.ok(again.error);
  assert.match(again.error.message, /already been used/);
});

test("an expired code is refused with a way forward", async () => {
  const schoolId = await seedSchool();
  const s = await seedStudent(schoolId);
  const code = await seedCode({
    role: "student", schoolId, email: s.data.email, rosterId: s.id, expiresInMs: -1000,
  });
  const res = await redeem(code);
  assert.ok(res.error);
  assert.match(res.error.message, /expired/);
  assert.match(res.error.message, /new one/);
});

test("a withdrawn code is refused", async () => {
  const schoolId = await seedSchool();
  const s = await seedStudent(schoolId);
  const code = await seedCode({
    role: "student", schoolId, email: s.data.email, rosterId: s.id, status: "revoked",
  });
  const res = await redeem(code);
  assert.ok(res.error);
  assert.match(res.error.message, /withdrawn/);
});

test("a code that does not exist gets the same answer as any other unknown code", async () => {
  const res = await redeem("S-ACDE-FGHJ");
  assert.ok(res.error);
  assert.match(res.error.message, /not valid/);
});

test("a parent whose child is already registered is linked at once", async () => {
  const schoolId = await seedSchool();
  const s = await seedStudent(schoolId);
  const g = await seedGuardian(schoolId, s);

  const sCode = await seedCode({ role: "student", schoolId, email: s.data.email, rosterId: s.id });
  assert.equal((await redeem(sCode)).error, undefined);
  const student = await admin.auth().getUserByEmail(s.data.email);

  const pCode = await seedCode({
    role: "parent", schoolId, email: g.data.email, rosterId: s.id, guardianId: g.id,
    studentName: s.data.name,
  });
  const res = await redeem(pCode);
  assert.equal(res.error, undefined, JSON.stringify(res.error));
  assert.equal(res.result.childLinked, true);
  assert.equal(res.result.childPending, false);

  const parent = await admin.auth().getUserByEmail(g.data.email);
  const pDoc = (await db.collection("users").doc(parent.uid).get()).data();
  assert.deepEqual(pDoc.children, [student.uid]);
  assert.deepEqual(pDoc.schoolIds, [schoolId]);
  assert.equal(pDoc.role, "parent");
  assert.equal(pDoc.schoolId, undefined, "a parent is not scoped to one school");

  const sDoc = (await db.collection("users").doc(student.uid).get()).data();
  assert.deepEqual(sDoc.parentIds, [parent.uid]);

  const gDoc = (await db.collection("guardians").doc(g.id).get()).data();
  assert.equal(gDoc.parentUid, parent.uid);
  assert.equal(gDoc.studentUid, student.uid);
  assert.equal(gDoc.status, "activated");
});

test("a parent who registers before their child is not turned away, and is linked when the child arrives", async () => {
  const schoolId = await seedSchool();
  const s = await seedStudent(schoolId);
  const g = await seedGuardian(schoolId, s);

  const pCode = await seedCode({
    role: "parent", schoolId, email: g.data.email, rosterId: s.id, guardianId: g.id,
    studentName: s.data.name,
  });
  const first = await redeem(pCode);
  assert.equal(first.error, undefined, JSON.stringify(first.error));
  assert.equal(first.result.childPending, true);
  const parent = await admin.auth().getUserByEmail(g.data.email);
  assert.deepEqual(
    (await db.collection("users").doc(parent.uid).get()).data().children,
    []
  );

  const sCode = await seedCode({ role: "student", schoolId, email: s.data.email, rosterId: s.id });
  const second = await redeem(sCode);
  assert.equal(second.error, undefined, JSON.stringify(second.error));
  assert.equal(second.result.parentsLinked, 1);

  const student = await admin.auth().getUserByEmail(s.data.email);
  assert.deepEqual(
    (await db.collection("users").doc(parent.uid).get()).data().children,
    [student.uid]
  );
  assert.deepEqual(
    (await db.collection("users").doc(student.uid).get()).data().parentIds,
    [parent.uid]
  );
});

test("a second child goes onto the parent's existing account, one code each", async () => {
  const schoolId = await seedSchool();
  const parentEmail = `mama.${uniq()}@parent.test`;

  const a = await seedStudent(schoolId, { name: "Ana Reyes", firstName: "Ana" });
  const b = await seedStudent(schoolId, { name: "Ben Reyes", firstName: "Ben" });
  const ga = await seedGuardian(schoolId, a, { email: parentEmail });
  const gb = await seedGuardian(schoolId, b, { email: parentEmail });

  for (const s of [a, b]) {
    const c = await seedCode({ role: "student", schoolId, email: s.data.email, rosterId: s.id });
    assert.equal((await redeem(c)).error, undefined);
  }
  const studentA = await admin.auth().getUserByEmail(a.data.email);
  const studentB = await admin.auth().getUserByEmail(b.data.email);

  const codeA = await seedCode({
    role: "parent", schoolId, email: parentEmail, rosterId: a.id, guardianId: ga.id, studentName: "Ana Reyes",
  });
  assert.equal((await redeem(codeA)).error, undefined);

  // The same address cannot register twice, and is told where to go instead.
  const codeB = await seedCode({
    role: "parent", schoolId, email: parentEmail, rosterId: b.id, guardianId: gb.id, studentName: "Ben Reyes",
  });
  const refused = await redeem(codeB);
  assert.ok(refused.error);
  assert.match(refused.error.message, /Add a child/);

  const parent = await admin.auth().getUserByEmail(parentEmail);
  const added = await call("addChildByCode", { code: codeB }, await tokenFor(parent.uid));
  assert.equal(added.error, undefined, JSON.stringify(added.error));
  assert.equal(added.result.childLinked, true);

  const pDoc = (await db.collection("users").doc(parent.uid).get()).data();
  assert.deepEqual([...pDoc.children].sort(), [studentA.uid, studentB.uid].sort());
});

test("a parent code cannot be used by an account with a different address", async () => {
  const schoolId = await seedSchool();
  const a = await seedStudent(schoolId);
  const b = await seedStudent(schoolId);
  const gaEmail = `one.${uniq()}@parent.test`;
  const ga = await seedGuardian(schoolId, a, { email: gaEmail });
  const gb = await seedGuardian(schoolId, b, { email: `two.${uniq()}@parent.test` });

  const codeA = await seedCode({
    role: "parent", schoolId, email: gaEmail, rosterId: a.id, guardianId: ga.id,
  });
  assert.equal((await redeem(codeA)).error, undefined);
  const parentOne = await admin.auth().getUserByEmail(gaEmail);

  const codeB = await seedCode({
    role: "parent", schoolId, email: gb.data.email, rosterId: b.id, guardianId: gb.id,
  });
  const res = await call("addChildByCode", { code: codeB }, await tokenFor(parentOne.uid));
  assert.ok(res.error);
  assert.match(res.error.message, /different email/);
});

test("a student cannot use addChildByCode", async () => {
  const schoolId = await seedSchool();
  const s = await seedStudent(schoolId);
  const code = await seedCode({ role: "student", schoolId, email: s.data.email, rosterId: s.id });
  assert.equal((await redeem(code)).error, undefined);
  const student = await admin.auth().getUserByEmail(s.data.email);

  const res = await call("addChildByCode", { code: "P-ACDE-FGHJ" }, await tokenFor(student.uid));
  assert.ok(res.error);
  assert.match(res.error.message, /Only a parent/);
});

test("a third parent cannot be linked to a student who already has two", async () => {
  const schoolId = await seedSchool();
  const s = await seedStudent(schoolId);
  const sCode = await seedCode({ role: "student", schoolId, email: s.data.email, rosterId: s.id });
  assert.equal((await redeem(sCode)).error, undefined);

  const made = [];
  for (let i = 0; i < 3; i++) {
    const g = await seedGuardian(schoolId, s, { relationship: `Guardian ${i}` });
    const c = await seedCode({
      role: "parent", schoolId, email: g.data.email, rosterId: s.id, guardianId: g.id,
    });
    made.push({ g, c });
  }
  assert.equal((await redeem(made[0].c)).error, undefined);
  assert.equal((await redeem(made[1].c)).error, undefined);

  const third = await redeem(made[2].c);
  assert.ok(third.error);
  assert.match(third.error.message, /already has 2 linked parents/);
  // Turned away before anything was created, so nothing is left half-built and
  // the code is still good for when a place frees up.
  await assert.rejects(admin.auth().getUserByEmail(made[2].g.data.email));
  const codeDoc = await db
    .collection("enrollmentCodes")
    .where("codeHash", "==", hashCode(made[2].c))
    .get();
  assert.equal(codeDoc.docs[0].get("status"), "pending");
});
