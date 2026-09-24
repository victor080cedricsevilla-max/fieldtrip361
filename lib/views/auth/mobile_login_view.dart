import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../controllers/auth_controller.dart';
import '../../config/theme.dart';
import 'register_view.dart';
import 'redeem_invite_view.dart';
import 'forgot_password_dialog.dart';

class MobileLoginView extends StatefulWidget {
  const MobileLoginView({super.key});

  @override
  State<MobileLoginView> createState() => _MobileLoginViewState();
}

class _MobileLoginViewState extends State<MobileLoginView> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _authController = AuthController();
  
  bool _isLoading = false;
  String? _errorMessage;
  bool _obscurePassword = true;

  @override
  void initState() {
    super.initState();
    _checkExistingSession();
  }

  Future<void> _checkExistingSession() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      // Verify the session token matches — if not, another device logged in
      final prefs = await SharedPreferences.getInstance();
      final localSession = prefs.getString('activeSession');
      final snap = await FirebaseFirestore.instance.collection('users').doc(user.uid).get();
      final data = snap.data();
      if (data == null) return;
      final firestoreSession = data['activeSession'] as String?;
      // If both tokens exist and they differ, this device was displaced
      if (localSession != null && firestoreSession != null && localSession != firestoreSession) {
        await FirebaseAuth.instance.signOut();
        await prefs.remove('activeSession');
        if (mounted) {
          setState(() => _errorMessage = 'You were logged out because your account signed in on another device.');
        }
        return;
      }
      // Session is valid — route to the right dashboard
      final role = (data['role'] ?? '').toString();
      if (!mounted) return;
      switch (role) {
        case 'admin':   Navigator.pushReplacementNamed(context, '/admin/dashboard'); break;
        case 'teacher': Navigator.pushReplacementNamed(context, '/teacher/dashboard'); break;
        case 'student': Navigator.pushReplacementNamed(context, '/student/dashboard'); break;
        case 'parent':  Navigator.pushReplacementNamed(context, '/parent/dashboard'); break;
      }
    } catch (_) {}
  }

  void _handleLogin() async {
    FocusScope.of(context).unfocus();

    final email = _emailController.text.trim();
    final password = _passwordController.text.trim();

    if (email.isEmpty && password.isEmpty) {
      setState(() => _errorMessage = "Please enter your email and password.");
      return;
    }
    if (email.isEmpty) {
      setState(() => _errorMessage = "Please enter your email.");
      return;
    }
    if (password.isEmpty) {
      setState(() => _errorMessage = "Please enter your password.");
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    String? error = await _authController.loginUser(
      context: context,
      email: _emailController.text.trim(),
      password: _passwordController.text.trim(),
    );

    if (mounted) {
      setState(() {
        _isLoading = false;
        if (error != null) _errorMessage = _friendlyAuthError(error);
      });
    }
  }

  String _friendlyAuthError(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('wrong-password') ||
        lower.contains('invalid-credential') ||
        lower.contains('invalid-login-credentials') ||
        lower.contains('incorrect')) {
      return "Incorrect email or password. Please try again.";
    }
    if (lower.contains('user-not-found') || lower.contains('no user record')) {
      return "No account found for that email.";
    }
    if (lower.contains('too-many-requests')) {
      return "Too many attempts. Please try again later.";
    }
    if (lower.contains('network')) {
      return "Network error. Check your connection.";
    }
    if (lower.contains('not-verified') || lower.contains('verify your email')) {
      return "Please verify your email before logging in.";
    }
    if (lower.contains('invalid-email') || lower.contains('badly formatted')) {
      return "Please enter a valid email address.";
    }
    return "Login failed. Please check your credentials and try again.";
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(30),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Logo / Branding
              Image.asset(
                "assets/icon/ft360_logo.png",
                height: 120,
                // A missing asset would otherwise blank the whole login screen,
                // leaving no way in. Fall back to the mark we shipped before.
                errorBuilder: (_, __, ___) => Icon(
                  Icons.directions_bus_filled,
                  size: 80,
                  color: AppTheme.effectivePrimary,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                "FieldTrip360",
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: AppTheme.darkText,
                ),
              ),
              const Text("Student & Faculty Portal", textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 40),

              if (_errorMessage != null)
                Container(
                  padding: const EdgeInsets.all(10),
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: AppTheme.errorColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(_errorMessage!, style: TextStyle(color: AppTheme.errorColor)),
                ),

              // Inputs
              TextField(
                controller: _emailController,
                decoration: const InputDecoration(labelText: "Email", prefixIcon: Icon(Icons.email)),
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
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => showDialog(
                    context: context,
                    builder: (_) => ForgotPasswordDialog(
                      initialEmail: _emailController.text.trim(),
                    ),
                  ),
                  child: Text(
                    "Forgot password?",
                    style: TextStyle(color: AppTheme.effectivePrimary, fontWeight: FontWeight.w600),
                  ),
                ),
              ),
              const SizedBox(height: 14),

              // Login Button
              SizedBox(
                height: 50,
                child: ElevatedButton(
                  onPressed: _isLoading ? null : _handleLogin,
                  style: ElevatedButton.styleFrom(backgroundColor: AppTheme.secondaryColor),
                  child: _isLoading ? const CircularProgressIndicator() : const Text("LOGIN"),
                ),
              ),
              const SizedBox(height: 20),

              // Sign Up Link
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text("No account yet?"),
                  TextButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => const RegisterView()),
                      );
                    },
                    child: Text("Sign Up", style: TextStyle(color: AppTheme.effectivePrimary, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),

              // Teachers do not sign up — their school invites them, and this is
              // where that invitation becomes an account.
              TextButton.icon(
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (context) => const RedeemInviteView()),
                  );
                },
                icon: const Icon(Icons.vpn_key_outlined, size: 17),
                label: const Text("I have an invitation code"),
                style: TextButton.styleFrom(foregroundColor: Colors.grey.shade600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}