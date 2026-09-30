/**
 * End-to-end check of unscheduled stops, against the local emulators.
 *
 *   npm run test:enrollment     (runs every *.it.js here)
 *
 * The point of the feature is who is told, so that is what is checked: a
 * stopover reaches the school and the parents; an emergency always reaches the
 * school and reaches the parents only when the facilitator says so; and only a
 * facilitator on a bus, on a trip under way, can log one at all.
 */
const test = require("node:test");
const assert = require("node:assert/strict");

const admin = require("firebase-admin");
const PROJECT = process.env.GCLOUD_PROJECT || "pildtrip360";
if (!admin.apps.length) admin.initializeApp({ projectId: PROJECT });
const db = admin.firestore();

const FN = `http://127.0.0.1:5001/${PROJECT}/us-central1`;
let n = 0;
const uniq = () => `${Date.now()}_${n++}`;

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

async function logStop(uid, data) {
  const res = await fetch(`${FN}/logUnscheduledStop`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${await tokenFor(uid)}`,
    },
    body: JSON.stringify({ data }),
  });
  const body = await res.json();
  return body.error ? { error: body.error } : { result: body.result };
}

async function inbox(uid) {
  return (await db.collection("users").doc(uid).collection("notifications").get()).docs.map((d) =>
    d.data()
  );
}

/** A school with an admin, a facilitator on bus 1, and two students with parents. */
async function world({ status = "in_progress" } = {}) {
  const tag = uniq();
  const schoolId = `school_${tag}`;
  await db.collection("schools").doc(schoolId).set({ name: "Test School" });

  const make = async (role, extra = {}) => {
    const uid = `${role}_${tag}_${n++}`;
    await admin.auth().createUser({ uid });
    await db.collection("users").doc(uid).set({ role, schoolId, name: role, ...extra });
    return uid;
  };

  const adminUid = await make("admin");
  const teacher = await make("teacher");
  const stranger = await make("teacher");
  const s1 = await make("student");
  const s2 = await make("student");
  const p1 = await make("parent", { children: [s1] });
  const p2 = await make("parent", { children: [s2] });
  await db.collection("users").doc(s1).update({ parentIds: [p1] });
  await db.collection("users").doc(s2).update({ parentIds: [p2] });
  // A parent on another bus must never be told about this one.
  const s3 = await make("student");
  const p3 = await make("parent", { children: [s3] });

  const tripId = `trip_${tag}`;
  await db.collection("trips").doc(tripId).set({
    schoolId,
    title: "Museum Trip",
    status,
    buses: [
      {
        busLabel: "1",
        mainTeacher: { id: teacher, name: "Ms Cruz" },
        passengers: [
          { id: s1, name: "One" },
          { id: s2, name: "Two" },
        ],
      },
      {
        busLabel: "2",
        mainTeacher: { id: stranger, name: "Mr Reyes" },
        passengers: [{ id: s3, name: "Three" }],
      },
    ],
  });

  return { schoolId, tripId, adminUid, teacher, stranger, p1, p2, p3 };
}

test("a stopover tells the school and the parents on that bus", async () => {
  const w = await world();
  const res = await logStop(w.teacher, {
    tripId: w.tripId,
    kind: "stopover",
    place: "Petron Plaridel",
    reason: "Toilet break",
  });
  assert.equal(res.error, undefined, JSON.stringify(res.error));
  assert.equal(res.result.kind, "stopover");
  assert.equal(res.result.parentsNotified, true);
  assert.equal(res.result.parentsReached, 2);

  assert.equal((await inbox(w.adminUid)).length, 1);
  assert.equal((await inbox(w.p1)).length, 1);
  assert.equal((await inbox(w.p2)).length, 1);
  assert.equal((await inbox(w.p3)).length, 0, "a parent on the other bus is not told");

  const note = (await inbox(w.p1))[0];
  assert.match(note.body, /Petron Plaridel/);
  assert.match(note.body, /Toilet break/);
  assert.equal(note.type, "trip_stopover");
});

test("a stopover reaches the parents even if the caller tries to switch that off", async () => {
  const w = await world();
  const res = await logStop(w.teacher, {
    tripId: w.tripId, kind: "stopover", notifyParents: false,
  });
  assert.equal(res.error, undefined);
  assert.equal(res.result.parentsNotified, true);
  assert.equal((await inbox(w.p1)).length, 1);
});

test("an emergency always tells the school, and tells parents when asked", async () => {
  const w = await world();
  const res = await logStop(w.teacher, {
    tripId: w.tripId, kind: "emergency", reason: "Vehicle problem", notifyParents: true,
  });
  assert.equal(res.error, undefined, JSON.stringify(res.error));
  assert.equal(res.result.parentsReached, 2);
  assert.equal((await inbox(w.adminUid)).length, 1);
  assert.equal((await inbox(w.p1)).length, 1);
  assert.equal((await inbox(w.p1))[0].type, "trip_emergency");
  assert.equal((await inbox(w.p3)).length, 0);
});

test("an emergency with the parents switched off tells only the school", async () => {
  const w = await world();
  const res = await logStop(w.teacher, {
    tripId: w.tripId, kind: "emergency", reason: "Medical", notifyParents: false,
  });
  assert.equal(res.error, undefined);
  assert.equal(res.result.parentsNotified, false);
  assert.equal(res.result.parentsReached, 0);
  assert.equal((await inbox(w.adminUid)).length, 1);
  assert.equal((await inbox(w.p1)).length, 0);
  assert.equal((await inbox(w.p2)).length, 0);
});

test("an emergency that does not say either way does not tell the parents", async () => {
  const w = await world();
  const res = await logStop(w.teacher, { tripId: w.tripId, kind: "emergency" });
  assert.equal(res.error, undefined);
  assert.equal(res.result.parentsNotified, false);
  assert.equal((await inbox(w.p1)).length, 0);
  assert.equal((await inbox(w.adminUid)).length, 1);
});

test("the stop is recorded for the trip report, with who logged it and which bus", async () => {
  const w = await world();
  const res = await logStop(w.teacher, { tripId: w.tripId, kind: "stopover", reason: "Fuel" });
  const ev = (await db.collection("tripEvents").doc(res.result.eventId).get()).data();
  assert.equal(ev.tripId, w.tripId);
  assert.equal(ev.schoolId, w.schoolId);
  assert.equal(ev.kind, "stopover");
  assert.equal(ev.busLabel, "1");
  assert.equal(ev.loggedBy, w.teacher);
  assert.equal(ev.passengerCount, 2);
});

test("the bus comes from the caller's own assignment, so one facilitator cannot report another's bus", async () => {
  const w = await world();
  const res = await logStop(w.stranger, { tripId: w.tripId, kind: "stopover", busIndex: 0 });
  assert.equal(res.error, undefined);
  assert.equal(res.result.busLabel, "2");
  assert.equal((await inbox(w.p1)).length, 0, "bus 1's parents are not told about bus 2");
  assert.equal((await inbox(w.p3)).length, 1);
});

test("someone not on a bus cannot log a stop", async () => {
  const w = await world();
  const outsider = `outsider_${uniq()}`;
  await admin.auth().createUser({ uid: outsider });
  await db.collection("users").doc(outsider).set({ role: "teacher", schoolId: w.schoolId });
  const res = await logStop(outsider, { tripId: w.tripId, kind: "stopover" });
  assert.ok(res.error);
  assert.match(res.error.message, /assigned to a bus/);
});

test("a stop cannot be logged before the trip has left", async () => {
  const w = await world({ status: "pending" });
  const res = await logStop(w.teacher, { tripId: w.tripId, kind: "stopover" });
  assert.ok(res.error);
  assert.match(res.error.message, /in progress/);
  assert.equal((await inbox(w.p1)).length, 0);
});
