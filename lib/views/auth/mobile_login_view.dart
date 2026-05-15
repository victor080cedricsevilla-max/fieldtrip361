import 'package:flutter/material.dart';
import '../../controllers/auth_controller.dart';
import '../../config/theme.dart';
import 'register_view.dart'; // Import Register View
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

  void _handleLogin() async {
    FocusScope.of(context).unfocus();
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
    return raw;
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
              Icon(Icons.directions_bus_filled, size: 80, color: AppTheme.primaryColor),
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
                    color: AppTheme.errorColor.withOpacity(0.1),
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
                  child: const Text(
                    "Forgot password?",
                    style: TextStyle(color: AppTheme.primaryColor, fontWeight: FontWeight.w600),
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
                  const Text("No account yet?"),
                  TextButton(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (context) => const RegisterView()),
                      );
                    },
                    child: Text("Sign Up", style: TextStyle(color: AppTheme.primaryColor, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}