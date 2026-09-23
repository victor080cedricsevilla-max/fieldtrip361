import 'dart:io';
// ignore: unnecessary_import -- kIsWeb isn't actually re-exported by material.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import '../../config/theme.dart';
import 'subscription_section.dart';
import 'support_view.dart';

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
    final ref = _storage.ref('profile_photos/$uid.jpg');
    try {
      _showSnack("Uploading photo…", Colors.blue);

      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) {
        _showSnack("Could not read image data.", Colors.red);
        return;
      }
      // Explicit content-type so Storage never rejects with type mismatch.
      final task = await ref.putData(
        bytes,
        SettableMetadata(contentType: 'image/jpeg'),
      );
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
      return Scaffold(
        body: Center(child: CircularProgressIndicator(color: AppTheme.effectivePrimary)),
      );
    }
    final String name = _userData['name'] ?? '';
    final String email = _userData['email'] ?? '';
    final String? photoUrl = _userData['photoUrl'];
    final String role = (_userData['role'] ?? '').toString();
    final String? customSoundName = _userData['emergencySoundName'];
    final Color currentThemeColor = AppTheme.effectivePrimary;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        // Settings is reached from a dashboard tab, not pushed as a route, so
        // there is nothing to go back to.
        automaticallyImplyLeading: false,
        titleSpacing: 20,
        title: const Text("Settings",
            style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
                color: AppTheme.secondaryColor)),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 40),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _collapsible(
              icon: Icons.badge_outlined,
              label: "Personal Information",
              subtitle: name,
              initiallyExpanded: true,
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
                                  AppTheme.effectivePrimary.withValues(alpha: 0.12),
                              backgroundImage: (photoUrl != null && photoUrl.isNotEmpty)
                                  ? NetworkImage(photoUrl)
                                  : null,
                              child: (photoUrl == null || photoUrl.isEmpty)
                                  ? Text(
                                      name.isNotEmpty ? name[0].toUpperCase() : '?',
                                      style: TextStyle(
                                          fontSize: 26,
                                          fontWeight: FontWeight.bold,
                                          color: AppTheme.effectivePrimary),
                                    )
                                  : null,
                            ),
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: BoxDecoration(
                                  color: AppTheme.effectivePrimary,
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
            _collapsible(
              icon: Icons.shield_outlined,
              label: "Account & Security",
              subtitle: email,
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
            if (widget.allowEmergencySoundUpload)
              _collapsible(
                icon: Icons.notifications_active_outlined,
                label: "Emergency Sound",
                subtitle: customSoundName ?? "Default",
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
                    const SizedBox(height: 8),
                    Text(
                      "Upload an MP3 or WAV to play instead of the default alarm.",
                      style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
                    ),
                  ],
                ),
              ),
            // Only a school admin has a plan to manage.
            if (role == 'admin')
              _collapsible(
                icon: Icons.workspace_premium_outlined,
                label: "Subscription",
                subtitle: "Plan, capacity and upgrades",
                child: const SubscriptionSection(),
              ),
            // Reachable from every app, because a support request is the same
            // act for an admin, a teacher, a student and a parent.
            _collapsible(
              icon: Icons.support_agent_outlined,
              label: "Help & Support",
              subtitle: "Ask the FieldTrip360 team",
              child: Column(
                children: [
                  _tile(
                    icon: Icons.chat_bubble_outline_rounded,
                    label: "Support requests",
                    value: "Send one, or read a reply",
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SupportView()),
                    ),
                  ),
                ],
              ),
            ),
            _collapsible(
              icon: Icons.palette_outlined,
              label: "App Theme Color",
              subtitle:
                  '#${currentThemeColor.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: currentThemeColor,
                          borderRadius: BorderRadius.circular(12),
                          boxShadow: [BoxShadow(color: currentThemeColor.withValues(alpha: 0.4), blurRadius: 8, offset: const Offset(0, 3))],
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text("Current color",
                                style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w500)),
                            const SizedBox(height: 2),
                            Text(
                              '#${currentThemeColor.toARGB32().toRadixString(16).substring(2).toUpperCase()}',
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: currentThemeColor),
                            ),
                          ],
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => _showColorPicker(context),
                        icon: Icon(Icons.palette_rounded, size: 16, color: currentThemeColor),
                        label: Text("Change", style: TextStyle(color: currentThemeColor, fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Divider(color: Colors.grey.shade100),
                  const SizedBox(height: 8),
                  Text("Tap a color to preview (light colors are auto-darkened)",
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
                  const SizedBox(height: 10),
                  _ColorSwatchRow(
                    current: currentThemeColor,
                    onPick: (c) => _applyThemeColor(c),
                  ),
                ],
              ),
            ),
            _collapsible(
              icon: Icons.brightness_6_outlined,
              label: "Appearance",
              subtitle: _appearanceLabel(AppTheme.mode.value),
              child: const _AppearancePicker(),
            ),
          ],
        ),
      ),
    );
  }

  static String _appearanceLabel(ThemeMode m) => switch (m) {
        ThemeMode.light => 'Light',
        ThemeMode.dark => 'Dark',
        ThemeMode.system => 'System default',
      };

  Future<void> _showColorPicker(BuildContext context) async {
    final picked = await showDialog<Color>(
      context: context,
      builder: (ctx) => _ColorPickerDialog(current: AppTheme.effectivePrimary),
    );
    if (picked != null) _applyThemeColor(picked);
  }

  Future<void> _applyThemeColor(Color color) async {
    AppTheme.setPrimaryColor(color);
    final saved = AppTheme.effectivePrimary.toARGB32();
    final uid = _auth.currentUser?.uid;
    if (uid != null) {
      await _firestore.collection('users').doc(uid).update({'themeColor': saved});
    }
    if (!mounted) return;
    setState(() => _userData['themeColor'] = saved);
  }

  /// A settings group that folds away.
  ///
  /// The page grew past what fits on one screen once Subscription was added, so
  /// each group collapses and shows a one-line summary in its header — the value
  /// you usually came to check is visible without opening anything.
  Widget _collapsible({
    required IconData icon,
    required String label,
    String? subtitle,
    bool initiallyExpanded = false,
    required Widget child,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
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
      clipBehavior: Clip.antiAlias,
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: initiallyExpanded,
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
          leading: Container(
            width: 38,
            height: 38,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 19, color: AppTheme.effectivePrimary),
          ),
          title: Text(label,
              style: const TextStyle(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.secondaryColor)),
          subtitle: (subtitle == null || subtitle.isEmpty)
              ? null
              : Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500)),
                ),
          children: [child],
        ),
      ),
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
                color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: AppTheme.effectivePrimary),
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

// ─────────────────────────────────────────────────────────────────────────────
// Color picker helpers
// ─────────────────────────────────────────────────────────────────────────────

const _kPresetColors = [
  Color(0xFF00897B), // Teal
  Color(0xFF1565C0), // Blue
  Color(0xFF6A1B9A), // Purple
  Color(0xFF283593), // Indigo
  Color(0xFFC62828), // Red
  Color(0xFFAD1457), // Pink
  Color(0xFFE65100), // Orange
  Color(0xFF2E7D32), // Green
  Color(0xFF00838F), // Cyan
  Color(0xFF4E342E), // Brown
  Color(0xFF37474F), // Blue-grey
  Color(0xFF558B2F), // Lime
  Color(0xFF4527A0), // Deep Purple
  Color(0xFFFF6F00), // Amber
  Color(0xFFBF360C), // Deep Orange
  Color(0xFF006064), // Dark Teal
];

class _ColorSwatchRow extends StatelessWidget {
  final Color current;
  final ValueChanged<Color> onPick;
  const _ColorSwatchRow({required this.current, required this.onPick});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 10,
      runSpacing: 10,
      children: _kPresetColors.map((color) {
        final isSelected = current.toARGB32() == color.toARGB32();
        return GestureDetector(
          onTap: () => onPick(color),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(
                color: isSelected ? Colors.white : Colors.transparent,
                width: 2,
              ),
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: isSelected ? 0.6 : 0.3),
                  blurRadius: isSelected ? 8 : 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: isSelected
                ? const Icon(Icons.check_rounded, color: Colors.white, size: 18)
                : null,
          ),
        );
      }).toList(),
    );
  }
}

class _ColorPickerDialog extends StatefulWidget {
  final Color current;
  const _ColorPickerDialog({required this.current});

  @override
  State<_ColorPickerDialog> createState() => _ColorPickerDialogState();
}

class _ColorPickerDialogState extends State<_ColorPickerDialog> {
  late Color _selected;
  final _hexController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _selected = widget.current;
    _hexController.text = _toHex(_selected);
  }

  @override
  void dispose() {
    _hexController.dispose();
    super.dispose();
  }

  String _toHex(Color c) =>
      c.toARGB32().toRadixString(16).substring(2).toUpperCase();

  void _pickPreset(Color c) {
    setState(() {
      _selected = c;
      _hexController.text = _toHex(c);
    });
  }

  void _applyHex(String hex) {
    final clean = hex.replaceAll('#', '').trim();
    if (clean.length == 6) {
      final val = int.tryParse('FF$clean', radix: 16);
      if (val != null) setState(() => _selected = Color(val));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text("Choose Theme Color",
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16, color: AppTheme.secondaryColor)),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Preview
            Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: _selected,
                  shape: BoxShape.circle,
                  boxShadow: [BoxShadow(color: _selected.withValues(alpha: 0.5), blurRadius: 16, offset: const Offset(0, 4))],
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Hex input
            TextField(
              controller: _hexController,
              decoration: InputDecoration(
                labelText: "Hex color",
                prefixText: "#",
                hintText: "e.g. 1565C0",
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide(color: _selected, width: 2),
                ),
                suffixIcon: Container(
                  margin: const EdgeInsets.all(6),
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(color: _selected, borderRadius: BorderRadius.circular(6)),
                ),
              ),
              onChanged: _applyHex,
              maxLength: 6,
            ),
            const SizedBox(height: 8),
            Text("Preset colors", style: TextStyle(fontSize: 11, color: Colors.grey.shade500, fontWeight: FontWeight.w500)),
            const SizedBox(height: 10),
            _ColorSwatchRow(current: _selected, onPick: _pickPreset),
            const SizedBox(height: 8),
            Text("Light colors are auto-darkened for readability.",
                style: TextStyle(fontSize: 10, color: Colors.grey.shade400)),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text("Cancel", style: TextStyle(color: Colors.grey)),
        ),
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: _selected,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          onPressed: () => Navigator.pop(context, _selected),
          child: const Text("Apply"),
        ),
      ],
    );
  }
}

/// Light / Dark / System, applied at once and remembered.
///
/// The choice is stored on the device rather than the user's profile: theme is
/// a property of the screen you are looking at, and a parent using a phone at
/// night should not have their tablet flip too.
class _AppearancePicker extends StatefulWidget {
  const _AppearancePicker();

  @override
  State<_AppearancePicker> createState() => _AppearancePickerState();
}

class _AppearancePickerState extends State<_AppearancePicker> {
  static const _options = <(ThemeMode, String, String, IconData)>[
    (ThemeMode.light, 'Light', 'Always light, whatever the device is set to',
        Icons.light_mode_rounded),
    (ThemeMode.dark, 'Dark', 'Always dark — easier on the eyes at night',
        Icons.dark_mode_rounded),
    (ThemeMode.system, 'System default', 'Follow the phone\'s own setting',
        Icons.brightness_auto_rounded),
  ];

  @override
  Widget build(BuildContext context) {
    final primary = AppTheme.effectivePrimary;

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppTheme.mode,
      builder: (context, mode, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final (value, title, subtitle, icon) in _options)
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => AppTheme.setMode(value),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
                child: Row(children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: (mode == value ? primary : Colors.grey).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(icon,
                        size: 19, color: mode == value ? primary : Colors.grey.shade500),
                  ),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(title,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: mode == value ? FontWeight.w700 : FontWeight.w500,
                            color: mode == value ? primary : null,
                          )),
                      const SizedBox(height: 1),
                      Text(subtitle,
                          style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500)),
                    ]),
                  ),
                  // A check rather than a radio: the row is the target, and a
                  // radio invites tapping the small circle instead.
                  AnimatedOpacity(
                    duration: const Duration(milliseconds: 180),
                    opacity: mode == value ? 1 : 0,
                    child: Icon(Icons.check_circle_rounded, size: 20, color: primary),
                  ),
                ]),
              ),
            ),
        ],
      ),
    );
  }
}
