/**
 * Primitives shared by every Cloud Functions module.
 *
 * Parameters live here rather than in index.js because `defineString` must be
 * called once per name for the whole codebase — a second definition of the same
 * parameter in another module is a deploy-time error.
 */
const { HttpsError } = require("firebase-functions/v2/https");
const { defineString } = require("firebase-functions/params");
const admin = require("firebase-admin");
const crypto = require("crypto");
const nodemailer = require("nodemailer");

if (!admin.apps.length) {
  admin.initializeApp();
}

// ─── Parameters ───────────────────────────────────────────────────────────────

const googleMapsKey = defineString("GOOGLE_MAPS_KEY");
const geminiApiKey = defineString("GEMINI_API_KEY");
// gemini-2.x has no free-tier quota on this project (limit: 0), so the default
// is a 3.x flash model.
const geminiModel = defineString("GEMINI_MODEL", { default: "gemini-3.6-flash" });
// A second model to fall back to when the first answers 503. "High demand"
// is a property of one model's capacity pool, not of the key, so the lighter
// variant is usually free when the popular one is not. Verified against this
// project's key: gemini-3.5-flash-lite, gemini-3.1-flash-lite,
// gemini-3-flash-preview. Never a 2.x — those return quota limit 0 here.
const geminiFallbackModel = defineString("GEMINI_MODEL_FALLBACK", { default: "gemini-3.5-flash-lite" });

// Outgoing mail. For Gmail, SMTP_PASS must be a 16-character App Password
// (myaccount.google.com/apppasswords), never the account's own password.
// Defaults are empty so deploys never block on an interactive prompt; when the
// credentials are missing sendMail throws and the caller decides what to say.
const smtpHost = defineString("SMTP_HOST", { default: "smtp.gmail.com" });
const smtpUser = defineString("SMTP_USER", { default: "" });
const smtpPass = defineString("SMTP_PASS", { default: "" });
const smtpFrom = defineString("SMTP_FROM", { default: "" });

// Outgoing SMS (Semaphore — semaphore.co). Optional: with no key configured the
// SMS branch is simply skipped and email remains the only channel.
const semaphoreKey = defineString("SEMAPHORE_API_KEY", { default: "" });
const semaphoreSender = defineString("SEMAPHORE_SENDER_NAME", { default: "" });

// Where a subscriber signs in, and who they contact about an application.
const appBaseUrl = defineString("APP_BASE_URL", { default: "https://fieldtrip360.vercel.app" });
const supportEmail = defineString("SUPPORT_EMAIL", { default: "" });

// Pepper for hashing guardian and staff invitation codes. Without it a leaked
// database of hashes could be attacked offline; with it, the attacker also
// needs this value, which never leaves the function environment.
const activationPepper = defineString("ACTIVATION_PEPPER", { default: "" });

// One-time shared secret for the very first super-admin bootstrap. Empty by
// default, which disables the endpoint entirely.
const superAdminSetupToken = defineString("SUPERADMIN_SETUP_TOKEN", { default: "" });

// ─── Input sanitization ───────────────────────────────────────────────────────

function sanitizeText(text, maxLen = 2000) {
  if (typeof text !== "string") return "";
  return text
    .replace(/\0/g, "")        // strip null bytes (prompt-injection vector)
    .replace(/[<>]/g, "")      // strip angle brackets (XSS vector)
    .trim()
    .substring(0, maxLen);
}

function normEmail(v) {
  return typeof v === "string" ? v.trim().toLowerCase() : "";
}

function normStudentNumber(v) {
  return typeof v === "string" ? v.trim().toUpperCase() : "";
}

function isValidEmail(v) {
  return /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(v);
}

/** Escapes text before it is interpolated into an HTML email body. */
function escapeHtml(value) {
  return String(value == null ? "" : value)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

// ─── Rate limiting ────────────────────────────────────────────────────────────
// Tracks per-user request timestamps in _rateLimits/{uid}_{action}.

async function checkRateLimit(uid, action, maxReqs = 30) {
  const db = admin.firestore();
  const ref = db.collection("_rateLimits").doc(`${uid}_${action}`);
  const now = Date.now();
  const windowStart = now - 60_000;

  await db.runTransaction(async (tx) => {
    const doc = await tx.get(ref);
    const prev = doc.exists ? (doc.data().timestamps || []) : [];
    const inWindow = prev.filter((t) => t > windowStart);
    if (inWindow.length >= maxReqs) {
      throw new HttpsError("resource-exhausted", "Too many requests. Please wait a moment.");
    }
    tx.set(ref, { timestamps: [...inWindow, now] });
  });
}

// ─── Mail ─────────────────────────────────────────────────────────────────────

/**
 * Builds an SMTP transport. Pooled, so a bulk send reuses connections instead
 * of completing a TLS handshake for every message.
 */
function createMailTransport() {
  const user = smtpUser.value();
  const pass = smtpPass.value();
  if (!user || !pass) {
    throw new Error("SMTP is not configured (SMTP_USER / SMTP_PASS are unset).");
  }
  return nodemailer.createTransport({
    host: smtpHost.value() || "smtp.gmail.com",
    port: 465,
    secure: true,
    auth: { user, pass },
    pool: true,
    maxConnections: 3,
    maxMessages: 100,
  });
}

/**
 * Sends one email over SMTP. Throws when SMTP is unconfigured or the send fails,
 * so callers can decide what to tell the user — never swallow this silently.
 */
async function sendMail({ to, subject, text, html, transporter }) {
  const transport = transporter || createMailTransport();
  await transport.sendMail({
    from: smtpFrom.value() || `FieldTrip360 <${smtpUser.value()}>`,
    to,
    subject,
    text,
    html,
  });
}

/**
 * Wraps body HTML in the FieldTrip360 email shell so every message the platform
 * sends looks like it came from the same product.
 */
function emailShell({ heading, bodyHtml, footerHtml }) {
  return `
<div style="font-family:-apple-system,Segoe UI,Roboto,Helvetica,Arial,sans-serif;background:#f5f7f9;padding:32px 16px;">
  <div style="max-width:560px;margin:0 auto;background:#ffffff;border-radius:16px;overflow:hidden;box-shadow:0 2px 12px rgba(0,0,0,.06);">
    <div style="background:#00C4B4;padding:28px 32px;">
      <div style="color:#ffffff;font-size:20px;font-weight:700;letter-spacing:-.3px;">FieldTrip360</div>
      <div style="color:rgba(255,255,255,.85);font-size:13px;margin-top:4px;">Smart field trip management</div>
    </div>
    <div style="padding:32px;">
      <h1 style="margin:0 0 12px;font-size:19px;color:#1F2937;">${heading}</h1>
      ${bodyHtml}
    </div>
    <div style="padding:18px 32px;background:#F9FAFB;border-top:1px solid #E5E7EB;font-size:12px;color:#9CA3AF;">
      ${footerHtml || "This message was sent by FieldTrip360."}
    </div>
  </div>
</div>`;
}

// ─── Credentials ──────────────────────────────────────────────────────────────

function generateTempPassword() {
  const chars = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
  const bytes = crypto.randomBytes(14);
  let out = "";
  for (let i = 0; i < 12; i++) out += chars[bytes[i] % chars.length];
  return `${out}!${bytes[12] % 10}`;
}

// ─── Storage ──────────────────────────────────────────────────────────────────

/** Fetch an object from the default bucket as base64, with a hard size ceiling. */
async function storageObjectAsBase64(storagePath, maxBytes = 15 * 1024 * 1024) {
  const file = admin.storage().bucket().file(storagePath);
  const [metadata] = await file.getMetadata();
  const size = Number(metadata.size || 0);
  if (size > maxBytes) {
    throw new Error(`File too large for automatic review (${Math.round(size / 1048576)} MB).`);
  }
  const [buffer] = await file.download();
  return {
    data: buffer.toString("base64"),
    mimeType: metadata.contentType || "application/octet-stream",
  };
}

module.exports = {
  // params
  googleMapsKey,
  geminiApiKey,
  geminiModel,
  geminiFallbackModel,
  smtpHost,
  smtpUser,
  smtpPass,
  smtpFrom,
  semaphoreKey,
  semaphoreSender,
  appBaseUrl,
  supportEmail,
  superAdminSetupToken,
  activationPepper,
  // helpers
  sanitizeText,
  normEmail,
  normStudentNumber,
  isValidEmail,
  escapeHtml,
  checkRateLimit,
  createMailTransport,
  sendMail,
  emailShell,
  generateTempPassword,
  storageObjectAsBase64,
};
