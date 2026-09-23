/**
 * The emails an applicant receives, and the delivery bookkeeping behind them.
 *
 * Delivery is recorded on the application itself (queued → sent → failed) so
 * the console never claims an email was sent when the transport refused it,
 * and so a failed send can be retried without re-running the decision.
 */
const admin = require("firebase-admin");

const {
  escapeHtml,
  sendMail,
  emailShell,
  appBaseUrl,
  supportEmail,
  smtpUser,
} = require("./common");

const EMAIL_TYPE = {
  acknowledgement: "acknowledgement",
  documentsRequested: "documents_requested",
  approved: "approved",
  rejected: "rejected",
  credentials: "credentials",
};

function supportLine() {
  const addr = supportEmail.value() || smtpUser.value();
  return addr ? `If you have questions, reply to this email or write to ${addr}.` : "";
}

/**
 * The link back into the application.
 *
 * It carries the access key because the applicant never made a password — the
 * anonymous session that created the application lives in one browser, and this
 * email may well be opened on a different device.
 */
function statusUrl(applicationId, accessKey) {
  const base = (appBaseUrl.value() || "").replace(/\/+$/, "");
  const key = accessKey ? `&k=${encodeURIComponent(accessKey)}` : "";
  return `${base}/?app=${encodeURIComponent(applicationId)}${key}#/apply`;
}

function formatManilaDate(date) {
  if (!date) return "";
  const shifted = new Date(date.getTime() + 8 * 60 * 60 * 1000);
  return shifted.toISOString().slice(0, 10);
}

// ─── Templates ────────────────────────────────────────────────────────────────

/**
 * Acknowledgement of a submitted application.
 *
 * The turnaround sentence is fixed wording: it is the promise the platform
 * makes publicly, so it is not paraphrased per message.
 */
function acknowledgementEmail({ application, applicationId }) {
  const promise =
    "We have received your school subscription application. Our team aims to " +
    "review complete applications within 7 banking days. Processing may take up " +
    "to 14 calendar days. We will email you if additional documents are required " +
    "and once a decision has been made.";

  const url = statusUrl(applicationId, application.accessKey);
  const submitted = formatManilaDate(application.submittedAt?.toDate?.() || new Date());

  const text = [
    `Hello ${application.representative?.name || "there"},`,
    "",
    promise,
    "",
    `Application reference: ${application.reference}`,
    `School: ${application.schoolName}`,
    `Submitted: ${submitted}`,
    `Track your application: ${url}`,
    "",
    supportLine(),
  ].join("\n");

  const html = emailShell({
    heading: "We have your application",
    bodyHtml: `
      <p style="margin:0 0 20px;font-size:14px;line-height:1.7;color:#4B5563;">${escapeHtml(promise)}</p>
      <div style="background:#F9FAFB;border:1px solid #E5E7EB;border-radius:12px;padding:18px;margin-bottom:22px;">
        <div style="font-size:11px;font-weight:600;color:#6B7280;text-transform:uppercase;letter-spacing:.05em;">Reference</div>
        <div style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:16px;color:#1F2937;margin:4px 0 14px;">${escapeHtml(application.reference)}</div>
        <div style="font-size:11px;font-weight:600;color:#6B7280;text-transform:uppercase;letter-spacing:.05em;">School</div>
        <div style="font-size:14px;color:#1F2937;margin:4px 0 14px;">${escapeHtml(application.schoolName)}</div>
        <div style="font-size:11px;font-weight:600;color:#6B7280;text-transform:uppercase;letter-spacing:.05em;">Submitted</div>
        <div style="font-size:14px;color:#1F2937;margin-top:4px;">${escapeHtml(submitted)}</div>
      </div>
      <a href="${escapeHtml(url)}" style="display:inline-block;background:#00C4B4;color:#ffffff;text-decoration:none;padding:12px 22px;border-radius:10px;font-size:14px;font-weight:600;">Track your application</a>
      <p style="margin:22px 0 0;font-size:13px;line-height:1.7;color:#6B7280;">${escapeHtml(supportLine())}</p>`,
    footerHtml: "You are receiving this because a subscription application was submitted with this email address.",
  });

  return { subject: `We received your FieldTrip360 application (${application.reference})`, text, html };
}

function documentsRequestedEmail({ application, applicationId, reason, requestedDocTypes, docLabels }) {
  const url = statusUrl(applicationId, application.accessKey);
  const list = (requestedDocTypes || []).map((t) => docLabels[t] || t);

  const text = [
    `Hello ${application.representative?.name || "there"},`,
    "",
    `We reviewed your application ${application.reference} for ${application.schoolName} and need a few more documents before we can decide.`,
    "",
    "What we need:",
    ...list.map((l) => `  • ${l}`),
    "",
    `Why: ${reason}`,
    "",
    "Once you upload them, the 7-banking-day review target is re-counted from the day your documents are complete. Your original submission date does not change.",
    "",
    `Upload the documents: ${url}`,
    "",
    supportLine(),
  ].join("\n");

  const html = emailShell({
    heading: "We need a few more documents",
    bodyHtml: `
      <p style="margin:0 0 18px;font-size:14px;line-height:1.7;color:#4B5563;">
        We reviewed your application <strong>${escapeHtml(application.reference)}</strong> for
        ${escapeHtml(application.schoolName)} and need a few more documents before we can decide.
      </p>
      <div style="background:#FFFBEB;border:1px solid #FCD34D;border-radius:12px;padding:18px;margin-bottom:20px;">
        <div style="font-size:12px;font-weight:700;color:#92400E;margin-bottom:8px;">What we need</div>
        ${list.map((l) => `<div style="font-size:14px;color:#92400E;line-height:1.8;">• ${escapeHtml(l)}</div>`).join("")}
      </div>
      <p style="margin:0 0 18px;font-size:14px;line-height:1.7;color:#4B5563;"><strong>Why:</strong> ${escapeHtml(reason)}</p>
      <p style="margin:0 0 22px;font-size:13px;line-height:1.7;color:#6B7280;">
        Once you upload them, the 7-banking-day review target is re-counted from the day your
        documents are complete. Your original submission date does not change.
      </p>
      <a href="${escapeHtml(url)}" style="display:inline-block;background:#00C4B4;color:#ffffff;text-decoration:none;padding:12px 22px;border-radius:10px;font-size:14px;font-weight:600;">Upload the documents</a>
      <p style="margin:22px 0 0;font-size:13px;line-height:1.7;color:#6B7280;">${escapeHtml(supportLine())}</p>`,
  });

  return { subject: `Additional documents needed (${application.reference})`, text, html };
}

function rejectedEmail({ application, reason }) {
  const text = [
    `Hello ${application.representative?.name || "there"},`,
    "",
    `We have reviewed application ${application.reference} for ${application.schoolName} and are not able to approve it at this time.`,
    "",
    `Reason: ${reason}`,
    "",
    "No account has been created and no payment has been taken. If you believe this was decided in error, or if the situation changes, you are welcome to apply again.",
    "",
    supportLine(),
  ].join("\n");

  const html = emailShell({
    heading: "About your application",
    bodyHtml: `
      <p style="margin:0 0 18px;font-size:14px;line-height:1.7;color:#4B5563;">
        We have reviewed application <strong>${escapeHtml(application.reference)}</strong> for
        ${escapeHtml(application.schoolName)} and are not able to approve it at this time.
      </p>
      <div style="background:#FEF2F2;border:1px solid #FDA29B;border-radius:12px;padding:18px;margin-bottom:20px;">
        <div style="font-size:12px;font-weight:700;color:#B42318;margin-bottom:6px;">Reason</div>
        <div style="font-size:14px;color:#B42318;line-height:1.7;">${escapeHtml(reason)}</div>
      </div>
      <p style="margin:0 0 18px;font-size:13px;line-height:1.7;color:#6B7280;">
        No account has been created and no payment has been taken. If you believe this was decided
        in error, or if the situation changes, you are welcome to apply again.
      </p>
      <p style="margin:0;font-size:13px;line-height:1.7;color:#6B7280;">${escapeHtml(supportLine())}</p>`,
  });

  return { subject: `Decision on your FieldTrip360 application (${application.reference})`, text, html };
}

/**
 * Approval, credentials and the receipt in one message.
 *
 * The receipt is labelled as payment-bypassed test mode on its face — it must
 * never read as evidence that money changed hands.
 */
function approvalEmail({ application, adminEmail, tempPassword, receipt }) {
  const base = (appBaseUrl.value() || "").replace(/\/+$/, "");
  const loginUrl = `${base}/`;
  const plan = application.plan || {};
  const capacityLine =
    Number(plan.capacity) === 0
      ? `${plan.tierLabel} plan (custom capacity)`
      : `${plan.tierLabel} plan — up to ${plan.capacity} students`;

  const text = [
    `Congratulations — ${application.schoolName} is approved for FieldTrip360.`,
    "",
    `Sign in at: ${loginUrl}`,
    `Email: ${adminEmail}`,
    `Temporary password: ${tempPassword}`,
    "",
    "You will be asked to change this password the first time you sign in. Until you do, administration is locked.",
    "",
    "— Subscription acknowledgement receipt —",
    `Receipt number: ${receipt.number}`,
    `Plan: ${capacityLine}`,
    `Billing: ${receipt.billingCycle}`,
    `Amount: PHP ${receipt.amount} (NOT COLLECTED)`,
    "Payment status: BYPASSED — TEST MODE. No payment has been processed and no",
    "payment is due from this receipt. It records the activation only.",
    "",
    supportLine(),
  ].join("\n");

  const html = emailShell({
    heading: `${escapeHtml(application.schoolName)} is approved`,
    bodyHtml: `
      <p style="margin:0 0 20px;font-size:14px;line-height:1.7;color:#4B5563;">
        Your subscription is active. Sign in with the credentials below and change the
        temporary password — administration stays locked until you do.
      </p>
      <div style="background:#F9FAFB;border:1px solid #E5E7EB;border-radius:12px;padding:18px;margin-bottom:20px;">
        <div style="font-size:11px;font-weight:600;color:#6B7280;text-transform:uppercase;letter-spacing:.05em;">Email</div>
        <div style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:14px;color:#1F2937;margin:4px 0 14px;word-break:break-all;">${escapeHtml(adminEmail)}</div>
        <div style="font-size:11px;font-weight:600;color:#6B7280;text-transform:uppercase;letter-spacing:.05em;">Temporary password</div>
        <div style="font-family:ui-monospace,Menlo,Consolas,monospace;font-size:18px;font-weight:700;color:#00C4B4;margin-top:4px;letter-spacing:.5px;">${escapeHtml(tempPassword)}</div>
      </div>
      <a href="${escapeHtml(loginUrl)}" style="display:inline-block;background:#00C4B4;color:#ffffff;text-decoration:none;padding:12px 22px;border-radius:10px;font-size:14px;font-weight:600;">Sign in</a>

      <div style="margin-top:28px;border-top:1px solid #E5E7EB;padding-top:22px;">
        <div style="font-size:13px;font-weight:700;color:#1F2937;margin-bottom:12px;">Subscription acknowledgement receipt</div>
        <table style="width:100%;border-collapse:collapse;font-size:13px;color:#4B5563;">
          <tr><td style="padding:4px 0;">Receipt number</td><td style="padding:4px 0;text-align:right;font-family:ui-monospace,Menlo,Consolas,monospace;">${escapeHtml(receipt.number)}</td></tr>
          <tr><td style="padding:4px 0;">Plan</td><td style="padding:4px 0;text-align:right;">${escapeHtml(capacityLine)}</td></tr>
          <tr><td style="padding:4px 0;">Billing</td><td style="padding:4px 0;text-align:right;">${escapeHtml(receipt.billingCycle)}</td></tr>
          <tr><td style="padding:4px 0;">Amount</td><td style="padding:4px 0;text-align:right;">PHP ${escapeHtml(String(receipt.amount))}</td></tr>
        </table>
        <div style="margin-top:14px;background:#FFFBEB;border:1px solid #FCD34D;border-radius:10px;padding:14px;">
          <div style="font-size:12px;font-weight:700;color:#92400E;">PAYMENT BYPASSED — TEST MODE</div>
          <div style="font-size:12px;line-height:1.7;color:#92400E;margin-top:4px;">
            No payment has been processed and no payment is due from this receipt. It records
            the activation of your subscription only.
          </div>
        </div>
      </div>
      <p style="margin:22px 0 0;font-size:13px;line-height:1.7;color:#6B7280;">${escapeHtml(supportLine())}</p>`,
  });

  return { subject: `FieldTrip360 is ready for ${application.schoolName}`, text, html };
}

// ─── Delivery bookkeeping ─────────────────────────────────────────────────────

/**
 * Sends one application email and records the outcome on the application.
 *
 * Never throws: the caller's decision has already been committed, and a mail
 * outage must not roll it back. The return value says plainly whether the
 * message went out, and the console shows that rather than assuming success.
 */
async function sendApplicationEmail(db, { applicationRef, to, type, message }) {
  const now = admin.firestore.FieldValue.serverTimestamp();
  const record = (status, error) =>
    applicationRef
      .set(
        {
          emails: admin.firestore.FieldValue.arrayUnion({
            type,
            status,
            to,
            at: admin.firestore.Timestamp.now(),
            error: error || null,
          }),
          lastEmailAt: now,
        },
        { merge: true }
      )
      .catch((e) => console.error("email bookkeeping failed:", e?.message || e));

  try {
    await sendMail({ to, subject: message.subject, text: message.text, html: message.html });
    await record("sent");
    return { sent: true };
  } catch (e) {
    const error = String(e?.message || e).slice(0, 500);
    console.error(`application email (${type}) failed:`, error);
    await record("failed", error);
    return { sent: false, error };
  }
}

module.exports = {
  EMAIL_TYPE,
  acknowledgementEmail,
  documentsRequestedEmail,
  rejectedEmail,
  approvalEmail,
  sendApplicationEmail,
  statusUrl,
};
