import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../config/console_theme.dart';
import '../auth/brand_panel.dart';
import '../superadmin/super_admin_data.dart';
import '../superadmin/widgets/console_ui.dart';
import 'application_service.dart';

/// Applying for a school subscription.
///
/// Four steps, in the order the applicant can actually complete them: prove the
/// email address, describe the school, attach the documents that school type
/// requires, then submit. Nothing here creates an account with access — an
/// applicant remains an applicant until a reviewer decides.
class ApplyView extends StatefulWidget {
  const ApplyView({super.key});

  @override
  State<ApplyView> createState() => _ApplyViewState();
}

class _ApplyViewState extends State<ApplyView> {
  int _step = 0;

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final twoColumn = MediaQuery.sizeOf(context).width >= Breakpoints.loginStack;

    final content = StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, authSnap) {
        final user = authSnap.data ?? FirebaseAuth.instance.currentUser;
        if (user == null) {
          return _AccountStep(onDone: () => setState(() => _step = 1));
        }
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: ApplicationService.myApplications(),
          builder: (context, appSnap) {
            if (appSnap.hasError) {
              return ConsoleErrorState(
                title: 'Your application could not be loaded',
                message: 'Check your connection and try again.',
                technicalDetail: appSnap.error.toString(),
                onRetry: () => setState(() {}),
              );
            }
            if (!appSnap.hasData) {
              return const DelayedLoader(child: ConsoleSkeleton(rows: 3, rowHeight: 80));
            }

            final docs = appSnap.data!.docs;
            final live = docs.where((d) {
              final s = (d.data()['status'] ?? '').toString();
              return s != ApplicationStatus.rejected;
            }).toList();
            final current = live.isEmpty ? null : live.first;
            final status = current == null
                ? null
                : (current.data()['status'] ?? '').toString();

            // Once submitted there is nothing left to fill in — the applicant
            // sees where their application stands instead of an empty form.
            if (current != null &&
                status != ApplicationStatus.draft &&
                status != ApplicationStatus.needsMoreDocuments) {
              return _StatusPanel(applicationId: current.id, data: current.data());
            }

            return _ApplicationSteps(
              step: _step,
              onStep: (s) => setState(() => _step = s),
              application: current,
            );
          },
        );
      },
    );

    return Scaffold(
      backgroundColor: t.surface,
      body: twoColumn
          ? Row(
              children: [
                const Expanded(
                  flex: 4,
                  child: BrandPanel(
                    headline: 'Bring FieldTrip360\nto your school.',
                    supporting:
                        'Tell us about your institution and attach your verification '
                        'documents. A person reviews every application.',
                    points: [
                      'Reviewed within 7 banking days',
                      'Processing may take up to 14 calendar days',
                      'No student information is ever requested to verify a school',
                    ],
                  ),
                ),
                Expanded(
                  flex: 6,
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(Insets.xxxl),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 620),
                        child: content,
                      ),
                    ),
                  ),
                ),
              ],
            )
          : SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(Insets.lg),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 620),
                    child: content,
                  ),
                ),
              ),
            ),
    );
  }
}

// ─── Step 1: the account ──────────────────────────────────────────────────────

class _AccountStep extends StatefulWidget {
  final VoidCallback onDone;
  const _AccountStep({required this.onDone});

  @override
  State<_AccountStep> createState() => _AccountStepState();
}

class _AccountStepState extends State<_AccountStep> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _signingIn = false;
  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final email = _email.text.trim();
    if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$').hasMatch(email)) {
      setState(() => _error = 'Enter a valid email address.');
      return;
    }
    if (_password.text.length < 8) {
      setState(() => _error = 'Use at least 8 characters for your password.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_signingIn) {
        await ApplicationService.signIn(email: email, password: _password.text);
      } else {
        await ApplicationService.registerApplicant(
          email: email,
          password: _password.text,
        );
      }
      widget.onDone();
    } on FirebaseAuthException catch (e) {
      setState(() {
        _error = switch (e.code) {
          'email-already-in-use' =>
            'An account already uses that email. Switch to "I already started" to sign in.',
          'wrong-password' || 'invalid-credential' =>
            'Incorrect email or password.',
          'user-not-found' => 'No account found for that email.',
          'weak-password' => 'Choose a longer password.',
          _ => e.message ?? 'That did not work. Please try again.',
        };
      });
    } catch (e) {
      setState(() => _error = 'That did not work. Please try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Apply for a subscription',
          style: TextStyle(
            fontSize: FontSizes.display,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.9,
            height: 1.15,
            color: t.text,
          ),
        ),
        const SizedBox(height: Insets.sm),
        Text(
          'Start with the email address we should send the decision to. We will '
          'send a link to confirm it is yours.',
          style: TextStyle(fontSize: FontSizes.body, height: 1.55, color: t.textMuted),
        ),
        const SizedBox(height: Insets.xl),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('New application')),
            ButtonSegment(value: true, label: Text('I already started')),
          ],
          selected: {_signingIn},
          onSelectionChanged: (s) => setState(() {
            _signingIn = s.first;
            _error = null;
          }),
        ),
        const SizedBox(height: Insets.xl),
        if (_error != null) ...[
          Semantics(
            liveRegion: true,
            child: Container(
              padding: const EdgeInsets.all(Insets.md),
              decoration: BoxDecoration(
                color: t.danger.bg,
                border: Border.all(color: t.danger.border),
                borderRadius: Radii.control,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline_rounded, size: 18, color: t.danger.fg),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(fontSize: FontSizes.body, color: t.danger.fg),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: Insets.lg),
        ],
        ConsoleField(
          label: 'Work email address',
          required: true,
          helper: 'Use an address at the school where possible.',
          child: TextField(
            controller: _email,
            keyboardType: TextInputType.emailAddress,
            autofillHints: const [AutofillHints.email],
            decoration: const InputDecoration(hintText: 'registrar@school.edu.ph'),
          ),
        ),
        const SizedBox(height: Insets.lg),
        ConsoleField(
          label: 'Password',
          required: true,
          helper: _signingIn ? null : 'At least 8 characters.',
          child: TextField(
            controller: _password,
            obscureText: _obscure,
            autofillHints: [
              _signingIn ? AutofillHints.password : AutofillHints.newPassword,
            ],
            onSubmitted: (_) => _submit(),
            decoration: InputDecoration(
              hintText: 'Password',
              suffixIcon: IconButton(
                icon: Icon(_obscure
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined),
                tooltip: _obscure ? 'Show password' : 'Hide password',
                onPressed: () => setState(() => _obscure = !_obscure),
              ),
            ),
          ),
        ),
        const SizedBox(height: Insets.xl),
        ConsoleButton(
          label: _signingIn ? 'Continue' : 'Create account & continue',
          icon: Icons.arrow_forward_rounded,
          busy: _busy,
          onPressed: _busy ? null : _submit,
        ),
      ],
    );
  }
}

// ─── Steps 2–4 ────────────────────────────────────────────────────────────────

class _ApplicationSteps extends StatefulWidget {
  final int step;
  final ValueChanged<int> onStep;
  final QueryDocumentSnapshot<Map<String, dynamic>>? application;

  const _ApplicationSteps({
    required this.step,
    required this.onStep,
    required this.application,
  });

  @override
  State<_ApplicationSteps> createState() => _ApplicationStepsState();
}

class _ApplicationStepsState extends State<_ApplicationSteps> {
  final _schoolName = TextEditingController();
  final _legalName = TextEditingController();
  final _address = TextEditingController();
  final _repName = TextEditingController();
  final _repPosition = TextEditingController();
  final _repPhone = TextEditingController();

  String _institutionType = InstitutionType.privateIncorporated;
  String _tier = 'starter';
  String _billingCycle = 'monthly';

  bool _verified = false;
  bool _checkingVerification = false;
  bool _busy = false;
  String? _error;
  String? _applicationId;
  Map<String, dynamic>? _submitResult;

  @override
  void initState() {
    super.initState();
    _hydrate();
    _checkVerification();
  }

  @override
  void didUpdateWidget(covariant _ApplicationSteps oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.application?.id != widget.application?.id) _hydrate();
  }

  void _hydrate() {
    final d = widget.application?.data();
    if (d == null) return;
    _applicationId = widget.application!.id;
    _schoolName.text = (d['schoolName'] ?? '').toString();
    _legalName.text = (d['legalName'] ?? '').toString();
    _address.text = (d['address'] ?? '').toString();
    final rep = (d['representative'] ?? const {}) as Map;
    _repName.text = (rep['name'] ?? '').toString();
    _repPosition.text = (rep['position'] ?? '').toString();
    _repPhone.text = (rep['phone'] ?? '').toString();
    _institutionType = (d['institutionType'] ?? _institutionType).toString();
    final plan = (d['plan'] ?? const {}) as Map;
    _tier = (plan['tier'] ?? _tier).toString();
    _billingCycle = (plan['billingCycle'] ?? _billingCycle).toString();
  }

  @override
  void dispose() {
    _schoolName.dispose();
    _legalName.dispose();
    _address.dispose();
    _repName.dispose();
    _repPosition.dispose();
    _repPhone.dispose();
    super.dispose();
  }

  Future<void> _checkVerification() async {
    setState(() => _checkingVerification = true);
    final ok = await ApplicationService.refreshEmailVerified();
    if (mounted) {
      setState(() {
        _verified = ok;
        _checkingVerification = false;
      });
    }
  }

  Future<void> _saveDetails() async {
    if (_schoolName.text.trim().length < 2) {
      setState(() => _error = 'Enter the school\'s name.');
      return;
    }
    if (_repName.text.trim().isEmpty) {
      setState(() => _error = 'Enter the authorized representative\'s name.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await ApplicationService.saveApplication(
        schoolName: _schoolName.text.trim(),
        legalName: _legalName.text.trim().isEmpty
            ? _schoolName.text.trim()
            : _legalName.text.trim(),
        institutionType: _institutionType,
        address: _address.text.trim(),
        repName: _repName.text.trim(),
        repPosition: _repPosition.text.trim(),
        repEmail: FirebaseAuth.instance.currentUser?.email ?? '',
        repPhone: _repPhone.text.trim(),
        tier: _tier,
        billingCycle: _billingCycle,
      );
      if (mounted) {
        setState(() => _applicationId = res['applicationId']?.toString());
        widget.onStep(2);
      }
    } catch (e) {
      if (mounted) setState(() => _error = _friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    final id = _applicationId;
    if (id == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await ApplicationService.submit(id);
      if (mounted) setState(() => _submitResult = res);
    } catch (e) {
      if (mounted) setState(() => _error = _friendly(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendly(Object e) {
    final s = e.toString();
    final match = RegExp(r'\[firebase_functions/[a-z-]+\]\s*(.+)$').firstMatch(s);
    if (match != null) return match.group(1)!;
    return 'That did not work. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);

    if (_submitResult != null) {
      return _SubmittedPanel(result: _submitResult!);
    }

    if (!_verified) {
      return _VerifyEmailPanel(
        email: FirebaseAuth.instance.currentUser?.email ?? '',
        checking: _checkingVerification,
        onCheck: _checkVerification,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _StepIndicator(current: widget.step),
        const SizedBox(height: Insets.xl),
        if (_error != null) ...[
          Semantics(
            liveRegion: true,
            child: Container(
              padding: const EdgeInsets.all(Insets.md),
              decoration: BoxDecoration(
                color: t.danger.bg,
                border: Border.all(color: t.danger.border),
                borderRadius: Radii.control,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.error_outline_rounded, size: 18, color: t.danger.fg),
                  const SizedBox(width: Insets.sm),
                  Expanded(
                    child: Text(
                      _error!,
                      style: TextStyle(fontSize: FontSizes.body, color: t.danger.fg),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: Insets.lg),
        ],
        if (widget.step <= 1) _detailsForm(t) else _documentsStep(t),
      ],
    );
  }

  Widget _detailsForm(ConsoleTokens t) {
    final requested = ((widget.application?.data()['requestedDocTypes'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (requested.isNotEmpty) ...[
          _RequestedDocsBanner(types: requested),
          const SizedBox(height: Insets.lg),
        ],
        Text(
          'About your school',
          style: TextStyle(
            fontSize: FontSizes.heading,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
            color: t.text,
          ),
        ),
        const SizedBox(height: Insets.xl),
        ConsoleField(
          label: 'School name',
          required: true,
          helper: 'As people normally write it.',
          child: TextField(
            controller: _schoolName,
            decoration: const InputDecoration(hintText: 'e.g. San Rafael National High School'),
          ),
        ),
        const SizedBox(height: Insets.lg),
        ConsoleField(
          label: 'Registered legal name',
          helper: 'Leave blank if it is the same as above.',
          child: TextField(
            controller: _legalName,
            decoration: const InputDecoration(hintText: 'As printed on your registration'),
          ),
        ),
        const SizedBox(height: Insets.lg),
        ConsoleField(
          label: 'Kind of institution',
          required: true,
          helper: 'This decides which documents we ask for — a public school is '
              'never asked for an SEC registration.',
          child: DropdownMenu<String>(
            initialSelection: _institutionType,
            expandedInsets: EdgeInsets.zero,
            onSelected: (v) => setState(() => _institutionType = v ?? _institutionType),
            dropdownMenuEntries: InstitutionType.all
                .map((v) => DropdownMenuEntry(value: v, label: InstitutionType.label(v)))
                .toList(),
          ),
        ),
        const SizedBox(height: Insets.lg),
        ConsoleField(
          label: 'School address',
          child: TextField(
            controller: _address,
            minLines: 2,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'Street, barangay, city, province'),
          ),
        ),
        const SizedBox(height: Insets.xl),
        Text(
          'Authorized representative',
          style: TextStyle(
            fontSize: FontSizes.bodyLg,
            fontWeight: FontWeight.w600,
            color: t.text,
          ),
        ),
        const SizedBox(height: Insets.md),
        ConsoleField(
          label: 'Full name',
          required: true,
          child: TextField(controller: _repName),
        ),
        const SizedBox(height: Insets.lg),
        ConsoleField(
          label: 'Position',
          child: TextField(
            controller: _repPosition,
            decoration: const InputDecoration(hintText: 'e.g. Principal, Registrar'),
          ),
        ),
        const SizedBox(height: Insets.lg),
        ConsoleField(
          label: 'Contact number',
          child: TextField(
            controller: _repPhone,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(hintText: '09xx xxx xxxx'),
          ),
        ),
        const SizedBox(height: Insets.xl),
        Text(
          'Plan',
          style: TextStyle(
            fontSize: FontSizes.bodyLg,
            fontWeight: FontWeight.w600,
            color: t.text,
          ),
        ),
        const SizedBox(height: Insets.md),
        _PlanPicker(
          tier: _tier,
          billingCycle: _billingCycle,
          onTier: (v) => setState(() => _tier = v),
          onCycle: (v) => setState(() => _billingCycle = v),
        ),
        const SizedBox(height: Insets.xl),
        ConsoleButton(
          label: 'Save and choose documents',
          icon: Icons.arrow_forward_rounded,
          busy: _busy,
          onPressed: _busy ? null : _saveDetails,
        ),
      ],
    );
  }

  Widget _documentsStep(ConsoleTokens t) {
    final id = _applicationId;
    if (id == null) {
      return ConsoleEmptyState(
        icon: Icons.assignment_outlined,
        title: 'Fill in your school details first',
        message: 'We use the kind of institution to decide which documents to ask for.',
        action: ConsoleButton(
          label: 'Back to details',
          kind: ConsoleButtonKind.secondary,
          onPressed: () => widget.onStep(1),
        ),
      );
    }

    return _DocumentsStep(
      applicationId: id,
      application: widget.application!.data(),
      busy: _busy,
      onBack: () => widget.onStep(1),
      onSubmit: _submit,
    );
  }
}

class _StepIndicator extends StatelessWidget {
  final int current;
  const _StepIndicator({required this.current});

  static const _labels = ['Account', 'School details', 'Documents'];

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final index = current.clamp(0, 2);
    return Row(
      children: List.generate(_labels.length, (i) {
        final done = i < index;
        final active = i == index;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: i == _labels.length - 1 ? 0 : Insets.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: done || active ? t.brand : t.border,
                    borderRadius: BorderRadius.circular(999),
                  ),
                ),
                const SizedBox(height: Insets.sm),
                Text(
                  '${i + 1}. ${_labels[i]}',
                  style: TextStyle(
                    fontSize: FontSizes.caption,
                    fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    color: active ? t.text : t.textMuted,
                  ),
                ),
              ],
            ),
          ),
        );
      }),
    );
  }
}

class _VerifyEmailPanel extends StatelessWidget {
  final String email;
  final bool checking;
  final VoidCallback onCheck;

  const _VerifyEmailPanel({
    required this.email,
    required this.checking,
    required this.onCheck,
  });

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    return ConsoleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.mark_email_unread_outlined, size: 30, color: t.brand),
          const SizedBox(height: Insets.md),
          Text(
            'Confirm your email address',
            style: TextStyle(
              fontSize: FontSizes.title,
              fontWeight: FontWeight.w700,
              color: t.text,
            ),
          ),
          const SizedBox(height: Insets.sm),
          Text(
            'We sent a link to $email. Open it, then come back to this page and '
            'continue. We verify the address because every decision on your '
            'application is sent there.',
            style: TextStyle(fontSize: FontSizes.body, height: 1.6, color: t.textMuted),
          ),
          const SizedBox(height: Insets.xl),
          Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.sm,
            children: [
              ConsoleButton(
                label: 'I have confirmed it',
                icon: Icons.refresh_rounded,
                busy: checking,
                onPressed: checking ? null : onCheck,
              ),
              ConsoleButton(
                label: 'Send the link again',
                icon: Icons.send_rounded,
                kind: ConsoleButtonKind.secondary,
                onPressed: () async {
                  await ApplicationService.resendVerification();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Verification email sent.')),
                    );
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _RequestedDocsBanner extends StatelessWidget {
  final List<String> types;
  const _RequestedDocsBanner({required this.types});

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    return Container(
      padding: const EdgeInsets.all(Insets.lg),
      decoration: BoxDecoration(
        color: t.warning.bg,
        border: Border.all(color: t.warning.border),
        borderRadius: Radii.control,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.upload_file_rounded, size: 18, color: t.warning.fg),
              const SizedBox(width: Insets.sm),
              Text(
                'We asked for more documents',
                style: TextStyle(
                  fontSize: FontSizes.body,
                  fontWeight: FontWeight.w700,
                  color: t.warning.fg,
                ),
              ),
            ],
          ),
          const SizedBox(height: Insets.sm),
          ...types.map((t2) => Text(
                '• ${ApplicationDocType.label(t2)}',
                style: TextStyle(
                  fontSize: FontSizes.body,
                  height: 1.7,
                  color: t.warning.fg,
                ),
              )),
          const SizedBox(height: Insets.sm),
          Text(
            'Upload them below and submit again. Your original submission date '
            'stays as it was.',
            style: TextStyle(
              fontSize: FontSizes.caption,
              height: 1.55,
              color: t.warning.fg,
            ),
          ),
        ],
      ),
    );
  }
}

class _PlanPicker extends StatelessWidget {
  final String tier;
  final String billingCycle;
  final ValueChanged<String> onTier;
  final ValueChanged<String> onCycle;

  const _PlanPicker({
    required this.tier,
    required this.billingCycle,
    required this.onTier,
    required this.onCycle,
  });

  // Mirrors functions/lib/pricing.js. Shown so the applicant knows what they
  // are asking for; the server prices the plan itself on save.
  static const _tiers = [
    ('starter', 'Starter', 100, 1000),
    ('growth', 'Growth', 200, 2000),
    ('professional', 'Professional', 300, 3000),
    ('scale', 'Scale', 500, 5000),
    ('campus', 'Campus', 1000, 8000),
    ('enterprise', 'Enterprise', 0, 0),
  ];

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'monthly', label: Text('Monthly')),
            ButtonSegment(value: 'annual', label: Text('Annual (−20%)')),
          ],
          selected: {billingCycle},
          onSelectionChanged: (s) => onCycle(s.first),
        ),
        const SizedBox(height: Insets.md),
        ..._tiers.map((entry) {
          final (key, label, capacity, monthly) = entry;
          final selected = key == tier;
          final price = billingCycle == 'annual'
              ? (monthly * 12 * 0.8).round()
              : monthly;
          return Padding(
            padding: const EdgeInsets.only(bottom: Insets.sm),
            child: ConsoleCard(
              onTap: () => onTier(key),
              accent: selected ? t.brand : null,
              padding: const EdgeInsets.all(Insets.md),
              child: Row(
                children: [
                  Icon(
                    selected
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 20,
                    color: selected ? t.brand : t.textFaint,
                  ),
                  const SizedBox(width: Insets.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: TextStyle(
                            fontSize: FontSizes.body,
                            fontWeight: FontWeight.w600,
                            color: t.text,
                          ),
                        ),
                        Text(
                          capacity == 0
                              ? 'More than 1,000 students — we will quote you'
                              : 'Up to $capacity students',
                          style: TextStyle(
                            fontSize: FontSizes.caption,
                            color: t.textMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                  Text(
                    capacity == 0
                        ? 'Custom'
                        : '${formatPeso(price)}/${billingCycle == 'annual' ? 'yr' : 'mo'}',
                    style: TextStyle(
                      fontSize: FontSizes.body,
                      fontWeight: FontWeight.w700,
                      color: t.text,
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ],
    );
  }
}

class _DocumentsStep extends StatefulWidget {
  final String applicationId;
  final Map<String, dynamic> application;
  final bool busy;
  final VoidCallback onBack;
  final VoidCallback onSubmit;

  const _DocumentsStep({
    required this.applicationId,
    required this.application,
    required this.busy,
    required this.onBack,
    required this.onSubmit,
  });

  @override
  State<_DocumentsStep> createState() => _DocumentsStepState();
}

class _DocumentsStepState extends State<_DocumentsStep> {
  String? _uploadingType;
  double _progress = 0;
  String? _uploadError;

  Future<void> _pickAndUpload(String type) async {
    setState(() {
      _uploadError = null;
      _uploadingType = type;
      _progress = 0;
    });
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'],
        withData: true,
      );
      final file = picked?.files.firstOrNull;
      if (file == null || file.bytes == null) {
        setState(() => _uploadingType = null);
        return;
      }
      if (file.size > 10 * 1024 * 1024) {
        setState(() {
          _uploadError = 'That file is larger than 10 MB. Please upload a smaller scan.';
          _uploadingType = null;
        });
        return;
      }

      final ext = (file.extension ?? 'pdf').toLowerCase();
      final contentType = switch (ext) {
        'pdf' => 'application/pdf',
        'png' => 'image/png',
        _ => 'image/jpeg',
      };

      await ApplicationService.uploadDocument(
        applicationId: widget.applicationId,
        type: type,
        bytes: file.bytes!,
        fileName: file.name,
        contentType: contentType,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
    } catch (e) {
      if (mounted) {
        setState(() => _uploadError = 'The upload did not finish. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _uploadingType = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final required = ((widget.application['requestedDocTypes'] as List?) ??
            (widget.application['requiredDocTypes'] as List?) ??
            const [])
        .map((e) => e.toString())
        .toList();
    final optional = ((widget.application['optionalDocTypes'] as List?) ?? const [])
        .map((e) => e.toString())
        .where((e) => !required.contains(e))
        .toList();

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: ApplicationService.documents(widget.applicationId),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? const [];
        final live = docs.where((d) => d.data()['superseded'] != true).toList();
        final present = live.map((d) => (d.data()['type'] ?? '').toString()).toSet();
        final missing = required.where((r) => !present.contains(r)).toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Verification documents',
              style: TextStyle(
                fontSize: FontSizes.heading,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.4,
                color: t.text,
              ),
            ),
            const SizedBox(height: Insets.sm),
            Text(
              'PDF, JPG or PNG, up to 10 MB each. We never ask for student lists, '
              'student numbers, attendance or medical records to verify a school.',
              style: TextStyle(fontSize: FontSizes.body, height: 1.55, color: t.textMuted),
            ),
            const SizedBox(height: Insets.xl),
            if (_uploadError != null) ...[
              Semantics(
                liveRegion: true,
                child: Text(
                  _uploadError!,
                  style: TextStyle(fontSize: FontSizes.body, color: t.danger.fg),
                ),
              ),
              const SizedBox(height: Insets.md),
            ],
            Text(
              'Required',
              style: TextStyle(
                fontSize: FontSizes.body,
                fontWeight: FontWeight.w700,
                color: t.text,
              ),
            ),
            const SizedBox(height: Insets.sm),
            ...required.map((type) => _DocRow(
                  type: type,
                  uploaded: live.where((d) => d.data()['type'] == type).toList(),
                  uploading: _uploadingType == type,
                  progress: _progress,
                  onUpload: () => _pickAndUpload(type),
                  onRemove: (id) => ApplicationService.removeDocument(
                    applicationId: widget.applicationId,
                    documentId: id,
                  ),
                )),
            if (optional.isNotEmpty) ...[
              const SizedBox(height: Insets.lg),
              Text(
                'Optional — helpful if you have them',
                style: TextStyle(
                  fontSize: FontSizes.body,
                  fontWeight: FontWeight.w700,
                  color: t.text,
                ),
              ),
              const SizedBox(height: Insets.sm),
              ...optional.map((type) => _DocRow(
                    type: type,
                    uploaded: live.where((d) => d.data()['type'] == type).toList(),
                    uploading: _uploadingType == type,
                    progress: _progress,
                    onUpload: () => _pickAndUpload(type),
                    onRemove: (id) => ApplicationService.removeDocument(
                      applicationId: widget.applicationId,
                      documentId: id,
                    ),
                  )),
            ],
            const SizedBox(height: Insets.xl),
            if (missing.isNotEmpty)
              Container(
                padding: const EdgeInsets.all(Insets.md),
                decoration: BoxDecoration(
                  color: t.warning.bg,
                  border: Border.all(color: t.warning.border),
                  borderRadius: Radii.control,
                ),
                child: Text(
                  'Still to attach: ${missing.map(ApplicationDocType.label).join(', ')}.',
                  style: TextStyle(fontSize: FontSizes.body, color: t.warning.fg),
                ),
              ),
            const SizedBox(height: Insets.lg),
            Row(
              children: [
                ConsoleButton(
                  label: 'Back',
                  icon: Icons.arrow_back_rounded,
                  kind: ConsoleButtonKind.ghost,
                  onPressed: widget.onBack,
                ),
                const Spacer(),
                ConsoleButton(
                  label: 'Submit application',
                  icon: Icons.send_rounded,
                  busy: widget.busy,
                  onPressed: missing.isEmpty && !widget.busy ? widget.onSubmit : null,
                  disabledReason: missing.isEmpty
                      ? null
                      : 'Attach the required documents first',
                ),
              ],
            ),
          ],
        );
      },
    );
  }
}

class _DocRow extends StatelessWidget {
  final String type;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> uploaded;
  final bool uploading;
  final double progress;
  final VoidCallback onUpload;
  final Future<void> Function(String documentId) onRemove;

  const _DocRow({
    required this.type,
    required this.uploaded,
    required this.uploading,
    required this.progress,
    required this.onUpload,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final has = uploaded.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.sm),
      child: Container(
        padding: const EdgeInsets.all(Insets.md),
        decoration: BoxDecoration(
          color: t.surfaceMuted,
          border: Border.all(color: has ? t.success.border : t.border),
          borderRadius: Radii.control,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  has ? Icons.check_circle_rounded : Icons.upload_file_outlined,
                  size: 20,
                  color: has ? t.success.fg : t.textFaint,
                ),
                const SizedBox(width: Insets.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        ApplicationDocType.label(type),
                        style: TextStyle(
                          fontSize: FontSizes.body,
                          fontWeight: FontWeight.w600,
                          color: t.text,
                        ),
                      ),
                      Text(
                        ApplicationDocType.description(type),
                        style: TextStyle(
                          fontSize: FontSizes.caption,
                          height: 1.5,
                          color: t.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: Insets.md),
                ConsoleButton(
                  label: has ? 'Replace' : 'Upload',
                  icon: Icons.attach_file_rounded,
                  kind: ConsoleButtonKind.secondary,
                  busy: uploading,
                  onPressed: uploading ? null : onUpload,
                ),
              ],
            ),
            if (uploading) ...[
              const SizedBox(height: Insets.sm),
              ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: LinearProgressIndicator(
                  value: progress == 0 ? null : progress,
                  minHeight: 4,
                  backgroundColor: t.border,
                ),
              ),
            ],
            ...uploaded.map((d) {
              final data = d.data();
              return Padding(
                padding: const EdgeInsets.only(top: Insets.sm),
                child: Row(
                  children: [
                    Icon(Icons.description_outlined, size: 15, color: t.textFaint),
                    const SizedBox(width: Insets.sm),
                    Expanded(
                      child: Text(
                        (data['fileName'] ?? 'document').toString(),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: FontSizes.caption,
                          color: t.textMuted,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close_rounded, size: 16),
                      tooltip: 'Remove this file',
                      onPressed: () => onRemove(d.id),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

class _SubmittedPanel extends StatelessWidget {
  final Map<String, dynamic> result;
  const _SubmittedPanel({required this.result});

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final emailSent = result['emailSent'] == true;

    return ConsoleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.check_circle_rounded, size: 34, color: t.success.fg),
          const SizedBox(height: Insets.md),
          Text(
            'Application submitted',
            style: TextStyle(
              fontSize: FontSizes.heading,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
              color: t.text,
            ),
          ),
          const SizedBox(height: Insets.sm),
          Text(
            'Our team aims to review complete applications within 7 banking days. '
            'Processing may take up to 14 calendar days. We will email you if '
            'additional documents are required and once a decision has been made.',
            style: TextStyle(fontSize: FontSizes.body, height: 1.65, color: t.textMuted),
          ),
          const SizedBox(height: Insets.lg),
          Container(
            padding: const EdgeInsets.all(Insets.md),
            decoration: BoxDecoration(
              color: emailSent ? t.success.bg : t.warning.bg,
              border: Border.all(color: emailSent ? t.success.border : t.warning.border),
              borderRadius: Radii.control,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  emailSent ? Icons.mark_email_read_outlined : Icons.report_outlined,
                  size: 18,
                  color: emailSent ? t.success.fg : t.warning.fg,
                ),
                const SizedBox(width: Insets.sm),
                Expanded(
                  child: Text(
                    emailSent
                        ? 'A confirmation email is on its way with your reference number.'
                        : 'Your application is saved, but the confirmation email could not '
                            'be sent right now. Your application is unaffected — keep this '
                            'page open or sign in again to check its status.',
                    style: TextStyle(
                      fontSize: FontSizes.body,
                      height: 1.55,
                      color: emailSent ? t.success.fg : t.warning.fg,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// What an applicant sees once their application is with the reviewer.
class _StatusPanel extends StatelessWidget {
  final String applicationId;
  final Map<String, dynamic> data;

  const _StatusPanel({required this.applicationId, required this.data});

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final status = (data['status'] ?? '').toString();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ConsoleCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      (data['schoolName'] ?? 'Your application').toString(),
                      style: TextStyle(
                        fontSize: FontSizes.heading,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.4,
                        color: t.text,
                      ),
                    ),
                  ),
                  StatusBadge(
                    label: ApplicationStatus.label(status),
                    tone: ApplicationStatus.tone(t, status),
                    icon: ApplicationStatus.icon(status),
                  ),
                ],
              ),
              const SizedBox(height: Insets.xs),
              Text(
                'Reference ${data['reference'] ?? '—'}',
                style: TextStyle(fontSize: FontSizes.body, color: t.textMuted),
              ),
              const SizedBox(height: Insets.lg),
              Text(
                'Submitted ${formatTimestamp(data['submittedAt'], withTime: false)} · '
                'Review target ${formatTimestamp(data['reviewTargetAt'], withTime: false)}',
                style: TextStyle(fontSize: FontSizes.body, color: t.textMuted),
              ),
              const SizedBox(height: Insets.md),
              Text(
                'The review target is a commitment to look at your application, not a '
                'payment deadline. Nothing is approved automatically when it passes.',
                style: TextStyle(
                  fontSize: FontSizes.caption,
                  height: 1.55,
                  color: t.textFaint,
                ),
              ),
              if (status == ApplicationStatus.approved) ...[
                const SizedBox(height: Insets.lg),
                Container(
                  padding: const EdgeInsets.all(Insets.md),
                  decoration: BoxDecoration(
                    color: t.success.bg,
                    border: Border.all(color: t.success.border),
                    borderRadius: Radii.control,
                  ),
                  child: Text(
                    'Approved. Your administrator credentials were emailed to '
                    '${data['email'] ?? 'your address'} — sign in and change the '
                    'temporary password.',
                    style: TextStyle(
                      fontSize: FontSizes.body,
                      height: 1.55,
                      color: t.success.fg,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
