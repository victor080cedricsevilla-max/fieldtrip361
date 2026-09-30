import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';

import '../../config/theme.dart';
import '../../controllers/auth_controller.dart';
import 'terms_agreement_box.dart';
import 'terms_content.dart';

/// The one way in for a student, a parent or a teacher.
///
/// There is no sign-up form. Anyone could open one and create an account, which
/// left the school finding out afterwards who had joined; now an account can
/// only come from a code the school issued to an address it already holds. The
/// code carries everything the old form asked for — the role, the address, and
/// for a student the learner reference number — so all that is left to ask is
/// the code and a password.
///
/// The first letter of the code says what it opens: S for a student, P for a
/// parent, T for a teacher. That is read as it is typed, so nobody chooses a
/// role from a list and nobody can register as one their school did not give
/// them.
class RedeemCodeView extends StatefulWidget {
  const RedeemCodeView({super.key});

  @override
  State<RedeemCodeView> createState() => _RedeemCodeViewState();
}

/// What the first letter of a code opens, for the heading and the hint.
enum _CodeRole { none, student, parent, teacher, unknown }

class _RedeemCodeViewState extends State<RedeemCodeView> {
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _auth = AuthController();

  bool _busy = false;
  bool _hidePassword = true;
  bool _agreedToTerms = false;
  String? _error;

  static const _minPassword = 12;

  @override
  void initState() {
    super.initState();
    _code.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _code.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  /// Letters and digits only, so "s 7k4p-92xm" and "S-7K4P-92XM" read alike.
  String get _normalized =>
      _code.text.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  _CodeRole get _role {
    final n = _normalized;
    if (n.isEmpty) return _CodeRole.none;
    switch (n[0]) {
      case 'S':
        return _CodeRole.student;
      case 'P':
        return _CodeRole.parent;
      case 'T':
        return _CodeRole.teacher;
      default:
        // A teacher invitation issued before codes began with T carries the
        // school's initials. It is still valid, so it is not called wrong here.
        return _CodeRole.unknown;
    }
  }

  String get _heading {
    switch (_role) {
      case _CodeRole.student:
        return 'Set up your student account';
      case _CodeRole.parent:
        return 'Set up your parent account';
      case _CodeRole.teacher:
        return 'Set up your facilitator account';
      default:
        return 'Create your account';
    }
  }

  String? get _roleHint {
    switch (_role) {
      case _CodeRole.student:
        return 'Student code — your Learner Reference Number is already on your record.';
      case _CodeRole.parent:
        return 'Parent code — your child will be linked automatically.';
      case _CodeRole.teacher:
        return 'Teacher code — you will join your school as a trip facilitator.';
      default:
        return null;
    }
  }

  IconData get _roleIcon {
    switch (_role) {
      case _CodeRole.student:
        return Icons.school_outlined;
      case _CodeRole.parent:
        return Icons.family_restroom_outlined;
      case _CodeRole.teacher:
        return Icons.directions_bus_outlined;
      default:
        return Icons.mark_email_read_outlined;
    }
  }

  Future<Map<String, dynamic>> _call(String name, Map<String, dynamic> data) async {
    final res = await FirebaseFunctions.instance
        .httpsCallable(name)
        .call<Map<String, dynamic>>(data);
    return Map<String, dynamic>.from(res.data);
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();

    final code = _code.text.trim();
    final password = _password.text;

    if (_normalized.length < 6) {
      setState(() => _error = 'Enter the registration code from your email.');
      return;
    }
    if (password.length < _minPassword) {
      setState(() => _error = 'Choose a password of at least $_minPassword characters.');
      return;
    }
    if (password != _confirm.text) {
      setState(() => _error = 'The two passwords do not match.');
      return;
    }
    // A backstop for the disabled button. The consent is what makes holding the
    // account's data lawful, so it is checked here as well as in the widget tree
    // — and again on the server.
    if (!_agreedToTerms) {
      setState(() => _error =
          'Please read the Terms & Conditions to the end and tick the box to continue.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final body = {
        'code': code,
        'password': password,
        'acceptedTermsVersion': kTermsVersion,
      };

      Map<String, dynamic> res;
      final first = _normalized[0];
      if (first == 'S' || first == 'P') {
        try {
          res = await _call('redeemEnrollmentCode', body);
        } on FirebaseFunctionsException catch (e) {
          // A teacher invitation issued before codes began with T can start with
          // an S or a P too. Only "no such code" falls through; anything else —
          // expired, used, withdrawn — is the real answer and is shown as is.
          if (e.code != 'not-found') rethrow;
          res = await _call('redeemTeacherInvite', body);
        }
      } else {
        res = await _call('redeemTeacherInvite', body);
      }

      final email = (res['email'] ?? '').toString();
      final school = (res['schoolName'] ?? '').toString();
      final childPending = res['childPending'] == true;

      // The account exists. Sign them straight in rather than sending them back
      // to type an address they never chose.
      if (!mounted) return;
      // Taken now, because this screen is gone by the time sign-in finishes: the
      // messenger belongs to the app, not to the page, so it outlives the route.
      final messenger = ScaffoldMessenger.of(context);
      final err = await _auth.loginUser(
        context: context,
        email: email,
        password: password,
        clearStack: true,
      );

      if (err != null) {
        // Created, but the sign-in itself failed. Say so: "try again" would be
        // wrong, because the code is now used.
        if (mounted) {
          setState(() => _error =
              'Your account was created, but signing in failed: $err Go back and log '
              'in with your email and the password you just chose.');
        }
        return;
      }

      messenger.showSnackBar(SnackBar(
        content: Text(
          childPending
              ? 'Your account is ready. Your child will appear as soon as they register.'
              : school.isEmpty
                  ? 'Your account is ready.'
                  : 'Welcome to $school.',
        ),
        backgroundColor: Colors.green,
      ));
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        setState(() => _error = e.message ?? 'That code could not be used.');
      }
    } catch (_) {
      if (mounted) {
        setState(() =>
            _error = 'Something went wrong. Check your connection and try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        foregroundColor: AppTheme.secondaryColor,
        title: const Text('Enter your code',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
            // Phones are narrower than this, so the cap only bites on the web
            // build, where a full-window form would stretch the terms panel into
            // unreadable lines.
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(_roleIcon, color: AppTheme.effectivePrimary, size: 28),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    _heading,
                    style: const TextStyle(
                        fontSize: 21,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.darkText),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Your school emailed you a registration code. Enter it below and '
                    'choose a password — we already know which school and which '
                    'address the account is for.',
                    style:
                        TextStyle(fontSize: 13.5, height: 1.5, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 26),

                  TextField(
                    controller: _code,
                    textCapitalization: TextCapitalization.characters,
                    autocorrect: false,
                    enableSuggestions: false,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: 'Registration code',
                      hintText: 'e.g. S-7K4P-92XM',
                      filled: true,
                      fillColor: Colors.white,
                      prefixIcon: const Icon(Icons.vpn_key_outlined),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  if (_roleHint != null) ...[
                    const SizedBox(height: 8),
                    Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Icon(Icons.check_circle_outline_rounded,
                          size: 15, color: AppTheme.effectivePrimary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _roleHint!,
                          style: TextStyle(
                              fontSize: 12,
                              height: 1.4,
                              color: Colors.grey.shade700),
                        ),
                      ),
                    ]),
                  ],
                  const SizedBox(height: 14),

                  TextField(
                    controller: _password,
                    obscureText: _hidePassword,
                    decoration: InputDecoration(
                      labelText: 'Create a password',
                      helperText: 'At least $_minPassword characters',
                      filled: true,
                      fillColor: Colors.white,
                      prefixIcon: const Icon(Icons.lock_outline_rounded),
                      suffixIcon: IconButton(
                        icon: Icon(_hidePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined),
                        onPressed: () => setState(() => _hidePassword = !_hidePassword),
                      ),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 14),

                  TextField(
                    controller: _confirm,
                    obscureText: _hidePassword,
                    decoration: InputDecoration(
                      labelText: 'Repeat the password',
                      filled: true,
                      fillColor: Colors.white,
                      prefixIcon: const Icon(Icons.lock_outline_rounded),
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
                  const SizedBox(height: 22),

                  // Consent gate: the account cannot be created until this notice
                  // has actually been scrolled through and agreed to.
                  TermsAgreementBox(
                    accepted: _agreedToTerms,
                    onAcceptedChanged: (value) => setState(() {
                      _agreedToTerms = value;
                      if (value) _error = null;
                    }),
                  ),

                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFDECEA),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        _error!,
                        style: const TextStyle(
                            fontSize: 13, color: Color(0xFF9B2C20), height: 1.4),
                      ),
                    ),
                  ],

                  const SizedBox(height: 22),
                  SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      onPressed: (_busy || !_agreedToTerms) ? null : _submit,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.effectivePrimary,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12)),
                      ),
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white),
                            )
                          : const Text('Create my account',
                              style:
                                  TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Text(
                    'No code yet? Ask your school administrator to send one to the '
                    'email address the school has on record for you. Codes start with '
                    'S for students, P for parents and T for teachers, and expire '
                    '30 days after they are sent.',
                    style:
                        TextStyle(fontSize: 12.5, height: 1.5, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
