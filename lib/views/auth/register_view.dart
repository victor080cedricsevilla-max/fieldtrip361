import 'package:flutter/material.dart';
import '../../../controllers/auth_controller.dart';
import '../../../config/theme.dart';
import 'terms_agreement_box.dart';
import 'terms_content.dart';

enum _PasswordStrength { empty, weak, moderate, strong }

extension _PasswordStrengthX on _PasswordStrength {
  String get label {
    switch (this) {
      case _PasswordStrength.empty:
        return "";
      case _PasswordStrength.weak:
        return "Weak";
      case _PasswordStrength.moderate:
        return "Moderate";
      case _PasswordStrength.strong:
        return "Strong";
    }
  }

  Color get color {
    switch (this) {
      case _PasswordStrength.empty:
        return Colors.grey;
      case _PasswordStrength.weak:
        return Colors.red.shade400;
      case _PasswordStrength.moderate:
        return Colors.orange.shade400;
      case _PasswordStrength.strong:
        return Colors.green.shade500;
    }
  }

  double get fraction {
    switch (this) {
      case _PasswordStrength.empty:
        return 0;
      case _PasswordStrength.weak:
        return 0.33;
      case _PasswordStrength.moderate:
        return 0.66;
      case _PasswordStrength.strong:
        return 1.0;
    }
  }
}

_PasswordStrength _evaluatePassword(String pw) {
  if (pw.isEmpty) return _PasswordStrength.empty;
  int score = 0;
  if (pw.length >= 8) score++;
  if (pw.length >= 12) score++;
  if (RegExp(r'[A-Z]').hasMatch(pw) && RegExp(r'[a-z]').hasMatch(pw)) score++;
  if (RegExp(r'\d').hasMatch(pw)) score++;
  if (RegExp(r'[^A-Za-z0-9]').hasMatch(pw)) score++;
  if (score <= 2) return _PasswordStrength.weak;
  if (score == 3 || score == 4) return _PasswordStrength.moderate;
  return _PasswordStrength.strong;
}

bool _isValidEmail(String email) {
  return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(email);
}

class RegisterView extends StatefulWidget {
  const RegisterView({super.key});

  @override
  State<RegisterView> createState() => _RegisterViewState();
}

class _RegisterViewState extends State<RegisterView> {
  final _firstNameController = TextEditingController();
  final _surnameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _lrnController = TextEditingController();
  final _activationCodeController = TextEditingController();
  final _authController = AuthController();

  String _selectedRole = 'student';
  final List<String> _roles = ['student', 'parent', 'teacher'];

  bool _isLoading = false;
  String? _errorMessage;
  bool _obscurePassword = true;
  _PasswordStrength _pwStrength = _PasswordStrength.empty;

  /// Only true once the notice has been scrolled through and the box ticked —
  /// the panel itself refuses to tick before that.
  bool _agreedToTerms = false;

  @override
  void initState() {
    super.initState();
    _passwordController.addListener(() {
      final s = _evaluatePassword(_passwordController.text);
      if (s != _pwStrength) setState(() => _pwStrength = s);
    });
  }

  void _handleRegister() async {
    FocusScope.of(context).unfocus();

    if (_firstNameController.text.trim().isEmpty ||
        _surnameController.text.trim().isEmpty ||
        _emailController.text.isEmpty ||
        _passwordController.text.isEmpty) {
      setState(() => _errorMessage = "Fill in all fields.");
      return;
    }

    if (!_isValidEmail(_emailController.text.trim())) {
      setState(() => _errorMessage = "Enter a valid email address.");
      return;
    }

    if (_pwStrength == _PasswordStrength.weak) {
      setState(() => _errorMessage = "Password is too weak. Use 8+ characters with letters, numbers, and a symbol.");
      return;
    }

    if (_selectedRole == 'student' && _lrnController.text.isEmpty) {
      setState(() => _errorMessage = "Enter your LRN.");
      return;
    }

    // Backstop for the disabled button: consent is what makes the rest of this
    // lawful, so it is checked here too and not only in the widget tree.
    if (!_agreedToTerms) {
      setState(() => _errorMessage =
          "Please read the Terms & Conditions to the end and tick the box to continue.");
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();

    final String firstName = _firstNameController.text.trim();
    final String surname = _surnameController.text.trim();
    String? error = await _authController.registerUser(
      email: email,
      password: password,
      name: "$firstName $surname",
      firstName: firstName,
      surname: surname,
      role: _selectedRole,
      lrn: _selectedRole == 'student' ? _lrnController.text.trim() : null,
      activationCode:
          _selectedRole == 'parent' ? _activationCodeController.text.trim() : null,
      acceptedTermsVersion: kTermsVersion,
    );

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (error == null) {
      // The account exists either way; a rejected code is a warning, not a
      // failed sign-up, so say so plainly instead of leaving them guessing why
      // no child appeared.
      final codeProblem = _authController.lastActivationError;
      if (codeProblem != null) {
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            title: const Text("Account created"),
            content: Text(
              "$codeProblem\n\n"
              "You can sign in normally and add your child from the app once you "
              "have a valid code from the school.",
              style: const TextStyle(fontSize: 13.5, height: 1.5),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text("Continue"),
              ),
            ],
          ),
        );
        if (!mounted) return;
      }

      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => VerifyEmailView(email: email, password: password),
        ),
      );
    } else {
      setState(() => _errorMessage = error);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Create Account"),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppTheme.darkText),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(30),
          // Phones are narrower than this, so the cap only bites on the web
          // build, where a full-window form would stretch the terms panel into
          // unreadable lines.
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  "Sign Up",
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: AppTheme.effectivePrimary,
                      ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 10),
                const Text(
                  "Select your role to get started",
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Colors.grey),
                ),
                const SizedBox(height: 30),

                if (_errorMessage != null)
                  Container(
                    padding: const EdgeInsets.all(10),
                    margin: const EdgeInsets.only(bottom: 20),
                    color: AppTheme.errorColor.withValues(alpha: 0.1),
                    child: Text(_errorMessage!, style: const TextStyle(color: AppTheme.errorColor)),
                  ),

                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _firstNameController,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: "First Name",
                          prefixIcon: Icon(Icons.person_outline),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextField(
                        controller: _surnameController,
                        textCapitalization: TextCapitalization.words,
                        decoration: const InputDecoration(
                          labelText: "Surname",
                          prefixIcon: Icon(Icons.badge_outlined),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 15),

                TextField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: "Email Address", prefixIcon: Icon(Icons.email)),
                ),
                const SizedBox(height: 15),

                TextField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    labelText: "Password",
                    prefixIcon: const Icon(Icons.lock),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscurePassword ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                      ),
                      tooltip: _obscurePassword ? "Show password" : "Hide password",
                      onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                ),
                if (_pwStrength != _PasswordStrength.empty) ...[
                  const SizedBox(height: 8),
                  _PasswordStrengthBar(strength: _pwStrength),
                ],
                const SizedBox(height: 20),

                const Text("I am a:", style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 5),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.grey[300]!),
                    borderRadius: BorderRadius.circular(8),
                    color: Colors.grey[50],
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _selectedRole,
                      isExpanded: true,
                      items: _roles.map((String role) {
                        return DropdownMenuItem<String>(
                          value: role,
                          child: Text(role.toUpperCase(), style: const TextStyle(fontWeight: FontWeight.bold)),
                        );
                      }).toList(),
                      onChanged: (String? newValue) {
                        setState(() {
                          _selectedRole = newValue!;
                        });
                      },
                    ),
                  ),
                ),

                if (_selectedRole == 'student') ...[
                  const SizedBox(height: 20),
                  TextField(
                    controller: _lrnController,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: "Learner Reference Number (LRN)",
                      prefixIcon: Icon(Icons.badge),
                    ),
                  ),
                ],

                // The code the school emailed the guardian. It is what ties this
                // account to a specific child — a parent cannot pick a student
                // themselves, which is the point.
                if (_selectedRole == 'parent') ...[
                  const SizedBox(height: 20),
                  TextField(
                    controller: _activationCodeController,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(
                      labelText: "Parent Activation Code",
                      hintText: "e.g. NU-7K4P-92XM",
                      prefixIcon: Icon(Icons.vpn_key_outlined),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.info_outline_rounded, size: 15, color: Colors.grey.shade500),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        "Your child's school emails this code to you. Leave it blank if "
                        "you don't have it yet — you can add your child later from the app.",
                        style: TextStyle(
                            fontSize: 11.5, color: Colors.grey.shade600, height: 1.4),
                      ),
                    ),
                  ]),
                ],

                const SizedBox(height: 26),

                // Consent gate: the account cannot be created until this notice
                // has actually been scrolled through and agreed to.
                TermsAgreementBox(
                  accepted: _agreedToTerms,
                  onAcceptedChanged: (value) => setState(() {
                    _agreedToTerms = value;
                    if (value) _errorMessage = null;
                  }),
                ),

                const SizedBox(height: 22),

                SizedBox(
                  height: 50,
                  child: ElevatedButton(
                    onPressed:
                        (_isLoading || !_agreedToTerms) ? null : _handleRegister,
                    style: ElevatedButton.styleFrom(backgroundColor: AppTheme.effectivePrimary),
                    child: _isLoading
                        ? const CircularProgressIndicator(color: Colors.white)
                        : const Text(
                            "CREATE ACCOUNT",
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _surnameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    _lrnController.dispose();
    _activationCodeController.dispose();
    super.dispose();
  }
}

class _PasswordStrengthBar extends StatelessWidget {
  final _PasswordStrength strength;
  const _PasswordStrengthBar({required this.strength});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: strength.fraction,
            minHeight: 6,
            backgroundColor: Colors.grey.shade200,
            valueColor: AlwaysStoppedAnimation<Color>(strength.color),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          "Password strength: ${strength.label}",
          style: TextStyle(color: strength.color, fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

class VerifyEmailView extends StatefulWidget {
  final String email;
  final String password;
  const VerifyEmailView({super.key, required this.email, required this.password});

  @override
  State<VerifyEmailView> createState() => _VerifyEmailViewState();
}

class _VerifyEmailViewState extends State<VerifyEmailView> {
  final _authController = AuthController();
  bool _isResending = false;
  String? _message;
  bool _messageIsError = false;

  Future<void> _resend() async {
    setState(() {
      _isResending = true;
      _message = null;
    });
    final err = await _authController.resendVerificationEmail(
      email: widget.email,
      password: widget.password,
    );
    if (!mounted) return;
    setState(() {
      _isResending = false;
      if (err == null) {
        _message = "Verification email re-sent. Check your inbox.";
        _messageIsError = false;
      } else {
        _message = err;
        _messageIsError = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Verify Email"),
        backgroundColor: Colors.transparent,
        elevation: 0,
        iconTheme: const IconThemeData(color: AppTheme.darkText),
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(30),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(Icons.mark_email_unread_rounded, size: 80, color: AppTheme.effectivePrimary),
              const SizedBox(height: 16),
              Text(
                "Confirm your email",
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: AppTheme.darkText,
                    ),
              ),
              const SizedBox(height: 12),
              Text(
                "We sent a confirmation link to:\n${widget.email}\n\nOpen it to activate your account before logging in.",
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, height: 1.4),
              ),
              const SizedBox(height: 24),
              if (_message != null)
                Container(
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: (_messageIsError ? AppTheme.errorColor : AppTheme.effectivePrimary)
                        .withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _message!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: _messageIsError ? AppTheme.errorColor : AppTheme.effectivePrimary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              SizedBox(
                height: 50,
                child: OutlinedButton.icon(
                  onPressed: _isResending ? null : _resend,
                  icon: _isResending
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.refresh_rounded),
                  label: Text(_isResending ? "Sending--" : "Resend verification email"),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 50,
                child: ElevatedButton(
                  onPressed: () => Navigator.of(context).popUntil((r) => r.isFirst),
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.effectivePrimary),
                  child: const Text(
                    "BACK TO LOGIN",
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
