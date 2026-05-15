import 'dart:io';
// ignore: unnecessary_import — kIsWeb isn't actually re-exported by material.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import '../../config/theme.dart';

/// Shared Settings screen used by teacher / student / parent.
/// Set [allowEmergencySoundUpload] to false to hide that section (parent / student).
class SettingsView extends StatefulWidget {
  final bool allowEmergencySoundUpload;
  const SettingsView({super.key, this.allowEmergencySoundUpload = false});

  @override
  State<SettingsView> createState() => _SettingsViewState();
}

class _SettingsViewState extends State<SettingsView> {
  final _firestore = FirebaseFirestore.instance;
  final _auth = FirebaseAuth.instance;
  final _storage = FirebaseStorage.instance;

  bool _loading = true;
  Map<String, dynamic> _userData = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final uid = _auth.currentUser?.uid;
    if (uid == null) return;
    final snap = await _firestore.collection('users').doc(uid).get();
    if (!mounted) return;
    setState(() {
      _userData = snap.data() ?? {};
      _loading = false;
    });
  }

  Future<void> _pickAndUploadProfilePhoto() async {
    final picker = ImagePicker();
    final XFile? file = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 800,
      imageQuality: 85,
    );
    if (file == null) return;

    final uid = _auth.currentUser!.uid;
    // Path includes an extension only for clarity; the actual content-type is
    // sent below via SettableMetadata.
    final ref = _storage.ref().child('profile_photos/$uid.jpg');
    try {
      _showSnack("Uploading photo…", Colors.blue);

      // Read bytes — this works on every platform (web included).
      // `putFile(File(path))` does NOT work on Flutter Web because XFile.path
      // is a blob URL, and that's what produced the "object-not-found" error.
      final bytes = await file.readAsBytes();
      final metadata = SettableMetadata(
        contentType: file.mimeType ?? 'image/jpeg',
      );
      final task = await ref.putData(bytes, metadata);
      // Grab the URL from the snapshot's own ref to avoid any race.
      final url = await task.ref.getDownloadURL();

      await _firestore.collection('users').doc(uid).update({'photoUrl': url});
      if (!mounted) return;
      setState(() => _userData['photoUrl'] = url);
      _showSnack("Profile photo updated.", Colors.green);
    } on FirebaseException catch (e) {
      _showSnack("Failed to upload: ${e.code} ${e.message ?? ''}", Colors.red);
    } catch (e) {
      _showSnack("Failed to upload: $e", Colors.red);
    }
  }

  Future<void> _pickAndUploadEmergencySound() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.audio,
      // withData: true ensures bytes are available on every platform (including web).
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.single;
    final uid = _auth.currentUser!.uid;
    final name = picked.name;
    final ref = _storage.ref().child('emergency_sounds/$uid/$name');
    try {
      _showSnack("Uploading sound…", Colors.blue);

      // Prefer the bytes the picker already provided. On native, fall back to
      // reading the file from disk if bytes are null.
      final List<int> data = picked.bytes != null
          ? picked.bytes!
          : (!kIsWeb && picked.path != null
              ? await File(picked.path!).readAsBytes()
              : const []);
      if (data.isEmpty) {
        _showSnack("Could not read the chosen file.", Colors.red);
        return;
      }

      final task = await ref.putData(
        Uint8List.fromList(data),
        SettableMetadata(contentType: 'audio/mpeg'),
      );
      final url = await task.ref.getDownloadURL();
      await _firestore.collection('users').doc(uid).update({
        'emergencySoundUrl': url,
        'emergencySoundName': name,
      });
      if (!mounted) return;
      setState(() {
        _userData['emergencySoundUrl'] = url;
        _userData['emergencySoundName'] = name;
      });
      _showSnack("Emergency sound updated.", Colors.green);
    } on FirebaseException catch (e) {
      _showSnack("Failed to upload: ${e.code} ${e.message ?? ''}", Colors.red);
    } catch (e) {
      _showSnack("Failed to upload: $e", Colors.red);
    }
  }

  Future<void> _resetEmergencySoundToDefault() async {
    final uid = _auth.currentUser!.uid;
    await _firestore.collection('users').doc(uid).update({
      'emergencySoundUrl': FieldValue.delete(),
      'emergencySoundName': FieldValue.delete(),
    });
    if (!mounted) return;
    setState(() {
      _userData.remove('emergencySoundUrl');
      _userData.remove('emergencySoundName');
    });
    _showSnack("Reverted to default sound.", Colors.green);
  }

  Future<void> _changeName() async {
    final ctrl = TextEditingController(text: _userData['name'] ?? '');
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Change name"),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(labelText: "Full name"),
          autofocus: true,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text("Save"),
          ),
        ],
      ),
    );
    if (newName == null || newName.isEmpty) return;
    final uid = _auth.currentUser!.uid;
    await _firestore.collection('users').doc(uid).update({'name': newName});
    if (!mounted) return;
    setState(() => _userData['name'] = newName);
    _showSnack("Name updated.", Colors.green);
  }

  Future<void> _changeEmail() async {
    final ctrl = TextEditingController(text: _userData['email'] ?? '');
    final pwCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Change email"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: ctrl,
              decoration: const InputDecoration(labelText: "New email"),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: pwCtrl,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: "Current password (required)",
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              "We'll send a confirmation link to the new email. The change takes effect when you click that link.",
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text("Save")),
        ],
      ),
    );
    if (ok != true) return;

    final newEmail = ctrl.text.trim();
    if (newEmail.isEmpty) return;
    final user = _auth.currentUser!;
    try {
      // Re-authenticate for sensitive change.
      final cred = EmailAuthProvider.credential(
        email: user.email!,
        password: pwCtrl.text,
      );
      await user.reauthenticateWithCredential(cred);
      await user.verifyBeforeUpdateEmail(newEmail);
      await _firestore.collection('users').doc(user.uid).update({'pendingEmail': newEmail});
      if (!mounted) return;
      _showSnack("Verification email sent to $newEmail.", Colors.green);
    } on FirebaseAuthException catch (e) {
      _showSnack(e.message ?? "Failed to change email.", Colors.red);
    } catch (e) {
      _showSnack("Failed: $e", Colors.red);
    }
  }

  Future<void> _changePassword() async {
    final email = _auth.currentUser?.email ?? _userData['email']?.toString() ?? '';
    if (email.isEmpty) {
      _showSnack("Your account has no email on file.", Colors.red);
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("Change password"),
        content: Text(
          "We'll send a password reset link to:\n$email\n\nOpen that email and follow the link to set a new password.",
          style: const TextStyle(fontSize: 13, height: 1.4),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Send reset link"),
          ),
        ],
      ),
    );
    if (ok != true) return;

    try {
      await _auth.sendPasswordResetEmail(email: email);
      if (!mounted) return;
      _showSnack("Reset link sent to $email.", Colors.green);
    } on FirebaseAuthException catch (e) {
      _showSnack(e.message ?? "Failed to send reset link.", Colors.red);
    }
  }

  void _showSnack(String msg, Color color) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      content: Text(msg),
      backgroundColor: color,
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator(color: AppTheme.primaryColor)),
      );
    }
    final String name = _userData['name'] ?? '';
    final String email = _userData['email'] ?? '';
    final String? photoUrl = _userData['photoUrl'];
    final String role = (_userData['role'] ?? '').toString();
    final String? customSoundName = _userData['emergencySoundName'];

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text("Settings",
            style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
                color: AppTheme.secondaryColor)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              size: 20, color: AppTheme.secondaryColor),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _section("Personal Information"),
            const SizedBox(height: 12),
            _card(
              child: Column(
                children: [
                  Row(
                    children: [
                      GestureDetector(
                        onTap: _pickAndUploadProfilePhoto,
                        child: Stack(
                          children: [
                            CircleAvatar(
                              radius: 36,
                              backgroundColor:
                                  AppTheme.primaryColor.withValues(alpha: 0.12),
                              backgroundImage: (photoUrl != null && photoUrl.isNotEmpty)
                                  ? NetworkImage(photoUrl)
                                  : null,
                              child: (photoUrl == null || photoUrl.isEmpty)
                                  ? Text(
                                      name.isNotEmpty ? name[0].toUpperCase() : '?',
                                      style: const TextStyle(
                                          fontSize: 26,
                                          fontWeight: FontWeight.bold,
                                          color: AppTheme.primaryColor),
                                    )
                                  : null,
                            ),
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: AppTheme.primaryColor,
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.white, width: 2),
                                ),
                                child: const Icon(Icons.camera_alt_rounded,
                                    size: 12, color: Colors.white),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(name,
                                style: const TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: AppTheme.secondaryColor,
                                )),
                            if (role.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(role.toUpperCase(),
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: Colors.grey.shade500,
                                      letterSpacing: 0.5,
                                    )),
                              ),
                            const SizedBox(height: 4),
                            Text("Tap photo to change",
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Colors.grey.shade500,
                                )),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Divider(color: Colors.grey.shade100),
                  _tile(
                    icon: Icons.person_outline_rounded,
                    label: "Full Name",
                    value: name,
                    onTap: _changeName,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            _section("Account & Security"),
            const SizedBox(height: 12),
            _card(
              child: Column(
                children: [
                  _tile(
                    icon: Icons.email_outlined,
                    label: "Email Address",
                    value: email,
                    onTap: _changeEmail,
                  ),
                  Divider(color: Colors.grey.shade100, height: 1),
                  _tile(
                    icon: Icons.lock_outline_rounded,
                    label: "Password",
                    value: "Send reset link via email",
                    onTap: _changePassword,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            _section("Appearance"),
            const SizedBox(height: 12),
            _card(
              child: ValueListenableBuilder<ThemeMode>(
                valueListenable: AppTheme.mode,
                builder: (context, mode, _) {
                  final bool isDark = mode == ThemeMode.dark;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                    child: Row(
                      children: [
                        Container(
                          width: 36,
                          height: 36,
                          decoration: BoxDecoration(
                            color: AppTheme.primaryColor.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(
                            isDark ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
                            size: 18,
                            color: AppTheme.primaryColor,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text("Dark Mode",
                                  style: TextStyle(
                                      fontSize: 11,
                                      color: Colors.grey.shade500,
                                      fontWeight: FontWeight.w500)),
                              const SizedBox(height: 2),
                              Text(
                                isDark ? "Enabled" : "Off",
                                style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.secondaryColor),
                              ),
                            ],
                          ),
                        ),
                        Switch.adaptive(
                          value: isDark,
                          activeThumbColor: AppTheme.primaryColor,
                          onChanged: (v) => AppTheme.setMode(
                            v ? ThemeMode.dark : ThemeMode.light,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            if (widget.allowEmergencySoundUpload) ...[
              const SizedBox(height: 22),
              _section("Emergency Sound"),
              const SizedBox(height: 12),
              _card(
                child: Column(
                  children: [
                    _tile(
                      icon: Icons.notifications_active_outlined,
                      label: "Custom Emergency Sound",
                      value: customSoundName ?? "Default",
                      onTap: _pickAndUploadEmergencySound,
                    ),
                    if (customSoundName != null) ...[
                      Divider(color: Colors.grey.shade100, height: 1),
                      _tile(
                        icon: Icons.restore_rounded,
                        label: "Reset to default",
                        value: "",
                        valueColor: Colors.orange,
                        onTap: _resetEmergencySoundToDefault,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  "Upload an MP3 or WAV to play instead of the default alarm.",
                  style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _section(String label) {
    return Text(label,
        style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppTheme.secondaryColor,
            letterSpacing: 0.3));
  }

  Widget _card({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 10,
              offset: const Offset(0, 4))
        ],
      ),
      padding: const EdgeInsets.all(14),
      child: child,
    );
  }

  Widget _tile({
    required IconData icon,
    required String label,
    required String value,
    required VoidCallback onTap,
    Color? valueColor,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppTheme.primaryColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: AppTheme.primaryColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          fontSize: 11,
                          color: Colors.grey.shade500,
                          fontWeight: FontWeight.w500)),
                  const SizedBox(height: 2),
                  Text(value,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: valueColor ?? AppTheme.secondaryColor,
                      )),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, color: Colors.grey),
          ],
        ),
      ),
    );
  }
}
