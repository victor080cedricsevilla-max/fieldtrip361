import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';

import '../../config/theme.dart';

/// Where an invited teacher turns their code into an account.
///
/// This is the only way to become a facilitator. Registration no longer offers
/// the role, because a facilitator can see where children are, and the school —
/// not the applicant — decides who that is. The address the account is created
/// for comes from the invitation, so holding a code does not let anyone choose
/// whose account it becomes.
class RedeemInviteView extends StatefulWidget {
  const RedeemInviteView({super.key});

  @override
  State<RedeemInviteView> createState() => _RedeemInviteViewState();
}

class _RedeemInviteViewState extends State<RedeemInviteView> {
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();

  bool _busy = false;
  bool _hidePassword = true;
  String? _error;

  static const _minPassword = 12;

  @override
  void dispose() {
    _code.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final code = _code.text.trim();
    final password = _password.text;

    if (code.isEmpty) {
      setState(() => _error = "Enter the invitation code from your email.");
      return;
    }
    if (password.length < _minPassword) {
      setState(() => _error = "Choose a password of at least $_minPassword characters.");
      return;
    }
    if (password != _confirm.text) {
      setState(() => _error = "The two passwords do not match.");
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final res = await FirebaseFunctions.instance
          .httpsCallable('redeemTeacherInvite')
          .call<Map<String, dynamic>>({'code': code, 'password': password});

      final email = (res.data['email'] ?? '').toString();
      final school = (res.data['schoolName'] ?? '').toString();

      // The account exists now; sign them straight in rather than sending them
      // back to type the address they never chose.
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email,
        password: password,
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          school.isEmpty ? "Your account is ready." : "You have joined $school.",
        ),
        backgroundColor: Colors.green,
      ));
      Navigator.pop(context);
    } on FirebaseFunctionsException catch (e) {
      if (mounted) {
        setState(() => _error = e.message ?? "That invitation could not be used.");
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = "Something went wrong. Check your connection and try again.");
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
        title: const Text("Accept your invitation",
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
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
                child: Icon(Icons.mark_email_read_outlined,
                    color: AppTheme.effectivePrimary, size: 28),
              ),
              const SizedBox(height: 18),
              const Text(
                "Set up your facilitator account",
                style: TextStyle(
                    fontSize: 21, fontWeight: FontWeight.bold, color: AppTheme.darkText),
              ),
              const SizedBox(height: 8),
              Text(
                "Your school emailed you an invitation code. Enter it below and choose a "
                "password — we already know which school and which address the account is for.",
                style: TextStyle(fontSize: 13.5, height: 1.5, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 26),

              TextField(
                controller: _code,
                textCapitalization: TextCapitalization.characters,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: "Invitation code",
                  hintText: "e.g. NUB-7K4P-92XM",
                  filled: true,
                  fillColor: Colors.white,
                  prefixIcon: const Icon(Icons.vpn_key_outlined),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 14),

              TextField(
                controller: _password,
                obscureText: _hidePassword,
                decoration: InputDecoration(
                  labelText: "Create a password",
                  helperText: "At least $_minPassword characters",
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
                  labelText: "Repeat the password",
                  filled: true,
                  fillColor: Colors.white,
                  prefixIcon: const Icon(Icons.lock_outline_rounded),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
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
                    style: const TextStyle(fontSize: 13, color: Color(0xFF9B2C20), height: 1.4),
                  ),
                ),
              ],

              const SizedBox(height: 26),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed: _busy ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.effectivePrimary,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _busy
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text("Create my account",
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
              const SizedBox(height: 18),
              Text(
                "No invitation? Ask your school administrator to send one to your school "
                "email address.",
                style: TextStyle(fontSize: 12.5, height: 1.5, color: Colors.grey.shade500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
