import 'package:flutter/material.dart';

import '../../config/console_theme.dart';
import '../../config/roles.dart';
import '../../controllers/auth_controller.dart';
import 'brand_panel.dart';
import 'forgot_password_dialog.dart';

/// The single web sign-in.
///
/// School administrators and the platform operator use the same form; where
/// they land is decided by the role stored on their account, never by anything
/// chosen here. There is no role picker and no third-party sign-in, because
/// neither is supported by the accounts this system issues.
class LoginView extends StatefulWidget {
  const LoginView({super.key});

  @override
  State<LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends State<LoginView> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _passwordFocus = FocusNode();
  final _authController = AuthController();

  bool _isLoading = false;
  String? _errorMessage;
  String? _emailError;
  bool _obscurePassword = true;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  bool _validate() {
    final email = _emailController.text.trim();
    setState(() {
      _emailError = email.isEmpty
          ? 'Enter the email address your account uses.'
          : (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]{2,}$').hasMatch(email)
              ? 'That does not look like an email address.'
              : null);
    });
    return _emailError == null && _passwordController.text.isNotEmpty;
  }

  Future<void> _handleLogin() async {
    FocusScope.of(context).unfocus();
    if (!_validate()) {
      if (_passwordController.text.isEmpty && _emailError == null) {
        setState(() => _errorMessage = 'Enter your password.');
      }
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final error = await _authController.loginUser(
      context: context,
      email: _emailController.text.trim(),
      password: _passwordController.text,
    );

    if (!mounted) return;
    setState(() {
      _isLoading = false;
      if (error != null) _errorMessage = _friendlyAuthError(error);
    });
    // On success the controller has already navigated by role.
  }

  String _friendlyAuthError(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('disabled')) return raw; // already a full sentence
    if (lower.contains('wrong-password') ||
        lower.contains('invalid-credential') ||
        lower.contains('invalid-login-credentials') ||
        lower.contains('incorrect')) {
      return 'Incorrect email or password. Please try again.';
    }
    if (lower.contains('user-not-found') || lower.contains('no user record')) {
      return 'No account found for that email.';
    }
    if (lower.contains('user-disabled')) {
      return 'This account has been disabled. Contact FieldTrip360 support.';
    }
    if (lower.contains('too-many-requests')) {
      return 'Too many attempts. Wait a few minutes and try again.';
    }
    if (lower.contains('network')) {
      return 'Network error. Check your connection and try again.';
    }
    if (lower.contains('not-verified') || lower.contains('verify your email')) {
      return 'Please verify your email before signing in.';
    }
    return raw;
  }

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final width = MediaQuery.sizeOf(context).width;
    final twoColumn = width >= Breakpoints.loginStack;

    final form = _LoginForm(
      emailController: _emailController,
      passwordController: _passwordController,
      passwordFocus: _passwordFocus,
      isLoading: _isLoading,
      errorMessage: _errorMessage,
      emailError: _emailError,
      obscurePassword: _obscurePassword,
      onToggleObscure: () => setState(() => _obscurePassword = !_obscurePassword),
      onSubmit: _handleLogin,
      onForgotPassword: () => showDialog(
        context: context,
        builder: (_) => ForgotPasswordDialog(
          initialEmail: _emailController.text.trim(),
        ),
      ),
      onApply: () => Navigator.of(context).pushNamed(AppRoutes.apply),
      showCompactBrand: !twoColumn,
    );

    return Scaffold(
      backgroundColor: t.surface,
      body: twoColumn
          ? Row(
              children: [
                const Expanded(
                  flex: 5,
                  child: BrandPanel(
                    headline: 'Every trip accounted for.',
                    supporting:
                        'Sign in to manage trips, rosters and the people responsible '
                        'for them.',
                    points: [
                      'Live location and stop-by-stop roll call',
                      'Consent forms checked before the bus leaves',
                      'Parents kept informed without a group chat',
                    ],
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Insets.xxxl,
                        vertical: Insets.xxl,
                      ),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 400),
                        child: form,
                      ),
                    ),
                  ),
                ),
              ],
            )
          : Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: Insets.lg,
                  vertical: Insets.xxl,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: form,
                ),
              ),
            ),
    );
  }
}

class _LoginForm extends StatelessWidget {
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final FocusNode passwordFocus;
  final bool isLoading;
  final String? errorMessage;
  final String? emailError;
  final bool obscurePassword;
  final VoidCallback onToggleObscure;
  final VoidCallback onSubmit;
  final VoidCallback onForgotPassword;
  final VoidCallback onApply;
  final bool showCompactBrand;

  const _LoginForm({
    required this.emailController,
    required this.passwordController,
    required this.passwordFocus,
    required this.isLoading,
    required this.errorMessage,
    required this.emailError,
    required this.obscurePassword,
    required this.onToggleObscure,
    required this.onSubmit,
    required this.onForgotPassword,
    required this.onApply,
    required this.showCompactBrand,
  });

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);

    return AutofillGroup(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showCompactBrand) ...[
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: t.brand,
                    borderRadius: BorderRadius.circular(Radii.base),
                  ),
                  child: const Icon(Icons.route_rounded, color: Colors.white, size: 23),
                ),
                const SizedBox(width: Insets.md),
                Text(
                  'FieldTrip360',
                  style: TextStyle(
                    fontSize: FontSizes.title,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.4,
                    color: t.text,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Insets.xxl),
          ],

          Text(
            'Sign in',
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
            'Use the email address your school account was set up with.',
            style: TextStyle(fontSize: FontSizes.body, height: 1.55, color: t.textMuted),
          ),
          const SizedBox(height: Insets.xl),

          if (errorMessage != null) ...[
            Semantics(
              liveRegion: true,
              container: true,
              child: Container(
                padding: const EdgeInsets.all(Insets.md),
                decoration: BoxDecoration(
                  color: t.danger.bg,
                  borderRadius: Radii.control,
                  border: Border.all(color: t.danger.border),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.error_outline_rounded, color: t.danger.fg, size: 18),
                    const SizedBox(width: Insets.sm),
                    Expanded(
                      child: Text(
                        errorMessage!,
                        style: TextStyle(
                          color: t.danger.fg,
                          fontSize: FontSizes.body,
                          height: 1.5,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: Insets.lg),
          ],

          _Field(
            label: 'Email address',
            errorText: emailError,
            child: TextField(
              controller: emailController,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              autofillHints: const [AutofillHints.username, AutofillHints.email],
              autocorrect: false,
              enabled: !isLoading,
              onSubmitted: (_) => passwordFocus.requestFocus(),
              decoration: const InputDecoration(
                hintText: 'you@school.edu.ph',
                prefixIcon: Icon(Icons.mail_outline_rounded, size: 20),
              ),
            ),
          ),
          const SizedBox(height: Insets.lg),

          _Field(
            label: 'Password',
            child: TextField(
              controller: passwordController,
              focusNode: passwordFocus,
              obscureText: obscurePassword,
              textInputAction: TextInputAction.done,
              autofillHints: const [AutofillHints.password],
              enabled: !isLoading,
              onSubmitted: (_) => onSubmit(),
              decoration: InputDecoration(
                hintText: 'Your password',
                prefixIcon: const Icon(Icons.lock_outline_rounded, size: 20),
                suffixIcon: IconButton(
                  icon: Icon(
                    obscurePassword
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    size: 20,
                  ),
                  tooltip: obscurePassword ? 'Show password' : 'Hide password',
                  onPressed: onToggleObscure,
                ),
              ),
            ),
          ),

          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: isLoading ? null : onForgotPassword,
              style: TextButton.styleFrom(
                minimumSize: const Size(44, 44),
                foregroundColor: t.brand,
              ),
              child: const Text(
                'Forgot password?',
                style: TextStyle(fontWeight: FontWeight.w600, fontSize: FontSizes.body),
              ),
            ),
          ),
          const SizedBox(height: Insets.md),

          SizedBox(
            height: 52,
            child: ElevatedButton(
              onPressed: isLoading ? null : onSubmit,
              style: ElevatedButton.styleFrom(
                backgroundColor: t.brand,
                foregroundColor: t.onBrand,
                disabledBackgroundColor: t.brand.withValues(alpha: 0.5),
                disabledForegroundColor: Colors.white70,
                elevation: 0,
                shape: const RoundedRectangleBorder(borderRadius: Radii.control),
                textStyle: const TextStyle(
                  fontSize: FontSizes.bodyLg,
                  fontWeight: FontWeight.w600,
                ),
              ),
              child: isLoading
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2.2,
                      ),
                    )
                  : const Text('Sign in'),
            ),
          ),
          const SizedBox(height: Insets.xl),

          Container(
            padding: const EdgeInsets.all(Insets.lg),
            decoration: BoxDecoration(
              color: t.surfaceMuted,
              borderRadius: Radii.control,
              border: Border.all(color: t.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Is your school not on FieldTrip360 yet?',
                  style: TextStyle(
                    fontSize: FontSizes.body,
                    fontWeight: FontWeight.w600,
                    color: t.text,
                  ),
                ),
                const SizedBox(height: Insets.xs),
                Text(
                  'Apply for a subscription and we will review your school\'s '
                  'verification documents within 7 banking days.',
                  style: TextStyle(
                    fontSize: FontSizes.caption,
                    height: 1.55,
                    color: t.textMuted,
                  ),
                ),
                const SizedBox(height: Insets.md),
                TextButton.icon(
                  onPressed: onApply,
                  icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                  label: const Text(
                    'Apply for a school subscription',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: FontSizes.body,
                    ),
                  ),
                  style: TextButton.styleFrom(
                    minimumSize: const Size(44, 44),
                    foregroundColor: t.brand,
                    padding: const EdgeInsets.symmetric(horizontal: Insets.sm),
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

/// Label above the field, always visible — a placeholder is not a label.
class _Field extends StatelessWidget {
  final String label;
  final Widget child;
  final String? errorText;

  const _Field({required this.label, required this.child, this.errorText});

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    return Column(
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
        const SizedBox(height: Insets.sm),
        child,
        if (errorText != null) ...[
          const SizedBox(height: Insets.xs + 2),
          Semantics(
            liveRegion: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline_rounded, size: 14, color: t.danger.fg),
                const SizedBox(width: Insets.xs + 2),
                Expanded(
                  child: Text(
                    errorText!,
                    style: TextStyle(fontSize: FontSizes.caption, color: t.danger.fg),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
