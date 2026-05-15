import 'package:flutter/material.dart';
import '../../controllers/auth_controller.dart'; // Ensure this path is correct
import '../../config/theme.dart';
import 'forgot_password_dialog.dart';

class LoginView extends StatefulWidget {
  const LoginView({super.key});

  @override
  State<LoginView> createState() => _LoginViewState();
}

class _LoginViewState extends State<LoginView> {
  // 1. Define Text Controllers
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  
  // 2. Initialize the AuthController
  final _authController = AuthController();
  
  // 3. State Variables
  bool _isLoading = false;
  String? _errorMessage;
  bool _obscurePassword = true;

  // --- LOGIN LOGIC ---
  void _handleLogin() async {
    // Hide keyboard
    FocusScope.of(context).unfocus();

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    // Call the updated loginUser function from AuthController
    String? error = await _authController.loginUser(
      context: context,
      email: _emailController.text.trim(),
      password: _passwordController.text.trim(),
    );

    // Check if widget is still on screen (mounted) before updating state
    if (!mounted) return;

    setState(() {
      _isLoading = false;
    });

    if (error != null) {
      setState(() {
        _errorMessage = _friendlyAuthError(error);
      });
    }
    // If error is null, AuthController handles the navigation automatically
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
      backgroundColor: Colors.grey[100],
      body: Center(
        child: SingleChildScrollView(
          child: Container(
            width: 400, // Fixed width for Web/Tablet look
            padding: const EdgeInsets.all(40),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.05),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                )
              ],
              // Mint Green Top Border
              border: Border(
                top: BorderSide(color: AppTheme.primaryColor, width: 6),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // --- HEADER ---
                Icon(
                  Icons.lock_person_rounded, 
                  size: 60, 
                  color: AppTheme.primaryColor
                ),
                const SizedBox(height: 10),
                Text(
                  "FieldTrip360",
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: AppTheme.darkText,
                  ),
                ),
                const SizedBox(height: 30),

                // --- ERROR MESSAGE BOX ---
                if (_errorMessage != null)
                  Container(
                    padding: const EdgeInsets.all(12),
                    margin: const EdgeInsets.only(bottom: 20),
                    decoration: BoxDecoration(
                      color: AppTheme.errorColor.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: AppTheme.errorColor.withOpacity(0.5)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline, color: AppTheme.errorColor, size: 20),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: TextStyle(
                              color: AppTheme.errorColor, 
                              fontSize: 13,
                              fontWeight: FontWeight.bold
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                // --- INPUT FIELDS ---
                TextField(
                  controller: _emailController,
                  decoration: const InputDecoration(
                    labelText: "Email Address",
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                ),
                const SizedBox(height: 20),
                
                TextField(
                  controller: _passwordController,
                  obscureText: _obscurePassword,
                  decoration: InputDecoration(
                    labelText: "Password",
                    prefixIcon: const Icon(Icons.lock_outline),
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

                // --- LOGIN BUTTON ---
                SizedBox(
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _handleLogin,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.secondaryColor, // Dolphin Blue
                      elevation: 0,
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                              color: AppTheme.darkText,
                              strokeWidth: 2,
                            ),
                          )
                        : const Text("LOGIN"),
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
    // Clean up controllers
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }
}