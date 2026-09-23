/**
 * Subscription plans, shared by the application flow and the in-app plan
 * changes. Capacity is what a school buys; the rate is per student per month.
 */

const TIERS = {
  starter: { capacity: 100, label: "Starter" },
  growth: { capacity: 200, label: "Growth" },
  professional: { capacity: 300, label: "Professional" },
  scale: { capacity: 500, label: "Scale" },
  campus: { capacity: 1000, label: "Campus", rate: 8 },
  enterprise: { capacity: 0, label: "Enterprise" },
};

// PHP per student per month. Priced so that five mid-sized schools cover the
// platform's fixed costs and a maintainer; ₱1 covered neither.
const RATE_PER_STUDENT = 10;
const ANNUAL_DISCOUNT = 0.2;

/**
 * Monthly price for a tier. Enterprise (capacity 0) is quoted by hand, so it
 * prices at zero here rather than guessing.
 */
function monthlyPriceFor(tier, billingCycle) {
  if (!tier || tier.capacity === 0) return 0;
  const base = tier.capacity * (tier.rate || RATE_PER_STUDENT);
  return Math.round(base * (billingCycle === "annual" ? 1 - ANNUAL_DISCOUNT : 1));
}

module.exports = { TIERS, RATE_PER_STUDENT, ANNUAL_DISCOUNT, monthlyPriceFor };
