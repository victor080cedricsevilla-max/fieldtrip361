/**
 * Security-rule tests for firestore.rules.
 *
 * These cover the boundary itself, not the logic behind it. Every case here is
 * a hole that was open at some point during the September 2026 rebuild: a
 * client minting itself an admin role, a super admin inheriting a directory of
 * minors, a facilitator writing attendance straight into the trip, an anonymous
 * applicant session reaching a student's live location. A rule that is not
 * tested is a rule that quietly stops holding.
 *
 * Run with the emulator around it:
 *   npm run test:rules
 */
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");

const {
  initializeTestEnvironment,
  assertFails,
  assertSucceeds,
} = require("@firebase/rules-unit-testing");

const {
  doc,
  getDoc,
  setDoc,
  updateDoc,
  collection,
  getDocs,
  query,
  where,
} = require("firebase/firestore");

const RULES = fs.readFileSync(
  path.join(__dirname, "..", "..", "..", "firestore.rules"),
  "utf8"
);

let env;

const SCHOOL_A = "schoolA";
const SCHOOL_B = "schoolB";

/** Seeds the user documents every rule calls get() on. */
async function seed() {
  await env.withSecurityRulesDisabled(async (ctx) => {
    const db = ctx.firestore();
    await setDoc(doc(db, "users/adminA"), {
      role: "admin", schoolId: SCHOOL_A, accountStatus: "active", email: "a@a.test",
    });
    await setDoc(doc(db, "users/adminB"), {
      role: "admin", schoolId: SCHOOL_B, accountStatus: "active", email: "b@b.test",
    });
    await setDoc(doc(db, "users/teacher1"), {
      role: "teacher", schoolId: SCHOOL_A, accountStatus: "active", email: "t@a.test",
    });
    await setDoc(doc(db, "users/student1"), {
      role: "student", schoolId: SCHOOL_A, accountStatus: "active", email: "s@a.test",
    });
    await setDoc(doc(db, "users/parent1"), {
      role: "parent", schoolId: SCHOOL_A, accountStatus: "active",
      children: ["student1"], email: "p@a.test",
    });
    await setDoc(doc(db, "users/super1"), {
      role: "super_admin", accountStatus: "active", email: "root@ft.test",
    });
    await setDoc(doc(db, "users/disabledAdmin"), {
      role: "admin", schoolId: SCHOOL_A, accountStatus: "disabled", email: "x@a.test",
    });

    // A trip that has already left, with a teacher facilitating bus 0.
    await setDoc(doc(db, "trips/trip1"), {
      schoolId: SCHOOL_A,
      status: "ongoing",
      allMemberIds: ["teacher1", "student1"],
      activeStopIndex: 0,
      stopStatuses: [],
      buses: [
        {
          busNumber: "1",
          teacherId: "teacher1",
          passengers: [{ id: "student1", name: "Ana", attendance: null }],
        },
      ],
    });

    // A trip still being composed.
    await setDoc(doc(db, "trips/trip2"), {
      schoolId: SCHOOL_A,
      status: "pending",
      allMemberIds: ["teacher1"],
      buses: [{ busNumber: "1", teacherId: "teacher1", passengers: [] }],
    });

    await setDoc(doc(db, "locations/student1"), {
      lat: 14.9, lng: 120.9, schoolId: SCHOOL_A,
    });

    await setDoc(doc(db, "announcements/ann1"), {
      title: "Scheduled maintenance", body: "We will be down briefly.",
      category: "maintenance", status: "published",
    });
    await setDoc(doc(db, "announcements/ann2"), {
      title: "Draft", body: "Not published yet.",
      category: "update", status: "draft",
    });

    await setDoc(doc(db, "supportTickets/t1"), {
      subject: "Help", status: "open", requester: { uid: "teacher1" },
    });
  });
}

const as = (uid, claims) => env.authenticatedContext(uid, claims).firestore();
const anon = () => env.authenticatedContext("anonUser", { provider_id: "anonymous" }).firestore();

test.before(async () => {
  env = await initializeTestEnvironment({
    projectId: "ft360-rules-test",
    firestore: { rules: RULES, host: "127.0.0.1", port: 8080 },
  });
  await seed();
});

test.after(async () => {
  if (env) await env.cleanup();
});

// ─── users: creating an account ───────────────────────────────────────────────

test("a client cannot mint itself an admin role", async () => {
  await assertFails(
    setDoc(doc(as("newbie"), "users/newbie"), { role: "admin", email: "n@n.test" })
  );
});

test("a client cannot mint itself a super admin", async () => {
  await assertFails(
    setDoc(doc(as("newbie2"), "users/newbie2"), { role: "super_admin", email: "n@n.test" })
  );
});

test("a self-service role may register", async () => {
  await assertSucceeds(
    setDoc(doc(as("newStudent"), "users/newStudent"), {
      role: "student", email: "new@s.test", name: "New",
    })
  );
});

test("a new account cannot arrive already attached to a school", async () => {
  await assertFails(
    setDoc(doc(as("sneaky"), "users/sneaky"), {
      role: "student", email: "s@s.test", schoolId: SCHOOL_A,
    })
  );
});

test("a new parent cannot arrive already listing someone else's child", async () => {
  await assertFails(
    setDoc(doc(as("sneakyParent"), "users/sneakyParent"), {
      role: "parent", email: "p@p.test", children: ["student1"],
    })
  );
});

test("a teacher cannot register pre-approved", async () => {
  await assertFails(
    setDoc(doc(as("sneakyTeacher"), "users/sneakyTeacher"), {
      role: "teacher", email: "t@t.test", status: "pending_is_expected",
    })
  );
});

// ─── users: reading ───────────────────────────────────────────────────────────

test("every role can read its own document", async () => {
  await assertSucceeds(getDoc(doc(as("student1"), "users/student1")));
  await assertSucceeds(getDoc(doc(as("teacher1"), "users/teacher1")));
  await assertSucceeds(getDoc(doc(as("adminA"), "users/adminA")));
});

test("a super admin can read its own document", async () => {
  // This one locked the super admin out of the app entirely when it was wrong.
  await assertSucceeds(
    getDoc(doc(as("super1", { superAdmin: true }), "users/super1"))
  );
});

test("a super admin may read a school administrator", async () => {
  await assertSucceeds(
    getDoc(doc(as("super1", { superAdmin: true }), "users/adminA"))
  );
});

test("a super admin may NOT read a student", async () => {
  await assertFails(
    getDoc(doc(as("super1", { superAdmin: true }), "users/student1"))
  );
});

test("a super admin may NOT read a parent or a teacher", async () => {
  const db = as("super1", { superAdmin: true });
  await assertFails(getDoc(doc(db, "users/parent1")));
  await assertFails(getDoc(doc(db, "users/teacher1")));
});

// ─── users: updating ──────────────────────────────────────────────────────────

test("an owner cannot promote themselves by update", async () => {
  await assertFails(
    updateDoc(doc(as("student1"), "users/student1"), { role: "admin" })
  );
});

test("an owner cannot lift their own suspension", async () => {
  await assertFails(
    updateDoc(doc(as("disabledAdmin"), "users/disabledAdmin"), {
      accountStatus: "active",
    })
  );
});

test("an owner cannot attach themselves to a school", async () => {
  await assertFails(
    updateDoc(doc(as("student1"), "users/student1"), { schoolId: SCHOOL_B })
  );
});

test("an owner may still edit their own name", async () => {
  await assertSucceeds(
    updateDoc(doc(as("student1"), "users/student1"), { name: "Ana Reyes" })
  );
});

// ─── trips: who may write what ────────────────────────────────────────────────

test("a facilitator may move the trip along", async () => {
  await assertSucceeds(
    updateDoc(doc(as("teacher1"), "trips/trip1"), { activeStopIndex: 1 })
  );
});

test("a facilitator may NOT write buses — that is where attendance lives", async () => {
  await assertFails(
    updateDoc(doc(as("teacher1"), "trips/trip1"), {
      buses: [
        {
          busNumber: "1",
          teacherId: "teacher1",
          passengers: [{ id: "student1", name: "Ana", attendance: { status: "present" } }],
        },
      ],
    })
  );
});

test("an admin may NOT write buses once the trip has started", async () => {
  await assertFails(
    updateDoc(doc(as("adminA"), "trips/trip1"), {
      buses: [
        {
          busNumber: "1",
          teacherId: "teacher1",
          passengers: [{ id: "student1", name: "Ana", attendance: { status: "present" } }],
        },
      ],
    })
  );
});

test("an admin may still compose a trip that has not left", async () => {
  await assertSucceeds(
    updateDoc(doc(as("adminA"), "trips/trip2"), {
      buses: [
        { busNumber: "1", teacherId: "teacher1", passengers: [{ id: "student1", name: "Ana" }] },
      ],
    })
  );
});

test("an admin of another school cannot touch the trip", async () => {
  await assertFails(
    updateDoc(doc(as("adminB"), "trips/trip1"), { activeStopIndex: 2 })
  );
});

test("a super admin cannot read a trip", async () => {
  await assertFails(
    getDoc(doc(as("super1", { superAdmin: true }), "trips/trip1"))
  );
});

// ─── locations: the anonymous-session hole ────────────────────────────────────

test("an anonymous applicant session cannot read a student's location", async () => {
  // Anonymous sign-in exists so a registrar can upload documents without an
  // account. Before isSchoolUser() this path was a bare isSignedIn(), which
  // would have handed every student's live position to anyone at all.
  await assertFails(getDoc(doc(anon(), "locations/student1")));
});

test("a school user may still read a location", async () => {
  await assertSucceeds(getDoc(doc(as("teacher1"), "locations/student1")));
});

test("a super admin cannot read a location", async () => {
  await assertFails(
    getDoc(doc(as("super1", { superAdmin: true }), "locations/student1"))
  );
});

// ─── announcements ────────────────────────────────────────────────────────────

test("an admin reads published announcements", async () => {
  const db = as("adminA");
  await assertSucceeds(
    getDocs(query(collection(db, "announcements"), where("status", "==", "published")))
  );
});

test("an admin cannot read an unpublished draft", async () => {
  await assertFails(getDoc(doc(as("adminA"), "announcements/ann2")));
});

test("nobody may write an announcement from a client", async () => {
  await assertFails(
    setDoc(doc(as("super1", { superAdmin: true }), "announcements/ann3"), {
      title: "Nope", status: "published",
    })
  );
});

test("an admin may record that they read one", async () => {
  await assertSucceeds(
    setDoc(doc(as("adminA"), "users/adminA/announcementReads/ann1"), { readAt: new Date() })
  );
});

test("an admin cannot write another admin's read marker", async () => {
  await assertFails(
    setDoc(doc(as("adminA"), "users/adminB/announcementReads/ann1"), { readAt: new Date() })
  );
});

// ─── support tickets ──────────────────────────────────────────────────────────

test("a requester reads their own ticket", async () => {
  await assertSucceeds(getDoc(doc(as("teacher1"), "supportTickets/t1")));
});

test("an administrator does not see a teacher's support conversation", async () => {
  await assertFails(getDoc(doc(as("adminA"), "supportTickets/t1")));
});

test("a ticket cannot be written from a client", async () => {
  await assertFails(
    setDoc(doc(as("teacher1"), "supportTickets/t2"), {
      subject: "Forged", status: "open", requester: { uid: "teacher1" },
    })
  );
});

// ─── platform audit log ───────────────────────────────────────────────────────

test("a school admin cannot read the platform audit log", async () => {
  await assertFails(getDoc(doc(as("adminA"), "platformAuditLogs/any")));
});

test("nobody may write the platform audit log from a client", async () => {
  await assertFails(
    setDoc(doc(as("super1", { superAdmin: true }), "platformAuditLogs/forged"), {
      action: "made_up",
    })
  );
});
