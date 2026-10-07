/**
 * PayMongo client for subscription payments — TEST MODE ONLY.
 *
 * A school pays through a PayMongo Checkout Session after its application is
 * approved. Nothing here trusts the browser: whether a session was paid is
 * always read back from PayMongo with the secret key, and webhooks are accepted
 * only with a valid test-mode signature.
 */
const crypto = require("crypto");
const axios = require("axios");
const { HttpsError } = require("firebase-functions/v2/https");

const { paymongoSecretKey, paymongoWebhookSecret } = require("./common");

const API = "https://api.paymongo.com/v1";

// GCash, Maya, cards and GrabPay all have test flows in PayMongo's sandbox.
const PAYMENT_METHODS = ["gcash", "paymaya", "card", "grab_pay"];

// PayMongo's smallest accepted amount is ₱20.
const MIN_CENTAVOS = 2000;

/** The configured secret key, or "" when PayMongo is not set up. */
function configuredKey() {
  return (paymongoSecretKey.value() || "").trim();
}

/**
 * The secret key for an API call. Refuses a live key outright: this build
 * collects test payments only, so a live key here is a configuration mistake
 * that would otherwise move real money.
 */
function requireTestKey() {
  const key = configuredKey();
  if (!key) {
    throw new HttpsError("failed-precondition", "PayMongo is not configured (PAYMONGO_SECRET_KEY is empty).");
  }
  if (!key.startsWith("sk_test_")) {
    throw new HttpsError(
      "failed-precondition",
      "Only a PayMongo TEST secret key (sk_test_…) is accepted in this build."
    );
  }
  return key;
}

/** True when a test key is configured, so approvals should collect payment. */
function isConfigured() {
  return configuredKey().startsWith("sk_test_");
}

async function api(method, path, data) {
  const key = requireTestKey();
  try {
    const res = await axios({
      method,
      url: `${API}${path}`,
      data,
      auth: { username: key, password: "" },
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      timeout: 20000,
    });
    return res.data;
  } catch (e) {
    const detail = e.response?.data?.errors?.map((x) => x.detail).join("; ") || e.message;
    throw new Error(`PayMongo ${method.toUpperCase()} ${path} failed: ${detail}`);
  }
}

/**
 * What the first payment covers: one month on a monthly plan, twelve months on
 * an annual one (the annual price already carries its discount).
 */
function chargeFor(plan) {
  const months = plan?.billingCycle === "annual" ? 12 : 1;
  const amount = Math.round(Number(plan?.priceMonthly || 0) * months);
  return { months, amount, centavos: amount * 100 };
}

/** Creates the hosted checkout page for an approved application. */
async function createCheckoutSession({ applicationId, application, successUrl, cancelUrl }) {
  const plan = application.plan || {};
  const charge = chargeFor(plan);
  if (charge.centavos < MIN_CENTAVOS) {
    throw new HttpsError("failed-precondition", "This plan has no amount to collect.");
  }
  const period = charge.months === 12 ? "12 months (annual)" : "1 month";

  const body = await api("post", "/checkout_sessions", {
    data: {
      attributes: {
        line_items: [
          {
            currency: "PHP",
            amount: charge.centavos,
            quantity: 1,
            name: `FieldTrip360 ${plan.tierLabel || "subscription"} plan`,
            description: `${application.schoolName} — ${period}`,
          },
        ],
        payment_method_types: PAYMENT_METHODS,
        description: `FieldTrip360 subscription for ${application.schoolName}`,
        reference_number: application.reference || applicationId,
        success_url: successUrl,
        cancel_url: cancelUrl,
        show_description: true,
        show_line_items: true,
        send_email_receipt: false,
        metadata: { applicationId, reference: String(application.reference || "") },
      },
    },
  });

  return {
    id: body.data.id,
    url: body.data.attributes.checkout_url,
    ...charge,
  };
}

async function retrieveCheckoutSession(id) {
  const body = await api("get", `/checkout_sessions/${encodeURIComponent(id)}`);
  return body.data;
}

/**
 * The successful payment on a checkout session, or null when it is unpaid.
 * Reads PayMongo's own record, never anything the browser reported.
 */
function paidPaymentFrom(session) {
  const attrs = session?.attributes || {};
  const payments = Array.isArray(attrs.payments) ? attrs.payments : [];
  const paid = payments.find((p) => p?.attributes?.status === "paid");
  if (!paid) return null;
  const pa = paid.attributes;
  return {
    paymentId: paid.id,
    centavos: Number(pa.amount || 0),
    method: pa.source?.type || attrs.payment_method_used || null,
    paidAtSeconds: Number(pa.paid_at || 0) || null,
    livemode: pa.livemode === true || attrs.livemode === true,
  };
}

/**
 * Checks a Paymongo-Signature header (`t=…,te=…,li=…`). The signature is
 * HMAC-SHA256 of `${t}.${rawBody}` keyed with the webhook secret; test-mode
 * events carry it in `te`. Live events (`li`) are refused in this build, and a
 * timestamp more than ten minutes away is treated as a replay.
 */
function verifyWebhookSignature(rawBody, header, { secret = paymongoWebhookSecret.value(), now = Date.now() } = {}) {
  if (!secret || !header || !rawBody) return false;
  const parts = Object.fromEntries(
    String(header)
      .split(",")
      .map((kv) => kv.trim().split("="))
      .filter((p) => p.length === 2)
  );
  const t = parts.t;
  const sig = parts.te;
  if (!t || !sig) return false;
  if (Math.abs(now / 1000 - Number(t)) > 600) return false;

  const expected = crypto
    .createHmac("sha256", secret)
    .update(`${t}.${Buffer.isBuffer(rawBody) ? rawBody.toString("utf8") : rawBody}`)
    .digest("hex");
  const a = Buffer.from(expected, "utf8");
  const b = Buffer.from(String(sig), "utf8");
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

module.exports = {
  isConfigured,
  chargeFor,
  createCheckoutSession,
  retrieveCheckoutSession,
  paidPaymentFrom,
  verifyWebhookSignature,
  MIN_CENTAVOS,
};
