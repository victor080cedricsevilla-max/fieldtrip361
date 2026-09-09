import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../../config/theme.dart';
import '../../utils/school_context.dart';

/// Currency shown against every amount on this screen.
///
/// The platform bills Philippine schools, so the figures are pesos. Kept in one
/// place because a screen that mixes symbols reads as a pricing error, and this
/// screen quotes a monthly rate, a proration and a credit in three places each.
const _currency = '₱';

/// The capacity tiers a school can be on. Mirrors TIERS in functions/index.js.
class PlanTier {
  final String key;
  final String label;
  final int capacity; // 0 = custom / Enterprise
  const PlanTier(this.key, this.label, this.capacity);

  static const all = <PlanTier>[
    PlanTier('starter', 'Starter', 100),
    PlanTier('growth', 'Growth', 200),
    PlanTier('professional', 'Professional', 300),
    PlanTier('scale', 'Scale', 500),
    PlanTier('enterprise', 'Enterprise', 0),
  ];

  static PlanTier byKey(String? k) =>
      all.firstWhere((t) => t.key == k, orElse: () => all.first);

  String get capacityLabel =>
      capacity == 0 ? '1,000+ students' : 'Up to $capacity students';
}

const _ratePerStudent = 1;
const _annualDiscount = 0.20;
const _billingPeriodDays = 30;

int monthlyPriceFor(PlanTier tier, String billingCycle) {
  if (tier.capacity == 0) return 0;
  final base = tier.capacity * _ratePerStudent;
  return (base * (billingCycle == 'annual' ? 1 - _annualDiscount : 1)).round();
}

/// Current plan, usage, and the upgrade/downgrade flow.
///
/// The prorated figures shown here are a preview computed with the same formula
/// the server uses; `changeSubscriptionPlan` recalculates authoritatively before
/// committing, so a stale clock can never change what is actually recorded.
class SubscriptionSection extends StatefulWidget {
  const SubscriptionSection({super.key});

  @override
  State<SubscriptionSection> createState() => _SubscriptionSectionState();
}

class _SubscriptionSectionState extends State<SubscriptionSection> {
  String? _schoolId;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = await SchoolContext.schoolId();
    if (!mounted) return;
    setState(() {
      _schoolId = id;
      _loading = false;
    });
  }

  int _daysRemaining(Map<String, dynamic> school) {
    final anchor = school['currentPeriodStart'] ??
        school['planChangedAt'] ??
        school['createdAt'];
    if (anchor is! Timestamp) return _billingPeriodDays;
    final elapsed = DateTime.now().difference(anchor.toDate()).inDays;
    return (_billingPeriodDays - elapsed).clamp(0, _billingPeriodDays);
  }

  Future<void> _changePlan(PlanTier tier, String billingCycle) async {
    setState(() => _busy = true);
    try {
      final res = await FirebaseFunctions.instance
          .httpsCallable('changeSubscriptionPlan')
          .call(<String, dynamic>{'tier': tier.key, 'billingCycle': billingCycle});
      final d = Map<String, dynamic>.from(res.data as Map);
      if (!mounted) return;

      final due = (d['amountDueNow'] as num?)?.toInt() ?? 0;
      final credit = (d['creditCarried'] as num?)?.toInt() ?? 0;
      _dialog(
        title: 'You are now on ${d['tierLabel']}',
        body: [
          if (tier.capacity == 0)
            'Our team will contact you to finalise your custom capacity.'
          else
            'Your capacity is now ${d['capacity']} students, effective immediately.',
          '',
          if (due > 0)
            'Prorated amount due: $_currency$due — this covers the upgrade for the '
                '${d['daysRemaining']} days left in your current period. Your next '
                'renewal is $_currency${d['newMonthly']}.'
          else if (credit > 0)
            'You have $_currency$credit of unused time credited to your next invoice. '
                'Your next renewal is $_currency${d['newMonthly']}.'
          else
            'Your next renewal is $_currency${d['newMonthly']}.',
          '',
          'Nothing has been charged — billing is not switched on yet.',
        ].join('\n'),
      );
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        _dialog(title: 'Could not change plan', body: e.message ?? 'Please try again.',
            isError: true);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _dialog({required String title, required String body, bool isError = false}) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(children: [
          Icon(isError ? Icons.error_outline_rounded : Icons.check_circle_rounded,
              color: isError ? AppTheme.errorColor : const Color(0xFF16A34A)),
          const SizedBox(width: 10),
          Expanded(child: Text(title, style: const TextStyle(fontSize: 16))),
        ]),
        content: SizedBox(
          width: 400,
          child: SingleChildScrollView(
            child: Text(body, style: const TextStyle(fontSize: 13, height: 1.55)),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

  // ── Plan picker ───────────────────────────────────────────────────────────

  Future<void> _openPlanPicker(Map<String, dynamic> school) async {
    final current = PlanTier.byKey(school['tier'] as String?);
    var cycle = (school['billingCycle'] ?? 'monthly').toString();
    final used = (school['studentCount'] as num?)?.toInt() ?? 0;
    final days = _daysRemaining(school);
    final oldMonthly = (school['priceMonthly'] as num?)?.toInt() ?? 0;

    final chosen = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
          titlePadding: const EdgeInsets.fromLTRB(22, 20, 22, 0),
          contentPadding: const EdgeInsets.fromLTRB(22, 14, 22, 0),
          title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Change your plan',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Text(
              'You pay only the difference for the $days '
              '${days == 1 ? "day" : "days"} left in this period.',
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600, height: 1.4),
            ),
          ]),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                // Monthly / annual switch
                Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF3F4F6),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(children: [
                    for (final c in const ['monthly', 'annual'])
                      Expanded(
                        child: GestureDetector(
                          onTap: () => setLocal(() => cycle = c),
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            decoration: BoxDecoration(
                              color: cycle == c ? Colors.white : Colors.transparent,
                              borderRadius: BorderRadius.circular(8),
                              boxShadow: cycle == c
                                  ? [BoxShadow(
                                      color: Colors.black.withValues(alpha: 0.06),
                                      blurRadius: 4)]
                                  : null,
                            ),
                            child: Text(
                              c == 'monthly' ? 'Monthly' : 'Annual — save 20%',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: cycle == c ? FontWeight.w700 : FontWeight.w500,
                                color: cycle == c
                                    ? AppTheme.secondaryColor
                                    : Colors.grey.shade600,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ]),
                ),
                const SizedBox(height: 16),
                for (final tier in PlanTier.all)
                  _planOption(
                    tier: tier,
                    cycle: cycle,
                    isCurrent: tier.key == current.key && cycle == school['billingCycle'],
                    used: used,
                    days: days,
                    oldMonthly: oldMonthly,
                    onPick: () => Navigator.pop(ctx, {'tier': tier, 'cycle': cycle}),
                  ),
              ]),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ],
        ),
      ),
    );

    if (chosen == null) return;
    await _changePlan(chosen['tier'] as PlanTier, chosen['cycle'] as String);
  }

  Widget _planOption({
    required PlanTier tier,
    required String cycle,
    required bool isCurrent,
    required int used,
    required int days,
    required int oldMonthly,
    required VoidCallback onPick,
  }) {
    final newMonthly = monthlyPriceFor(tier, cycle);
    final tooSmall = tier.capacity != 0 && tier.capacity < used;

    // Same formula the server applies; shown here only as a preview.
    final ratio = days / _billingPeriodDays;
    final difference = ((newMonthly - oldMonthly) * ratio).round();

    final String note;
    if (isCurrent) {
      note = 'Your current plan';
    } else if (tooSmall) {
      note = 'Too small — you have $used students registered';
    } else if (tier.capacity == 0) {
      note = 'Custom pricing — we will contact you';
    } else if (difference > 0) {
      note = '$_currency$difference now, then $_currency$newMonthly/mo';
    } else if (difference < 0) {
      note = '$_currency${-difference} credited, then $_currency$newMonthly/mo';
    } else {
      note = '$_currency$newMonthly/mo';
    }

    final disabled = isCurrent || tooSmall;

    return Opacity(
      opacity: disabled ? 0.55 : 1,
      child: Container(
        margin: const EdgeInsets.only(bottom: 9),
        decoration: BoxDecoration(
          color: isCurrent ? AppTheme.effectivePrimary.withValues(alpha: 0.06) : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isCurrent
                ? AppTheme.effectivePrimary.withValues(alpha: 0.4)
                : const Color(0xFFE5E7EB),
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: disabled ? null : onPick,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Text(tier.label,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700,
                            color: AppTheme.secondaryColor)),
                    const SizedBox(width: 8),
                    Text(tier.capacityLabel,
                        style: TextStyle(fontSize: 11.5, color: Colors.grey.shade600)),
                  ]),
                  const SizedBox(height: 3),
                  Text(note,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: tooSmall ? AppTheme.errorColor : Colors.grey.shade600,
                        fontWeight: difference > 0 && !disabled
                            ? FontWeight.w600
                            : FontWeight.normal,
                      )),
                ]),
              ),
              if (isCurrent)
                Icon(Icons.check_circle_rounded, size: 20, color: AppTheme.effectivePrimary)
              else if (!tooSmall)
                Icon(Icons.chevron_right_rounded, size: 22, color: Colors.grey.shade400),
            ]),
          ),
        ),
      ),
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: Center(child: SizedBox(
          width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
      );
    }
    if (_schoolId == null) {
      return Text(
        'This account is not linked to a school, so there is no subscription to show.',
        style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600, height: 1.5),
      );
    }

    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: SchoolContext.schoolStream(_schoolId),
      builder: (context, snap) {
        if (!snap.hasData) {
          return const Padding(
            padding: EdgeInsets.symmetric(vertical: 18),
            child: Center(child: SizedBox(
              width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))),
          );
        }
        final school = snap.data!.data() ?? const <String, dynamic>{};
        final tier = PlanTier.byKey(school['tier'] as String?);
        final capacity = (school['capacity'] as num?)?.toInt() ?? 0;
        final used = (school['studentCount'] as num?)?.toInt() ?? 0;
        final price = (school['priceMonthly'] as num?)?.toInt() ?? 0;
        final cycle = (school['billingCycle'] ?? 'monthly').toString();
        final days = _daysRemaining(school);
        final pending = (school['pendingProration'] as num?)?.toInt() ?? 0;
        final unlimited = capacity == 0;
        final ratio = unlimited ? 0.0 : (capacity == 0 ? 0.0 : (used / capacity).clamp(0.0, 1.0));
        final full = !unlimited && used >= capacity;

        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Plan headline
          Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text((school['name'] ?? 'Your school').toString(),
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.bold,
                        color: AppTheme.secondaryColor)),
                const SizedBox(height: 2),
                Text(
                  '${tier.label} · ${cycle == 'annual' ? 'billed annually' : 'billed monthly'}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ]),
            ),
            Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(unlimited ? 'Custom' : '$_currency$price',
                  style: TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold,
                      color: AppTheme.effectivePrimary)),
              if (!unlimited)
                Text('per month',
                    style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500)),
            ]),
          ]),
          const SizedBox(height: 16),

          // Capacity usage
          Row(children: [
            Text(unlimited ? '$used students' : '$used / $capacity students',
                style: TextStyle(
                    fontSize: 12.5, fontWeight: FontWeight.w600,
                    color: full ? AppTheme.errorColor : AppTheme.secondaryColor)),
            const Spacer(),
            if (!unlimited)
              Text(
                full ? 'Plan is full' : '${capacity - used} slots left',
                style: TextStyle(
                    fontSize: 11.5,
                    color: full ? AppTheme.errorColor : Colors.grey.shade600),
              ),
          ]),
          if (!unlimited) ...[
            const SizedBox(height: 7),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: ratio,
                minHeight: 7,
                backgroundColor: const Color(0xFFE5E7EB),
                valueColor: AlwaysStoppedAnimation(
                    full ? AppTheme.errorColor : AppTheme.effectivePrimary),
              ),
            ),
          ],
          const SizedBox(height: 14),

          // Renewal + any recorded proration
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFFF9FAFB),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFEFEFEF)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.event_repeat_rounded, size: 15, color: Colors.grey.shade500),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '$days ${days == 1 ? "day" : "days"} left in this billing period',
                    style: TextStyle(fontSize: 11.5, color: Colors.grey.shade700),
                  ),
                ),
              ]),
              if (pending > 0) ...[
                const SizedBox(height: 7),
                Row(children: [
                  Icon(Icons.receipt_long_rounded, size: 15, color: AppTheme.accentColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Prorated $_currency$pending recorded from your last plan change '
                      '(not charged — billing is not live yet).',
                      style: TextStyle(
                          fontSize: 11.5, color: Colors.orange.shade900, height: 1.4),
                    ),
                  ),
                ]),
              ],
            ]),
          ),
          const SizedBox(height: 14),

          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _busy ? null : () => _openPlanPicker(school),
              icon: _busy
                  ? const SizedBox(
                      width: 15, height: 15,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Icon(Icons.upgrade_rounded, size: 18),
              label: Text(_busy ? 'Working…' : 'Change plan'),
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 44),
                backgroundColor: AppTheme.effectivePrimary,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Upgrades apply immediately and you are only charged the difference for '
            'the rest of the period. Downgrades are blocked while more students are '
            'registered than the smaller plan allows.',
            style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500, height: 1.45),
          ),
        ]);
      },
    );
  }
}
