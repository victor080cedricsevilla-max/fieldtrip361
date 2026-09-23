/**
 * Unit tests for the logic that decides things: banking-day deadlines, the
 * geofence distance check, and the review hints OCR produces.
 *
 * These are the parts where being wrong is expensive — a deadline quoted to an
 * applicant, a student refused attendance, or a hint that reads as a verdict.
 *
 *   node --test functions/test/
 */
const test = require("node:test");
const assert = require("node:assert/strict");

const {
  addBankingDays,
  addCalendarDays,
  isBankingHoliday,
  manilaDateString,
  reviewDeadlines,
} = require("../lib/banking_days");
const { distanceMeters, findPassenger } = require("../lib/attendance");
const { buildReviewHints } = require("../lib/ocr");
const { monthlyPriceFor, TIERS } = require("../lib/pricing");

// ─── Banking days ─────────────────────────────────────────────────────────────

test("banking days skip weekends", () => {
  // Friday 18 September 2026 in Manila.
  const from = new Date("2026-09-18T02:00:00Z");
  const out = addBankingDays(from, 7, []);
  // Sat 19 and Sun 20 are skipped, so the 7th working day is Tue 29 Sep.
  assert.equal(manilaDateString(out), "2026-09-29");
});

test("banking days skip configured holidays", () => {
  const from = new Date("2026-09-18T02:00:00Z");
  const out = addBankingDays(from, 7, ["2026-09-21"]);
  assert.equal(manilaDateString(out), "2026-09-30");
});

test("a weekend is a banking holiday without being listed", () => {
  assert.equal(isBankingHoliday(new Date("2026-09-19T02:00:00Z"), []), true); // Sat
  assert.equal(isBankingHoliday(new Date("2026-09-20T02:00:00Z"), []), true); // Sun
  assert.equal(isBankingHoliday(new Date("2026-09-22T02:00:00Z"), []), false); // Tue
});

test("calendar days skip nothing", () => {
  const from = new Date("2026-09-18T02:00:00Z");
  assert.equal(manilaDateString(addCalendarDays(from, 14)), "2026-10-02");
});

test("the two deadlines are computed independently", () => {
  const from = new Date("2026-09-18T02:00:00Z");
  const { reviewTargetAt, processingDeadlineAt } = reviewDeadlines(from, {
    bankingDayTarget: 7,
    calendarDayLimit: 14,
    holidays: [],
  });
  assert.equal(manilaDateString(reviewTargetAt), "2026-09-29");
  assert.equal(manilaDateString(processingDeadlineAt), "2026-10-02");
  // The review target must never fall after the processing limit, or the
  // promise made to the applicant contradicts itself.
  assert.ok(reviewTargetAt.getTime() < processingDeadlineAt.getTime());
});

test("a calendar that marks everything a holiday still terminates", () => {
  const every = [];
  for (let d = 1; d <= 31; d++) {
    every.push(`2026-10-${String(d).padStart(2, "0")}`);
  }
  const out = addBankingDays(new Date("2026-10-01T02:00:00Z"), 7, every);
  assert.ok(out instanceof Date);
});

// ─── Geofence distance ────────────────────────────────────────────────────────

test("distance is zero for the same point", () => {
  assert.equal(Math.round(distanceMeters(14.9, 120.9, 14.9, 120.9)), 0);
});

test("distance matches a known separation", () => {
  // ~111 m per 0.001 degree of latitude.
  const d = distanceMeters(14.9000, 120.9000, 14.9010, 120.9000);
  assert.ok(d > 105 && d < 118, `expected ~111 m, got ${d}`);
});

test("a student a kilometre away is outside a 100 m geofence", () => {
  const d = distanceMeters(14.9000, 120.9000, 14.9090, 120.9000);
  assert.ok(d > 100 + 25, `expected well outside, got ${d}`);
});

test("a student inside the radius passes even with slack applied", () => {
  const d = distanceMeters(14.9000, 120.9000, 14.90020, 120.9000);
  assert.ok(d <= 100 + 25, `expected inside, got ${d}`);
});

// ─── Passenger lookup ─────────────────────────────────────────────────────────

test("findPassenger locates a student on the right bus", () => {
  const buses = [
    { passengers: [{ id: "a", name: "Ana" }] },
    { passengers: [{ id: "b", name: "Ben" }, { id: "c", name: "Cara" }] },
  ];
  const found = findPassenger(buses, "c");
  assert.equal(found.busIndex, 1);
  assert.equal(found.passengerIndex, 1);
  assert.equal(found.passenger.name, "Cara");
});

test("findPassenger returns null for someone not on the trip", () => {
  assert.equal(findPassenger([{ passengers: [{ id: "a" }] }], "zz"), null);
});

// ─── OCR review hints ─────────────────────────────────────────────────────────

const application = { schoolName: "San Rafael NHS", legalName: "San Rafael National High School" };

test("a matching institution name produces no name hint", () => {
  const hints = buildReviewHints({
    fields: {
      institutionName: "San Rafael National High School",
      registrationNumber: "DEPED-1234",
    },
    application,
    docType: "deped_permit",
    readable: true,
    embeddedInstructions: false,
  });
  assert.equal(hints.filter((h) => h.includes("does not obviously match")).length, 0);
});

test("a different institution name is raised as something to check, not a verdict", () => {
  const hints = buildReviewHints({
    fields: { institutionName: "Quezon City Science High School", registrationNumber: "X" },
    application,
    docType: "deped_permit",
    readable: true,
    embeddedInstructions: false,
  });
  const hint = hints.find((h) => h.includes("does not obviously match"));
  assert.ok(hint, "expected a name hint");
  // The wording must stay a prompt to look, never a judgement.
  assert.ok(/check the document/i.test(hint));
  assert.ok(!/fake|invalid|fraud|reject/i.test(hint));
});

test("an unreadable scan says so and says it is not grounds to reject", () => {
  const hints = buildReviewHints({
    fields: {},
    application,
    docType: "deped_permit",
    readable: false,
    embeddedInstructions: false,
  });
  assert.ok(hints.some((h) => /not a reason to reject/i.test(h)));
});

test("embedded instructions are surfaced as a warning, not obeyed", () => {
  const hints = buildReviewHints({
    fields: { institutionName: "San Rafael National High School" },
    application,
    docType: "deped_permit",
    readable: true,
    embeddedInstructions: true,
  });
  assert.ok(hints.some((h) => /addressed to an automated reader/i.test(h)));
});

test("an expired printed validity date is flagged", () => {
  const hints = buildReviewHints({
    fields: {
      institutionName: "San Rafael National High School",
      registrationNumber: "A",
      validUntil: "2020-01-01",
    },
    application,
    docType: "deped_permit",
    readable: true,
    embeddedInstructions: false,
  });
  assert.ok(hints.some((h) => h.includes("2020-01-01")));
});

test("an ambiguous validity date is not flagged as expired", () => {
  const hints = buildReviewHints({
    fields: {
      institutionName: "San Rafael National High School",
      registrationNumber: "A",
      validUntil: "January 2020",
    },
    application,
    docType: "deped_permit",
    readable: true,
    embeddedInstructions: false,
  });
  assert.equal(hints.filter((h) => /validity date/i.test(h)).length, 0);
});

test("a document filed under the wrong agency is flagged", () => {
  const hints = buildReviewHints({
    fields: {
      institutionName: "San Rafael National High School",
      registrationNumber: "A",
      issuingAgency: "TESDA",
    },
    application,
    docType: "sec_registration",
    readable: true,
    embeddedInstructions: false,
  });
  assert.ok(hints.some((h) => /right kind/i.test(h)));
});

// ─── Pricing ──────────────────────────────────────────────────────────────────

test("plan prices match the published rates", () => {
  assert.equal(monthlyPriceFor(TIERS.starter, "monthly"), 1000);
  assert.equal(monthlyPriceFor(TIERS.growth, "monthly"), 2000);
  assert.equal(monthlyPriceFor(TIERS.professional, "monthly"), 3000);
  assert.equal(monthlyPriceFor(TIERS.scale, "monthly"), 5000);
  // Campus carries its own volume rate.
  assert.equal(monthlyPriceFor(TIERS.campus, "monthly"), 8000);
  // Enterprise is quoted by hand.
  assert.equal(monthlyPriceFor(TIERS.enterprise, "monthly"), 0);
});

test("the annual cycle applies the 20 percent discount", () => {
  assert.equal(monthlyPriceFor(TIERS.starter, "annual"), 800);
  assert.equal(monthlyPriceFor(TIERS.campus, "annual"), 6400);
});

// ─── The order of the location checks ─────────────────────────────────────────
//
// The scenario these exist for: a student's phone dies at destination 2 and the
// group moves on to destination 3. Their saved position still sits at
// destination 2. Measured against destination 3 it is far away — but that is
// not evidence of absence, and must never be reported as "not in the vicinity".

const { evaluateStudentLocation } = require("../lib/attendance");

const CONFIG = {
  locationMaxAgeSeconds: 120,
  maxAccuracyMeters: 100,
  geofenceSlackMeters: 25,
};

const NOW = Date.UTC(2026, 8, 23, 4, 0, 0);
const ts = (ms) => ({ toMillis: () => ms });
const secondsAgo = (s) => ts(NOW - s * 1000);

// Destination 2 and destination 3, about 1.1 km apart.
const DEST_2 = { lat: 14.9000, lng: 120.9000, name: "Museum" };
const DEST_3 = { lat: 14.9100, lng: 120.9000, name: "Park" };

test("a dead phone left behind at destination 2 is unverifiable, not absent", () => {
  const result = evaluateStudentLocation({
    // Last fix: at destination 2, forty minutes ago, when the battery died.
    loc: { lat: DEST_2.lat, lng: DEST_2.lng, accuracy: 12, observedAt: secondsAgo(2400) },
    stop: DEST_3,
    radius: 100,
    config: CONFIG,
    now: NOW,
  });

  assert.equal(result.verdict, "unverifiable");
  assert.equal(result.reason, "stale");
  // The distance is deliberately not computed: reporting one would invite the
  // facilitator to read a stale fix as a location.
  assert.equal(result.distanceM, null);
  assert.equal(result.ageSeconds, 2400);
});

test("a fresh fix far from the stop really is outside", () => {
  const result = evaluateStudentLocation({
    loc: { lat: DEST_2.lat, lng: DEST_2.lng, accuracy: 12, observedAt: secondsAgo(20) },
    stop: DEST_3,
    radius: 100,
    config: CONFIG,
    now: NOW,
  });
  assert.equal(result.verdict, "outside");
  assert.ok(result.distanceM > 1000);
});

test("a fresh fix at the stop is inside", () => {
  const result = evaluateStudentLocation({
    loc: { lat: 14.91005, lng: 120.90005, accuracy: 10, observedAt: secondsAgo(5) },
    stop: DEST_3,
    radius: 100,
    config: CONFIG,
    now: NOW,
  });
  assert.equal(result.verdict, "inside");
});

test("accuracy widens the zone rather than failing an honest fix at the edge", () => {
  // 110 m out, with a 60 m accuracy circle, against a 100 m zone.
  const result = evaluateStudentLocation({
    loc: { lat: 14.9110, lng: 120.9000, accuracy: 60, observedAt: secondsAgo(5) },
    stop: DEST_3,
    radius: 100,
    config: CONFIG,
    now: NOW,
  });
  assert.equal(result.verdict, "inside");
});

test("a mocked location is refused before any distance is considered", () => {
  const result = evaluateStudentLocation({
    loc: {
      lat: DEST_3.lat,
      lng: DEST_3.lng, // sitting exactly on the stop
      accuracy: 5,
      observedAt: secondsAgo(2),
      isMocked: true,
    },
    stop: DEST_3,
    radius: 100,
    config: CONFIG,
    now: NOW,
  });
  assert.equal(result.verdict, "unverifiable");
  assert.equal(result.reason, "mocked");
});

test("a device that never reported is unverifiable", () => {
  const result = evaluateStudentLocation({
    loc: null,
    stop: DEST_3,
    radius: 100,
    config: CONFIG,
    now: NOW,
  });
  assert.equal(result.verdict, "unverifiable");
  assert.equal(result.reason, "no_fix");
});

test("a fix too vague to compare is unverifiable, not outside", () => {
  const result = evaluateStudentLocation({
    loc: { lat: DEST_2.lat, lng: DEST_2.lng, accuracy: 3000, observedAt: secondsAgo(5) },
    stop: DEST_3,
    radius: 100,
    config: CONFIG,
    now: NOW,
  });
  assert.equal(result.verdict, "unverifiable");
  assert.equal(result.reason, "inaccurate");
});

test("a re-uploaded old fix stays stale — the write time does not refresh it", () => {
  const result = evaluateStudentLocation({
    loc: {
      lat: DEST_3.lat,
      lng: DEST_3.lng,
      accuracy: 8,
      observedAt: secondsAgo(900), // taken 15 minutes ago
      lastUpdate: secondsAgo(1),   // uploaded a second ago
    },
    stop: DEST_3,
    radius: 100,
    config: CONFIG,
    now: NOW,
  });
  assert.equal(result.verdict, "unverifiable");
  assert.equal(result.reason, "stale");
});

// ─── Who a facilitator may record ─────────────────────────────────────────────
//
// A Bus 1 teacher records Bus 1 students. Recording someone from another bus
// would put a name on a roster nobody on that bus checked, and would leave two
// facilitators' counts disagreeing about the same child.

const { requireOwnPassenger, teacherBusIndex } = require("../lib/attendance");

const TRIP = {
  buses: [
    {
      busLabel: "1",
      mainTeacher: { id: "teacher1" },
      passengers: [{ id: "ana", name: "Ana" }, { id: "ben", name: "Ben" }],
    },
    {
      busLabel: "2",
      mainTeacher: { id: "teacher2" },
      coTeacher: { id: "teacher3" },
      passengers: [{ id: "cara", name: "Cara" }],
    },
  ],
};

test("teacherBusIndex finds the bus a teacher runs", () => {
  assert.equal(teacherBusIndex(TRIP.buses, "teacher1"), 0);
  assert.equal(teacherBusIndex(TRIP.buses, "teacher2"), 1);
  // A co-teacher counts as a facilitator of that bus.
  assert.equal(teacherBusIndex(TRIP.buses, "teacher3"), 1);
  assert.equal(teacherBusIndex(TRIP.buses, "stranger"), -1);
});

test("a facilitator may record a student on their own bus", () => {
  const found = requireOwnPassenger(TRIP, 0, "ben");
  assert.equal(found.busIndex, 0);
  assert.equal(found.passenger.name, "Ben");
});

test("a facilitator may not record a student from another bus", () => {
  assert.throws(
    () => requireOwnPassenger(TRIP, 0, "cara"),
    (e) => {
      assert.equal(e.code, "permission-denied");
      // The refusal names the bus, so the facilitator knows who to hand it to
      // rather than being told only that they cannot.
      assert.match(e.message, /Bus 2/);
      assert.match(e.message, /own bus facilitator/i);
      return true;
    }
  );
});

test("a student who is not on the trip at all is a different refusal", () => {
  assert.throws(
    () => requireOwnPassenger(TRIP, 0, "nobody"),
    (e) => {
      assert.equal(e.code, "not-found");
      assert.match(e.message, /not assigned to this trip/i);
      return true;
    }
  );
});

test("a co-teacher on bus 2 may record bus 2 students", () => {
  const busIndex = teacherBusIndex(TRIP.buses, "teacher3");
  const found = requireOwnPassenger(TRIP, busIndex, "cara");
  assert.equal(found.passenger.name, "Cara");
});
