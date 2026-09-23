/**
 * Banking-day arithmetic in Asia/Manila.
 *
 * Applicants are told their application is reviewed "within 7 banking days"
 * and that processing may take "up to 14 calendar days". Those are two
 * different clocks, so they are computed separately and stored separately: the
 * banking-day target skips weekends and the configured holidays, the calendar
 * limit does not skip anything.
 *
 * Manila is UTC+8 with no daylight saving, which is why a fixed offset is
 * correct here and a timezone library is not needed.
 */

const MANILA_OFFSET_MS = 8 * 60 * 60 * 1000;
const DAY_MS = 24 * 60 * 60 * 1000;

/** The Manila calendar date of an instant, as "YYYY-MM-DD". */
function manilaDateString(date) {
  const shifted = new Date(date.getTime() + MANILA_OFFSET_MS);
  return shifted.toISOString().slice(0, 10);
}

/** Day of week in Manila: 0 = Sunday … 6 = Saturday. */
function manilaDayOfWeek(date) {
  return new Date(date.getTime() + MANILA_OFFSET_MS).getUTCDay();
}

function isWeekend(date) {
  const d = manilaDayOfWeek(date);
  return d === 0 || d === 6;
}

/**
 * True when banks are closed: a weekend, or a date in the configured holiday
 * list. Unparsable entries are ignored rather than throwing — a typo in the
 * calendar must not break every application's deadline.
 */
function isBankingHoliday(date, holidays) {
  if (isWeekend(date)) return true;
  if (!Array.isArray(holidays)) return false;
  return holidays.includes(manilaDateString(date));
}

/**
 * Adds `count` banking days to `from`, landing on 09:00 Manila of the target
 * day so the deadline reads as a date rather than an arbitrary minute.
 */
function addBankingDays(from, count, holidays) {
  let cursor = new Date(from.getTime());
  let remaining = Math.max(0, count);

  // Guard against a calendar that marks every day a holiday.
  let guard = 0;
  while (remaining > 0 && guard < 400) {
    cursor = new Date(cursor.getTime() + DAY_MS);
    guard++;
    if (!isBankingHoliday(cursor, holidays)) remaining--;
  }

  // Normalise to 09:00 Manila (01:00 UTC) on the resulting date.
  const dateStr = manilaDateString(cursor);
  return new Date(`${dateStr}T01:00:00.000Z`);
}

/** Adds plain calendar days; nothing is skipped. */
function addCalendarDays(from, count) {
  return new Date(from.getTime() + Math.max(0, count) * DAY_MS);
}

/**
 * The two deadlines for an application, measured from the moment its documents
 * became complete. The original submission time is kept separately by the
 * caller: asking for more documents restarts the review target, but it must not
 * erase when the school first applied.
 */
function reviewDeadlines(documentsCompletedAt, config) {
  const bankingTarget = Number(config?.bankingDayTarget ?? 7);
  const calendarLimit = Number(config?.calendarDayLimit ?? 14);
  const holidays = config?.holidays || [];
  return {
    reviewTargetAt: addBankingDays(documentsCompletedAt, bankingTarget, holidays),
    processingDeadlineAt: addCalendarDays(documentsCompletedAt, calendarLimit),
  };
}

module.exports = {
  MANILA_OFFSET_MS,
  manilaDateString,
  manilaDayOfWeek,
  isWeekend,
  isBankingHoliday,
  addBankingDays,
  addCalendarDays,
  reviewDeadlines,
};
