/**
 * Security-rule tests for storage.rules.
 *
 * The file that matters most here is a student's filled-in medical clearance.
 * For a while any administrator or teacher of *any* school could read *any*
 * student's, because the rule checked the role and forgot the school. That is
 * the case this file exists to keep closed.
 *
 * Run with the emulator around it:
 *   npm run test:rules
 */
const test = require("node:test");
const fs = require("node:fs");
const path = require("node:path");

const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require("@firebase/rules-unit-testing");

const { doc, setDoc } = require("firebase/firestore");
const { ref, uploadBytes, getBytes } = require("firebase/storage");

const ROOT = path.join(__dirname, "..", "..", "..");
const STORAGE_RULES = fs.readFileSync(path.join(ROOT, "storage.rules"), "utf8");
const FIRESTORE_RULES = fs.readFileSync(path.join(ROOT, "firestore.rules"), "utf8");

const SCHOOL_A = "schoolA";
const SCHOOL_B = "schoolB";
const PDF = new Uint8Array([0x25, 0x50, 0x44, 0x46]); // "%PDF"
const asPdf = { contentType: "application/pdf" };

let env;

/**
 * Storage rules call firestore.get() for the role, so the user documents have
 * to exist in the Firestore emulator as well.
 */
async function seed() {
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, "users/adminA"), {
      role: "admin", schoolId: SCHOOL_A, accountStatus: "active",
    });
    await setDoc(doc(db, "users/adminB"), {
      role: "admin", schoolId: SCHOOL_B, accountStatus: "active",
    });
    await setDoc(doc(db, "users/teacherA"), {
      role: "teacher", schoolId: SCHOOL_A, accountStatus: "active",
    });
    await setDoc(doc(db, "users/teacherB"), {
      role: "teacher", schoolId: SCHOOL_B, accountStatus: "active",
    });
    await setDoc(doc(db, "users/studentA"), {
      role: "student", schoolId: SCHOOL_A, accountStatus: "active",
    });
    await setDoc(doc(db, "users/suspendedAdminA"), {
      role: "admin", schoolId: SCHOOL_A, accountStatus: "disabled",
    });
    await setDoc(doc(db, "users/super1"), {
      role: "super_admin", accountStatus: "active",
    });

    const storage = ctx.storage();
    await uploadBytes(
      ref(storage, `document_submissions/${SCHOOL_A}/studentA/medical.pdf`),
      PDF,
      asPdf
    );
    await uploadBytes(
      ref(storage, `school_applications/app1/applicantSession/sec.pdf`),
      PDF,
      asPdf
    );
  });
}

const as = (uid, claims) => env.authenticatedContext(uid, claims).storage();

test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: "ft360-rules-test",
    firestore: { rules: FIRESTORE_RULES, host: "127.0.0.1", port: 8080 },
    storage: { rules: STORAGE_RULES, host: "127.0.0.1", port: 9199 },
  });
  await seed();
});

test.after(async () => {
  if (env) await env.cleanup();
});

// ─── A student's medical form ─────────────────────────────────────────────────

const MEDICAL = `document_submissions/${SCHOOL_A}/studentA/medical.pdf`;

test("the student who uploaded it can read their own medical form", async () => {
  await assertSucceeds(getBytes(ref(as("studentA"), MEDICAL)));
});

test("staff of that student's school can read it", async () => {
  await assertSucceeds(getBytes(ref(as("adminA"), MEDICAL)));
  await assertSucceeds(getBytes(ref(as("teacherA"), MEDICAL)));
});

test("an administrator of ANOTHER school cannot read it", async () => {
  // The leak this file was written for.
  await assertFails(getBytes(ref(as("adminB"), MEDICAL)));
});

test("a teacher of another school cannot read it", async () => {
  await assertFails(getBytes(ref(as("teacherB"), MEDICAL)));
});

test("a suspended administrator of the right school cannot read it", async () => {
  await assertFails(getBytes(ref(as("suspendedAdminA"), MEDICAL)));
});

test("the super admin cannot read a student's medical form", async () => {
  await assertFails(
    getBytes(ref(as("super1", { superAdmin: true }), MEDICAL))
  );
});

test("a student cannot upload into another student's folder", async () => {
  await assertFails(
    uploadBytes(
      ref(as("studentA"), `document_submissions/${SCHOOL_A}/someoneElse/forged.pdf`),
      PDF,
      asPdf
    )
  );
});

test("an executable disguised in the folder is refused", async () => {
  await assertFails(
    uploadBytes(
      ref(as("studentA"), `document_submissions/${SCHOOL_A}/studentA/payload.exe`),
      PDF,
      { contentType: "application/x-msdownload" }
    )
  );
});

// ─── Subscription application documents ───────────────────────────────────────

const SEC = "school_applications/app1/applicantSession/sec.pdf";

test("the applicant session that uploaded it can read it back", async () => {
  await assertSucceeds(getBytes(ref(as("applicantSession"), SEC)));
});

test("the super admin reviewing the application can read it", async () => {
  await assertSucceeds(
    getBytes(ref(as("super1", { superAdmin: true }), SEC))
  );
});

test("another applicant cannot read someone else's application document", async () => {
  await assertFails(getBytes(ref(as("otherApplicant"), SEC)));
});

test("a school administrator cannot read an application document", async () => {
  await assertFails(getBytes(ref(as("adminA"), SEC)));
});

test("an applicant cannot upload into another session's folder", async () => {
  await assertFails(
    uploadBytes(
      ref(as("otherApplicant"), "school_applications/app1/applicantSession/forged.pdf"),
      PDF,
      asPdf
    )
  );
});

// ─── Profile photos ───────────────────────────────────────────────────────────

test("a user may write their own profile photo", async () => {
  await assertSucceeds(
    uploadBytes(ref(as("studentA"), "profile_photos/studentA.jpg"), PDF, {
      contentType: "image/jpeg",
    })
  );
});

test("a user cannot overwrite someone else's profile photo", async () => {
  await assertFails(
    uploadBytes(ref(as("studentA"), "profile_photos/adminA.jpg"), PDF, {
      contentType: "image/jpeg",
    })
  );
});
