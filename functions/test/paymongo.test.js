/**
 * Unit tests for the PayMongo pieces that decide money: what is charged,
 * whether a checkout counts as paid, and which webhooks are believed.
 *
 *   node --test functions/test/
 */
const test = require("node:test");
const assert = require("node:assert/strict");
const crypto = require("crypto");

const { chargeFor, paidPaymentFrom, verifyWebhookSignature, MIN_CENTAVOS } = require("../lib/paymongo");
const { monthlyPriceFor, TIERS } = require("../lib/pricing");

// ─── What is charged ──────────────────────────────────────────────────────────

test("monthly plan charges one month", () => {
  const c = chargeFor({ billingCycle: "monthly", priceMonthly: monthlyPriceFor(TIERS.starter, "monthly") });
  assert.deepEqual(c, { months: 1, amount: 1000, centavos: 100000 });
});

test("annual plan charges twelve discounted months", () => {
  const c = chargeFor({ billingCycle: "annual", priceMonthly: monthlyPriceFor(TIERS.starter, "annual") });
  assert.deepEqual(c, { months: 12, amount: 9600, centavos: 960000 });
});

test("enterprise has nothing to charge, so it stays below PayMongo's minimum", () => {
  const c = chargeFor({ billingCycle: "monthly", priceMonthly: monthlyPriceFor(TIERS.enterprise, "monthly") });
  assert.ok(c.centavos < MIN_CENTAVOS);
});

// ─── Whether a checkout is paid ───────────────────────────────────────────────

test("a session with a paid payment is paid", () => {
  const p = paidPaymentFrom({
    attributes: {
      payments: [
        { id: "pay_1", attributes: { status: "paid", amount: 100000, paid_at: 1760000000, source: { type: "gcash" }, livemode: false } },
      ],
    },
  });
  assert.deepEqual(p, { paymentId: "pay_1", centavos: 100000, method: "gcash", paidAtSeconds: 1760000000, livemode: false });
});

test("a session without a paid payment is unpaid", () => {
  assert.equal(paidPaymentFrom({ attributes: { payments: [] } }), null);
  assert.equal(paidPaymentFrom({ attributes: { payments: [{ id: "pay_2", attributes: { status: "failed" } }] } }), null);
  assert.equal(paidPaymentFrom(null), null);
});

// ─── Which webhooks are believed ──────────────────────────────────────────────

const SECRET = "whsk_test_secret";
const BODY = JSON.stringify({ data: { id: "evt_1", attributes: { type: "checkout_session.payment.paid" } } });
const NOW = 1760000000000;
const sign = (t, body = BODY, secret = SECRET) =>
  crypto.createHmac("sha256", secret).update(`${t}.${body}`).digest("hex");

test("a correctly signed test-mode webhook is accepted", () => {
  const t = NOW / 1000;
  assert.equal(verifyWebhookSignature(BODY, `t=${t},te=${sign(t)},li=`, { secret: SECRET, now: NOW }), true);
  assert.equal(verifyWebhookSignature(Buffer.from(BODY), `t=${t},te=${sign(t)},li=`, { secret: SECRET, now: NOW }), true);
});

test("a tampered body, wrong secret, or live-only signature is refused", () => {
  const t = NOW / 1000;
  assert.equal(verifyWebhookSignature(BODY + " ", `t=${t},te=${sign(t)},li=`, { secret: SECRET, now: NOW }), false);
  assert.equal(verifyWebhookSignature(BODY, `t=${t},te=${sign(t, BODY, "other")},li=`, { secret: SECRET, now: NOW }), false);
  assert.equal(verifyWebhookSignature(BODY, `t=${t},te=,li=${sign(t)}`, { secret: SECRET, now: NOW }), false);
});

test("an old webhook is treated as a replay; a missing secret refuses everything", () => {
  const old = NOW / 1000 - 3600;
  assert.equal(verifyWebhookSignature(BODY, `t=${old},te=${sign(old)},li=`, { secret: SECRET, now: NOW }), false);
  const t = NOW / 1000;
  assert.equal(verifyWebhookSignature(BODY, `t=${t},te=${sign(t)},li=`, { secret: "", now: NOW }), false);
});
