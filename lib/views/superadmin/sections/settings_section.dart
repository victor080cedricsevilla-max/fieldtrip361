import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../../config/console_theme.dart';
import '../../../config/theme.dart';
import '../super_admin_data.dart';
import '../widgets/console_scaffold.dart';
import '../widgets/console_ui.dart';

/// Profile, password and the review calendar that the published turnaround
/// promise is measured against.
class SettingsSection extends StatefulWidget {
  final Map<String, dynamic> me;
  final VoidCallback onProfileChanged;

  const SettingsSection({super.key, required this.me, required this.onProfileChanged});

  @override
  State<SettingsSection> createState() => _SettingsSectionState();
}

class _SettingsSectionState extends State<SettingsSection> {
  final _nameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  bool _savingProfile = false;
  bool _savingPassword = false;
  bool _obscure = true;
  String? _profileMessage;
  String? _passwordError;
  String? _passwordMessage;

  @override
  void initState() {
    super.initState();
    _nameController.text = (widget.me['name'] ?? '').toString();
  }

  @override
  void didUpdateWidget(covariant SettingsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.me['name'] != widget.me['name'] && !_savingProfile) {
      _nameController.text = (widget.me['name'] ?? '').toString();
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  Future<void> _saveProfile() async {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _profileMessage = 'Enter the name to show on the console.');
      return;
    }
    setState(() {
      _savingProfile = true;
      _profileMessage = null;
    });
    try {
      await FirebaseFirestore.instance.collection('users').doc(uid).update({'name': name});
      widget.onProfileChanged();
      if (mounted) setState(() => _profileMessage = 'Saved.');
    } catch (e) {
      if (mounted) setState(() => _profileMessage = 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _savingProfile = false);
    }
  }

  /// Validated on blur and again on submit; the message names the fix rather
  /// than the rule.
  String? _validatePassword(String value, String confirm) {
    if (value.length < 8) return 'Use at least 8 characters.';
    if (!RegExp(r'[A-Za-z]').hasMatch(value)) return 'Include at least one letter.';
    if (!RegExp(r'[0-9]').hasMatch(value)) return 'Include at least one number.';
    if (confirm.isNotEmpty && value != confirm) return 'The two passwords do not match.';
    return null;
  }

  Future<void> _changePassword() async {
    final value = _passwordController.text;
    final confirm = _confirmController.text;
    final error = _validatePassword(value, confirm) ??
        (value != confirm ? 'The two passwords do not match.' : null);
    if (error != null) {
      setState(() => _passwordError = error);
      return;
    }

    setState(() {
      _savingPassword = true;
      _passwordError = null;
      _passwordMessage = null;
    });
    try {
      await PlatformActions.changeMyPassword(value);
      _passwordController.clear();
      _confirmController.clear();
      if (mounted) {
        setState(() => _passwordMessage = 'Password changed. Use it the next time you sign in.');
      }
    } catch (e) {
      final text = e.toString();
      if (mounted) {
        setState(() {
          _passwordError = text.contains('failed-precondition')
              ? 'For your security, sign out and back in, then change the password within 15 minutes.'
              : 'Could not change the password. $text';
        });
      }
    } finally {
      if (mounted) setState(() => _savingPassword = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final email = (widget.me['email'] ?? FirebaseAuth.instance.currentUser?.email ?? '').toString();

    return ConsolePage(
      maxWidth: 760,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionHeader(
            title: 'Settings',
            subtitle: 'Your console profile, password and the review calendar.',
          ),
          const SizedBox(height: Insets.xl),

          ConsoleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Profile',
                  style: TextStyle(
                    fontSize: FontSizes.bodyLg,
                    fontWeight: FontWeight.w600,
                    color: t.text,
                  ),
                ),
                const SizedBox(height: Insets.lg),
                ConsoleField(
                  label: 'Display name',
                  helper: 'Shown on decisions you record and on replies you send.',
                  child: TextField(
                    controller: _nameController,
                    textInputAction: TextInputAction.done,
                    autofillHints: const [AutofillHints.name],
                    decoration: const InputDecoration(hintText: 'e.g. Platform Operations'),
                  ),
                ),
                const SizedBox(height: Insets.lg),
                ConsoleField(
                  label: 'Sign-in email',
                  helper: 'Changing this address is not self-serve — it identifies you in '
                      'the audit log.',
                  child: TextField(
                    enabled: false,
                    controller: TextEditingController(text: email),
                  ),
                ),
                const SizedBox(height: Insets.lg),
                Row(
                  children: [
                    ConsoleButton(
                      label: 'Save profile',
                      icon: Icons.check_rounded,
                      busy: _savingProfile,
                      onPressed: _savingProfile ? null : _saveProfile,
                    ),
                    if (_profileMessage != null) ...[
                      const SizedBox(width: Insets.md),
                      Flexible(
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            _profileMessage!,
                            style: TextStyle(fontSize: FontSizes.body, color: t.textMuted),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: Insets.lg),

          ConsoleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Password',
                  style: TextStyle(
                    fontSize: FontSizes.bodyLg,
                    fontWeight: FontWeight.w600,
                    color: t.text,
                  ),
                ),
                const SizedBox(height: Insets.xs),
                Text(
                  'The change is applied on the server, so it takes effect everywhere '
                  'you are signed in.',
                  style: TextStyle(fontSize: FontSizes.caption, color: t.textMuted),
                ),
                const SizedBox(height: Insets.lg),
                ConsoleField(
                  label: 'New password',
                  required: true,
                  helper: 'At least 8 characters, with a letter and a number.',
                  errorText: _passwordError,
                  child: TextField(
                    controller: _passwordController,
                    obscureText: _obscure,
                    autofillHints: const [AutofillHints.newPassword],
                    onEditingComplete: () => setState(() {
                      _passwordError = _validatePassword(
                        _passwordController.text,
                        _confirmController.text,
                      );
                    }),
                    decoration: InputDecoration(
                      hintText: 'New password',
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
                const SizedBox(height: Insets.lg),
                ConsoleField(
                  label: 'Confirm new password',
                  required: true,
                  child: TextField(
                    controller: _confirmController,
                    obscureText: _obscure,
                    autofillHints: const [AutofillHints.newPassword],
                    decoration: const InputDecoration(hintText: 'Repeat the password'),
                  ),
                ),
                const SizedBox(height: Insets.lg),
                Row(
                  children: [
                    ConsoleButton(
                      label: 'Change password',
                      icon: Icons.lock_reset_rounded,
                      busy: _savingPassword,
                      onPressed: _savingPassword ? null : _changePassword,
                    ),
                    if (_passwordMessage != null) ...[
                      const SizedBox(width: Insets.md),
                      Flexible(
                        child: Semantics(
                          liveRegion: true,
                          child: Text(
                            _passwordMessage!,
                            style: TextStyle(fontSize: FontSizes.body, color: t.success.fg),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: Insets.lg),

          ConsoleCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Appearance',
                  style: TextStyle(
                    fontSize: FontSizes.bodyLg,
                    fontWeight: FontWeight.w600,
                    color: t.text,
                  ),
                ),
                const SizedBox(height: Insets.md),
                ValueListenableBuilder<ThemeMode>(
                  valueListenable: AppTheme.mode,
                  builder: (context, mode, _) => SegmentedButton<ThemeMode>(
                    segments: const [
                      ButtonSegment(
                        value: ThemeMode.light,
                        icon: Icon(Icons.light_mode_outlined),
                        label: Text('Light'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.dark,
                        icon: Icon(Icons.dark_mode_outlined),
                        label: Text('Dark'),
                      ),
                      ButtonSegment(
                        value: ThemeMode.system,
                        icon: Icon(Icons.brightness_auto_outlined),
                        label: Text('System'),
                      ),
                    ],
                    selected: {mode},
                    onSelectionChanged: (s) => AppTheme.setMode(s.first),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Insets.lg),

          const _BankingCalendarCard(),
        ],
      ),
    );
  }
}

/// The Philippine banking holidays the 7-banking-day review target skips.
/// Kept editable because the list changes every year by proclamation.
class _BankingCalendarCard extends StatefulWidget {
  const _BankingCalendarCard();

  @override
  State<_BankingCalendarCard> createState() => _BankingCalendarCardState();
}

class _BankingCalendarCardState extends State<_BankingCalendarCard> {
  final _controller = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  String? _error;
  String? _message;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('platformConfig')
          .doc('bankingCalendar')
          .get();
      final holidays = (snap.data()?['holidays'] as List?)?.cast<String>() ?? const [];
      _controller.text = holidays.join('\n');
    } catch (e) {
      _error = 'Could not load the calendar. It falls back to the built-in list until saved.';
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    final lines = _controller.text
        .split(RegExp(r'[\s,]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final bad = lines.where((l) => !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(l)).toList();
    if (bad.isNotEmpty) {
      setState(() => _error = 'Use the format YYYY-MM-DD. Check: ${bad.take(3).join(', ')}');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
      _message = null;
    });
    try {
      await PlatformActions.updateBankingCalendar(lines);
      if (mounted) setState(() => _message = 'Saved ${lines.length} holiday dates.');
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not save: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    return ConsoleCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Review calendar',
            style: TextStyle(
              fontSize: FontSizes.bodyLg,
              fontWeight: FontWeight.w600,
              color: t.text,
            ),
          ),
          const SizedBox(height: Insets.xs),
          Text(
            'Applicants are told their application is reviewed within 7 banking days, '
            'and that processing may take up to 14 calendar days. These dates are the '
            'days the 7-banking-day count skips, in Asia/Manila time.',
            style: TextStyle(fontSize: FontSizes.caption, height: 1.5, color: t.textMuted),
          ),
          const SizedBox(height: Insets.lg),
          if (_loading)
            const DelayedLoader(child: ConsoleSkeleton(rows: 1, rowHeight: 120))
          else
            ConsoleField(
              label: 'Banking holidays',
              helper: 'One date per line, formatted YYYY-MM-DD.',
              errorText: _error,
              child: TextField(
                controller: _controller,
                minLines: 5,
                maxLines: 12,
                style: const TextStyle(fontFamily: 'monospace', fontSize: FontSizes.body),
                decoration: const InputDecoration(hintText: '2026-01-01\n2026-04-09'),
              ),
            ),
          const SizedBox(height: Insets.lg),
          Row(
            children: [
              ConsoleButton(
                label: 'Save calendar',
                icon: Icons.event_available_rounded,
                busy: _saving,
                onPressed: _loading || _saving ? null : _save,
              ),
              if (_message != null) ...[
                const SizedBox(width: Insets.md),
                Flexible(
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      _message!,
                      style: TextStyle(fontSize: FontSizes.body, color: t.success.fg),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}
