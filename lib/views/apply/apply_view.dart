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
/// One form, no account to create. A registrar tells us about the school,
/// attaches what their kind of institution is asked for, picks a plan and
/// submits — then a person reads it. The sign-in details only exist if that
/// person approves, and they arrive by email with the receipt.
class ApplyView extends StatefulWidget {
  const ApplyView({super.key});

  @override
  State<ApplyView> createState() => _ApplyViewState();
}

class _ApplyViewState extends State<ApplyView> {
  bool _ready = false;
  String? _sessionError;

  @override
  void initState() {
    super.initState();
    _begin();
  }

  Future<void> _begin() async {
    // A link from our email carries the application and its key, so the form
    // can be reopened on a phone even though the session that created it lives
    // in a desktop browser.
    final appId = Uri.base.queryParameters['app'];
    final key = Uri.base.queryParameters['k'];

    final user = await ApplicationService.ensureSession();
    if (user == null) {
      if (mounted) {
        setState(() {
          _sessionError =
              'We could not start a secure session. Check your connection and reload.';
          _ready = true;
        });
      }
      return;
    }

    if (appId != null && key != null) {
      try {
        await ApplicationService.openWithKey(applicationId: appId, accessKey: key);
      } catch (e) {
        if (mounted) setState(() => _sessionError = ApplicationService.describeError(e));
      }
    }
    if (mounted) setState(() => _ready = true);
  }

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final twoColumn = MediaQuery.sizeOf(context).width >= Breakpoints.loginStack;

    Widget content;
    if (!_ready) {
      content = const Padding(
        padding: EdgeInsets.symmetric(vertical: Insets.huge),
        child: DelayedLoader(child: ConsoleSkeleton(rows: 3, rowHeight: 80)),
      );
    } else if (ApplicationService.isSchoolAccount) {
      content = ConsoleEmptyState(
        icon: Icons.account_circle_outlined,
        title: 'You are signed in to FieldTrip360',
        message: 'Applying for a new school needs a signed-out browser, so the '
            'application is not attached to your existing account.',
        action: ConsoleButton(
          label: 'Sign out and apply',
          icon: Icons.logout_rounded,
          onPressed: () async {
            await FirebaseAuth.instance.signOut();
            if (mounted) {
              setState(() => _ready = false);
              _begin();
            }
          },
        ),
      );
    } else {
      content = StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: ApplicationService.mine(),
        builder: (context, snap) {
          if (snap.hasError) {
            return ConsoleErrorState(
              title: 'Your application could not be loaded',
              message: 'Check your connection and try again.',
              technicalDetail: snap.error.toString(),
              onRetry: () => setState(() {}),
            );
          }
          if (!snap.hasData) {
            return const DelayedLoader(child: ConsoleSkeleton(rows: 3, rowHeight: 80));
          }

          final live = snap.data!.docs
              .where((d) => (d.data()['status'] ?? '') != ApplicationStatus.rejected)
              .toList();
          final current = live.isEmpty ? null : live.first;
          final status = (current?.data()['status'] ?? '').toString();

          // Once it is with the reviewer there is nothing left to fill in.
          if (current != null &&
              status != ApplicationStatus.draft &&
              status != ApplicationStatus.needsMoreDocuments) {
            return _StatusPanel(data: current.data());
          }

          return _ApplicationForm(
            applicationId: current?.id,
            existing: current?.data(),
            banner: _sessionError,
          );
        },
      );
    }

    final panel = BrandPanel(
      headline: 'Bring FieldTrip360\nto your school.',
      supporting: 'Tell us about your institution and attach your verification '
          'documents. A person reviews every application.',
      points: const [
        'Reviewed within 7 banking days',
        'Processing may take up to 14 calendar days',
        'No student information is ever requested to verify a school',
      ],
    );

    return Scaffold(
      backgroundColor: t.surface,
      body: twoColumn
          ? Row(
              children: [
                Expanded(flex: 4, child: panel),
                Expanded(
                  flex: 6,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(
                      horizontal: Insets.xxxl,
                      vertical: Insets.xxl,
                    ),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 640),
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
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const BrandLockup(),
                    const SizedBox(height: Insets.xl),
                    Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 640),
                        child: content,
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

// ─── The form ─────────────────────────────────────────────────────────────────

class _ApplicationForm extends StatefulWidget {
  final String? applicationId;
  final Map<String, dynamic>? existing;
  final String? banner;

  const _ApplicationForm({this.applicationId, this.existing, this.banner});

  @override
  State<_ApplicationForm> createState() => _ApplicationFormState();
}

class _ApplicationFormState extends State<_ApplicationForm> {
  final _schoolName = TextEditingController();
  final _legalName = TextEditingController();
  final _address = TextEditingController();
  final _email = TextEditingController();
  final _repName = TextEditingController();
  final _repPosition = TextEditingController();
  final _repPhone = TextEditingController();

  String _institutionType = InstitutionType.privateIncorporated;
  String _tier = _fromUrl('tier', _knownTiers, 'starter');
  String _cycle = _fromUrl('cycle', const {'monthly', 'annual'}, 'monthly');

  String? _applicationId;
  bool _saving = false;
  bool _submitting = false;
  Map<String, dynamic>? _submitted;
  final Map<String, String?> _errors = {};
  String? _formError;

  static const _knownTiers = {
    'starter', 'growth', 'professional', 'scale', 'campus', 'enterprise',
  };

  static String _fromUrl(String key, Set<String> allowed, String fallback) {
    final v = Uri.base.queryParameters[key];
    return allowed.contains(v) ? v! : fallback;
  }

  @override
  void initState() {
    super.initState();
    _applicationId = widget.applicationId;
    _hydrate();
  }

  @override
  void didUpdateWidget(covariant _ApplicationForm old) {
    super.didUpdateWidget(old);
    if (old.applicationId != widget.applicationId) {
      _applicationId = widget.applicationId;
      _hydrate();
    }
  }

  void _hydrate() {
    final d = widget.existing;
    if (d == null) return;
    _schoolName.text = (d['schoolName'] ?? '').toString();
    _legalName.text = (d['legalName'] ?? '').toString();
    _address.text = (d['address'] ?? '').toString();
    _email.text = (d['email'] ?? '').toString();
    final rep = (d['representative'] ?? const {}) as Map;
    _repName.text = (rep['name'] ?? '').toString();
    _repPosition.text = (rep['position'] ?? '').toString();
    _repPhone.text = (rep['phone'] ?? '').toString();
    _institutionType = (d['institutionType'] ?? _institutionType).toString();
    final plan = (d['plan'] ?? const {}) as Map;
    _tier = (plan['tier'] ?? _tier).toString();
    _cycle = (plan['billingCycle'] ?? _cycle).toString();
  }

  @override
  void dispose() {
    for (final c in [
      _schoolName, _legalName, _address, _email, _repName, _repPosition, _repPhone,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  bool _validate() {
    setState(() {
      _errors.clear();
      if (_schoolName.text.trim().length < 2) {
        _errors['schoolName'] = "Enter the school's name.";
      }
      final email = _email.text.trim();
      if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$').hasMatch(email)) {
        _errors['email'] = 'Enter the email address we should send the decision to.';
      }
      if (_repName.text.trim().isEmpty) {
        _errors['repName'] = "Enter the representative's full name.";
      }
    });
    return _errors.isEmpty;
  }

  /// Saved as soon as the details are valid, because the documents cannot be
  /// attached until the application exists to attach them to.
  Future<bool> _save({bool silent = false}) async {
    if (!_validate()) return false;
    if (!silent) setState(() => _saving = true);
    try {
      final res = await ApplicationService.save(
        schoolName: _schoolName.text.trim(),
        legalName: _legalName.text.trim().isEmpty
            ? _schoolName.text.trim()
            : _legalName.text.trim(),
        institutionType: _institutionType,
        address: _address.text.trim(),
        email: _email.text.trim(),
        repName: _repName.text.trim(),
        repPosition: _repPosition.text.trim(),
        repPhone: _repPhone.text.trim(),
        tier: _tier,
        billingCycle: _cycle,
      );
      if (mounted) {
        setState(() {
          _applicationId = res['applicationId']?.toString();
          _formError = null;
        });
      }
      return true;
    } catch (e) {
      if (mounted) setState(() => _formError = ApplicationService.describeError(e));
      return false;
    } finally {
      if (mounted && !silent) setState(() => _saving = false);
    }
  }

  Future<void> _submit() async {
    if (!await _save(silent: true)) return;
    final id = _applicationId;
    if (id == null) return;

    setState(() {
      _submitting = true;
      _formError = null;
    });
    try {
      final res = await ApplicationService.submit(id);
      if (mounted) setState(() => _submitted = res);
    } catch (e) {
      if (mounted) setState(() => _formError = ApplicationService.describeError(e));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    if (_submitted != null) return _SubmittedPanel(result: _submitted!);

    final requested = ((widget.existing?['requestedDocTypes'] as List?) ?? const [])
        .map((e) => e.toString())
        .toList();

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
          'One form. A person reads it, and you hear back by email either way.',
          style: TextStyle(fontSize: FontSizes.body, height: 1.55, color: t.textMuted),
        ),
        const SizedBox(height: Insets.xl),

        if (widget.banner != null) ...[
          _Notice(text: widget.banner!, tone: t.warning, icon: Icons.link_off_rounded),
          const SizedBox(height: Insets.lg),
        ],
        if (requested.isNotEmpty) ...[
          _Notice(
            tone: t.warning,
            icon: Icons.upload_file_rounded,
            text: 'We asked for more documents:\n'
                '${requested.map((r) => '•  ${ApplicationDocType.label(r)}').join('\n')}\n\n'
                'Attach them below and submit again. Your original submission date '
                'does not change.',
          ),
          const SizedBox(height: Insets.lg),
        ],
        if (_formError != null) ...[
          _Notice(text: _formError!, tone: t.danger, icon: Icons.error_outline_rounded),
          const SizedBox(height: Insets.lg),
        ],

        _SectionCard(
          title: 'About the school',
          child: Column(
            children: [
              ConsoleField(
                label: 'School name',
                required: true,
                errorText: _errors['schoolName'],
                child: TextField(
                  controller: _schoolName,
                  autofillHints: const [AutofillHints.organizationName],
                  decoration: const InputDecoration(
                    hintText: 'e.g. San Rafael National High School',
                  ),
                ),
              ),
              const SizedBox(height: Insets.lg),
              ConsoleField(
                label: 'Registered legal name',
                helper: 'Leave blank if it is the same as above.',
                child: TextField(
                  controller: _legalName,
                  decoration: const InputDecoration(
                    hintText: 'As printed on your registration',
                  ),
                ),
              ),
              const SizedBox(height: Insets.lg),
              ConsoleField(
                label: 'Kind of institution',
                required: true,
                helper: 'This decides which documents we ask for — a public school '
                    'is never asked for an SEC registration.',
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
                  decoration: const InputDecoration(
                    hintText: 'Street, barangay, city, province',
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: Insets.lg),

        _SectionCard(
          title: 'Who we should contact',
          subtitle: 'Every message about this application goes to this address, '
              'including the sign-in details if it is approved.',
          child: Column(
            children: [
              ConsoleField(
                label: 'Email address',
                required: true,
                errorText: _errors['email'],
                child: TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autofillHints: const [AutofillHints.email],
                  autocorrect: false,
                  decoration: const InputDecoration(hintText: 'registrar@school.edu.ph'),
                ),
              ),
              const SizedBox(height: Insets.lg),
              ConsoleField(
                label: 'Authorized representative',
                required: true,
                errorText: _errors['repName'],
                child: TextField(
                  controller: _repName,
                  autofillHints: const [AutofillHints.name],
                  decoration: const InputDecoration(hintText: 'Full name'),
                ),
              ),
              const SizedBox(height: Insets.lg),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: ConsoleField(
                      label: 'Position',
                      child: TextField(
                        controller: _repPosition,
                        decoration: const InputDecoration(hintText: 'e.g. Principal'),
                      ),
                    ),
                  ),
                  const SizedBox(width: Insets.md),
                  Expanded(
                    child: ConsoleField(
                      label: 'Contact number',
                      child: TextField(
                        controller: _repPhone,
                        keyboardType: TextInputType.phone,
                        decoration: const InputDecoration(hintText: '09xx xxx xxxx'),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: Insets.lg),

        _SectionCard(
          title: 'Subscription plan',
          subtitle: 'Pay for capacity. Pick the tier just above your real student '
              'count — you can change it later.',
          child: _PlanPicker(
            tier: _tier,
            cycle: _cycle,
            onTier: (v) => setState(() => _tier = v),
            onCycle: (v) => setState(() => _cycle = v),
          ),
        ),
        const SizedBox(height: Insets.lg),

        _DocumentsCard(
          applicationId: _applicationId,
          institutionType: _institutionType,
          requestedDocTypes: requested,
          onNeedApplication: () => _save(silent: true),
          saving: _saving,
        ),
        const SizedBox(height: Insets.xl),

        _SubmitBar(
          applicationId: _applicationId,
          institutionType: _institutionType,
          requestedDocTypes: requested,
          submitting: _submitting,
          onSubmit: _submit,
        ),
        const SizedBox(height: Insets.giant),
      ],
    );
  }
}

// ─── Pieces ───────────────────────────────────────────────────────────────────

class _SectionCard extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;

  const _SectionCard({required this.title, this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    return ConsoleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: FontSizes.bodyLg,
              fontWeight: FontWeight.w600,
              color: t.text,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: Insets.xs),
            Text(
              subtitle!,
              style: TextStyle(
                fontSize: FontSizes.caption,
                height: 1.55,
                color: t.textMuted,
              ),
            ),
          ],
          const SizedBox(height: Insets.lg),
          child,
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  final String text;
  final StatusTone tone;
  final IconData icon;

  const _Notice({required this.text, required this.tone, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.all(Insets.md),
        decoration: BoxDecoration(
          color: tone.bg,
          border: Border.all(color: tone.border),
          borderRadius: Radii.control,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: tone.fg),
            const SizedBox(width: Insets.sm),
            Expanded(
              child: Text(
                text,
                style: TextStyle(fontSize: FontSizes.body, height: 1.55, color: tone.fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The plans, with what each one costs. Mirrors functions/lib/pricing.js; the
/// server prices the plan itself on save, so this is display only.
class _PlanPicker extends StatelessWidget {
  final String tier;
  final String cycle;
  final ValueChanged<String> onTier;
  final ValueChanged<String> onCycle;

  const _PlanPicker({
    required this.tier,
    required this.cycle,
    required this.onTier,
    required this.onCycle,
  });

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
    final annual = cycle == 'annual';
    final selected = _tiers.firstWhere((e) => e.$1 == tier, orElse: () => _tiers.first);
    final monthly = annual ? (selected.$4 * 0.8).round() : selected.$4;
    final total = annual ? monthly * 12 : monthly;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'monthly', label: Text('Monthly')),
            ButtonSegment(value: 'annual', label: Text('Annual · save 20%')),
          ],
          selected: {cycle},
          onSelectionChanged: (s) => onCycle(s.first),
        ),
        const SizedBox(height: Insets.md),
        ..._tiers.map((e) {
          final (key, label, capacity, base) = e;
          final isSelected = key == tier;
          final price = annual ? (base * 0.8).round() : base;
          return Padding(
            padding: const EdgeInsets.only(bottom: Insets.sm),
            child: ConsoleCard(
              onTap: () => onTier(key),
              accent: isSelected ? t.brand : null,
              padding: const EdgeInsets.all(Insets.md),
              child: Row(
                children: [
                  Icon(
                    isSelected
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_unchecked_rounded,
                    size: 20,
                    color: isSelected ? t.brand : t.textFaint,
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
                    capacity == 0 ? 'Custom' : '${formatPeso(price)}/mo',
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
        const SizedBox(height: Insets.sm),
        Container(
          padding: const EdgeInsets.all(Insets.lg),
          decoration: BoxDecoration(
            color: t.info.bg,
            border: Border.all(color: t.info.border),
            borderRadius: Radii.control,
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      selected.$3 == 0
                          ? 'Enterprise — quoted individually'
                          : '${selected.$2} · up to ${selected.$3} students',
                      style: TextStyle(
                        fontSize: FontSizes.caption,
                        fontWeight: FontWeight.w600,
                        color: t.info.fg,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      annual ? 'Billed once a year' : 'Billed every month',
                      style: TextStyle(fontSize: FontSizes.caption, color: t.info.fg),
                    ),
                  ],
                ),
              ),
              if (selected.$3 != 0)
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      formatPeso(total),
                      style: TextStyle(
                        fontSize: FontSizes.heading,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                        color: t.info.fg,
                      ),
                    ),
                    Text(
                      annual ? 'per year' : 'per month',
                      style: TextStyle(fontSize: FontSizes.caption, color: t.info.fg),
                    ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(height: Insets.sm),
        Text(
          'No payment is collected during this trial. Your subscription is '
          'activated on approval and the receipt says so on its face.',
          style: TextStyle(fontSize: FontSizes.caption, height: 1.5, color: t.textFaint),
        ),
      ],
    );
  }
}

/// Which documents this institution type needs, and the upload for each.
/// Mirrors INSTITUTION_REQUIREMENTS in functions/lib/applications.js.
class _DocumentsCard extends StatefulWidget {
  final String? applicationId;
  final String institutionType;
  final List<String> requestedDocTypes;
  final Future<bool> Function() onNeedApplication;
  final bool saving;

  const _DocumentsCard({
    required this.applicationId,
    required this.institutionType,
    required this.requestedDocTypes,
    required this.onNeedApplication,
    required this.saving,
  });

  static const _requirements = <String, (List<String>, List<String>)>{
    InstitutionType.privateIncorporated: (
      [
        ApplicationDocType.secRegistration,
        ApplicationDocType.depedPermit,
        ApplicationDocType.authorizationLetter,
      ],
      [
        ApplicationDocType.articlesOfIncorporation,
        ApplicationDocType.schoolIdentifier,
        ApplicationDocType.addressProof,
      ],
    ),
    InstitutionType.publicSchool: (
      [
        ApplicationDocType.governmentEstablishment,
        ApplicationDocType.authorizationLetter,
      ],
      [
        ApplicationDocType.schoolIdentifier,
        ApplicationDocType.addressProof,
        ApplicationDocType.depedPermit,
      ],
    ),
    InstitutionType.stateUniversity: (
      [
        ApplicationDocType.governmentEstablishment,
        ApplicationDocType.authorizationLetter,
      ],
      [
        ApplicationDocType.chedRecognition,
        ApplicationDocType.schoolIdentifier,
        ApplicationDocType.addressProof,
      ],
    ),
    InstitutionType.tvet: (
      [
        ApplicationDocType.tesdaRegistration,
        ApplicationDocType.authorizationLetter,
      ],
      [
        ApplicationDocType.secRegistration,
        ApplicationDocType.schoolIdentifier,
        ApplicationDocType.addressProof,
      ],
    ),
    InstitutionType.other: (
      [ApplicationDocType.authorizationLetter],
      [
        ApplicationDocType.secRegistration,
        ApplicationDocType.depedPermit,
        ApplicationDocType.chedRecognition,
        ApplicationDocType.tesdaRegistration,
        ApplicationDocType.governmentEstablishment,
        ApplicationDocType.schoolIdentifier,
        ApplicationDocType.addressProof,
        ApplicationDocType.other,
      ],
    ),
  };

  static (List<String>, List<String>) requirementsFor(String type) =>
      _requirements[type] ?? _requirements[InstitutionType.other]!;

  @override
  State<_DocumentsCard> createState() => _DocumentsCardState();
}

class _DocumentsCardState extends State<_DocumentsCard> {
  String? _uploading;
  double _progress = 0;
  String? _error;

  Future<void> _pick(String type) async {
    setState(() {
      _error = null;
      _uploading = type;
      _progress = 0;
    });
    try {
      // The application has to exist before a file can hang off it.
      var id = widget.applicationId;
      if (id == null) {
        final ok = await widget.onNeedApplication();
        if (!ok) {
          setState(() {
            _uploading = null;
            _error = 'Fill in the school name, email and representative first.';
          });
          return;
        }
        if (!mounted) return;
        id = widget.applicationId;
        if (id == null) {
          setState(() => _uploading = null);
          return;
        }
      }

      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png'],
        withData: true,
      );
      final file = picked?.files.firstOrNull;
      if (file == null || file.bytes == null) {
        setState(() => _uploading = null);
        return;
      }
      if (file.size > 10 * 1024 * 1024) {
        setState(() {
          _error = 'That file is larger than 10 MB. Please upload a smaller scan.';
          _uploading = null;
        });
        return;
      }

      final ext = (file.extension ?? 'pdf').toLowerCase();
      await ApplicationService.uploadDocument(
        applicationId: id,
        type: type,
        bytes: file.bytes!,
        fileName: file.name,
        contentType: switch (ext) {
          'pdf' => 'application/pdf',
          'png' => 'image/png',
          _ => 'image/jpeg',
        },
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
    } catch (e) {
      if (mounted) setState(() => _error = ApplicationService.describeError(e));
    } finally {
      if (mounted) setState(() => _uploading = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final (required, optional) = _DocumentsCard.requirementsFor(widget.institutionType);
    final needed = widget.requestedDocTypes.isNotEmpty ? widget.requestedDocTypes : required;

    return _SectionCard(
      title: 'Verification documents',
      subtitle: 'PDF, JPG or PNG, up to 10 MB each. We never ask for student '
          'lists, student numbers, attendance or medical records to verify a school.',
      child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: widget.applicationId == null
            ? const Stream.empty()
            : ApplicationService.documents(widget.applicationId!),
        builder: (context, snap) {
          final live = (snap.data?.docs ?? const [])
              .where((d) => d.data()['superseded'] != true)
              .toList();

          Widget rowFor(String type) => _DocRow(
                type: type,
                uploaded: live.where((d) => d.data()['type'] == type).toList(),
                uploading: _uploading == type,
                progress: _progress,
                onUpload: () => _pick(type),
                onRemove: widget.applicationId == null
                    ? null
                    : (docId) => ApplicationService.removeDocument(
                          applicationId: widget.applicationId!,
                          documentId: docId,
                        ),
              );

          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_error != null) ...[
                _Notice(text: _error!, tone: t.danger, icon: Icons.error_outline_rounded),
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
              ...needed.map(rowFor),
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
                ...optional.where((o) => !needed.contains(o)).map(rowFor),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _DocRow extends StatelessWidget {
  final String type;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> uploaded;
  final bool uploading;
  final double progress;
  final VoidCallback onUpload;
  final Future<void> Function(String documentId)? onRemove;

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
            ...uploaded.map((d) => Padding(
                  padding: const EdgeInsets.only(top: Insets.sm),
                  child: Row(
                    children: [
                      Icon(Icons.description_outlined, size: 15, color: t.textFaint),
                      const SizedBox(width: Insets.sm),
                      Expanded(
                        child: Text(
                          (d.data()['fileName'] ?? 'document').toString(),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: FontSizes.caption,
                            color: t.textMuted,
                          ),
                        ),
                      ),
                      if (onRemove != null)
                        IconButton(
                          icon: const Icon(Icons.close_rounded, size: 16),
                          tooltip: 'Remove this file',
                          onPressed: () => onRemove!(d.id),
                        ),
                    ],
                  ),
                )),
          ],
        ),
      ),
    );
  }
}

class _SubmitBar extends StatelessWidget {
  final String? applicationId;
  final String institutionType;
  final List<String> requestedDocTypes;
  final bool submitting;
  final VoidCallback onSubmit;

  const _SubmitBar({
    required this.applicationId,
    required this.institutionType,
    required this.requestedDocTypes,
    required this.submitting,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final (required, _) = _DocumentsCard.requirementsFor(institutionType);
    final needed = requestedDocTypes.isNotEmpty ? requestedDocTypes : required;

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: applicationId == null
          ? const Stream.empty()
          : ApplicationService.documents(applicationId!),
      builder: (context, snap) {
        final present = (snap.data?.docs ?? const [])
            .where((d) => d.data()['superseded'] != true)
            .map((d) => (d.data()['type'] ?? '').toString())
            .toSet();
        final missing = needed.where((n) => !present.contains(n)).toList();
        final ready = applicationId != null && missing.isEmpty;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (missing.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: Insets.md),
                child: _Notice(
                  tone: t.neutral,
                  icon: Icons.checklist_rounded,
                  text: 'Still to attach: '
                      '${missing.map(ApplicationDocType.label).join(', ')}.',
                ),
              ),
            SizedBox(
              height: 52,
              child: ElevatedButton.icon(
                onPressed: ready && !submitting ? onSubmit : null,
                icon: submitting
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.send_rounded, size: 20),
                label: const Text('Submit application'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: t.brand,
                  foregroundColor: t.onBrand,
                  disabledBackgroundColor: t.brand.withValues(alpha: 0.4),
                  disabledForegroundColor: Colors.white70,
                  elevation: 0,
                  shape: const RoundedRectangleBorder(borderRadius: Radii.control),
                  textStyle: const TextStyle(
                    fontSize: FontSizes.bodyLg,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        );
      },
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
          _Notice(
            tone: emailSent ? t.success : t.warning,
            icon: emailSent ? Icons.mark_email_read_outlined : Icons.report_outlined,
            text: emailSent
                ? 'A confirmation email is on its way with your reference number.'
                : 'Your application is saved, but the confirmation email could not be '
                    'sent right now. Your application is unaffected — we will still '
                    'review it and email you the decision.',
          ),
        ],
      ),
    );
  }
}

/// What an applicant sees once their application is with the reviewer.
class _StatusPanel extends StatelessWidget {
  final Map<String, dynamic> data;
  const _StatusPanel({required this.data});

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final status = (data['status'] ?? '').toString();

    return ConsoleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
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
            _Notice(
              tone: t.success,
              icon: Icons.verified_outlined,
              text: 'Approved. Your administrator credentials and receipt were emailed '
                  'to ${data['email'] ?? 'your address'} — sign in and change the '
                  'temporary password.',
            ),
          ],
        ],
      ),
    );
  }
}
