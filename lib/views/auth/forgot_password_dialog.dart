import 'package:flutter/material.dart';
import '../../config/theme.dart';
import '../../controllers/auth_controller.dart';

/// Small modal that asks for an email and triggers Firebase's
/// `sendPasswordResetEmail`. The reset link itself is Firebase-hosted.
class ForgotPasswordDialog extends StatefulWidget {
  final String initialEmail;
  const ForgotPasswordDialog({super.key, this.initialEmail = ''});

  @override
  State<ForgotPasswordDialog> createState() => _ForgotPasswordDialogState();
}

class _ForgotPasswordDialogState extends State<ForgotPasswordDialog> {
  final _emailCtrl = TextEditingController();
  final _auth = AuthController();
  bool _sending = false;
  String? _message;
  bool _isError = false;

  @override
  void initState() {
    super.initState();
    _emailCtrl.text = widget.initialEmail;
  }

  Future<void> _send() async {
    final email = _emailCtrl.text.trim();
    if (email.isEmpty) {
      setState(() {
        _message = "Enter your email address.";
        _isError = true;
      });
      return;
    }
    setState(() {
      _sending = true;
      _message = null;
    });
    final err = await _auth.sendPasswordReset(email);
    if (!mounted) return;
    setState(() {
      _sending = false;
      if (err == null) {
        _message = "Reset link sent. Check your inbox (and spam folder).";
        _isError = false;
      } else {
        _message = err;
        _isError = true;
      }
    });
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text("Forgot password"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            "Enter your account email. We'll send a link you can use to set a new password.",
            style: TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _emailCtrl,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(
              labelText: "Email address",
              prefixIcon: Icon(Icons.email_outlined),
            ),
            autofocus: true,
          ),
          if (_message != null) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: (_isError ? AppTheme.errorColor : AppTheme.primaryColor)
                    .withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    _isError ? Icons.error_outline : Icons.mark_email_read_outlined,
                    color: _isError ? AppTheme.errorColor : AppTheme.primaryColor,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _message!,
                      style: TextStyle(
                        fontSize: 12,
                        color: _isError ? AppTheme.errorColor : AppTheme.primaryColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("Close"),
        ),
        ElevatedButton(
          onPressed: _sending ? null : _send,
          child: _sending
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text("Send reset link"),
        ),
      ],
    );
  }
}
