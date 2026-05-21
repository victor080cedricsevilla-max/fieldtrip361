import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../config/theme.dart';
import '../auth/login_view.dart';

class LandingPage extends StatefulWidget {
  const LandingPage({super.key});

  @override
  State<LandingPage> createState() => _LandingPageState();
}

class _LandingPageState extends State<LandingPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _fade;
  late final Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 900));
    _fade = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(begin: const Offset(0, .06), end: Offset.zero)
        .animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOutCubic));
    _ctrl.forward();
    _checkAlreadyLoggedIn();
  }

  Future<void> _checkAlreadyLoggedIn() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .get();
      final role = (snap.data()?['role'] ?? '').toString();
      if (!mounted) return;
      final route = switch (role) {
        'admin'   => '/admin/dashboard',
        'teacher' => '/teacher/dashboard',
        'student' => '/student/dashboard',
        'parent'  => '/parent/dashboard',
        _         => null,
      };
      if (route != null) {
        Navigator.pushReplacementNamed(context, route);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: const Color(0xFFF0FFFE),
      body: Stack(
        children: [
          // Background blobs
          Positioned(
            top: -80, right: -80,
            child: _Blob(size: 320, color: AppTheme.primaryColor.withValues(alpha: .12)),
          ),
          Positioned(
            bottom: -60, left: -60,
            child: _Blob(size: 260, color: AppTheme.accentColor.withValues(alpha: .10)),
          ),

          SafeArea(
            child: FadeTransition(
              opacity: _fade,
              child: SlideTransition(
                position: _slide,
                child: SizedBox(
                  width: size.width,
                  height: size.height,
                  child: Column(
                    children: [
                      // Top bar
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                        child: Row(
                          children: [
                            Container(
                              width: 40, height: 40,
                              decoration: BoxDecoration(
                                color: AppTheme.primaryColor,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: const Icon(Icons.directions_bus_rounded, color: Colors.white, size: 22),
                            ),
                            const SizedBox(width: 10),
                            RichText(
                              text: const TextSpan(
                                style: TextStyle(
                                  fontFamily: 'Poppins',
                                  fontSize: 18,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.secondaryColor,
                                ),
                                children: [
                                  TextSpan(text: 'FieldTrip'),
                                  TextSpan(text: '360', style: TextStyle(color: AppTheme.primaryColor)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Main content
                      Expanded(
                        child: SingleChildScrollView(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 28),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const SizedBox(height: 24),

                                // Badge
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                                  decoration: BoxDecoration(
                                    color: AppTheme.primaryColor.withValues(alpha: .12),
                                    borderRadius: BorderRadius.circular(999),
                                  ),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 6, height: 6,
                                        decoration: const BoxDecoration(
                                          color: AppTheme.primaryColor,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      const SizedBox(width: 7),
                                      const Text(
                                        'Real-time Field Trip Management',
                                        style: TextStyle(
                                          fontFamily: 'Poppins',
                                          fontSize: 11,
                                          fontWeight: FontWeight.w600,
                                          color: AppTheme.primaryColor,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),

                                const SizedBox(height: 20),

                                // Headline
                                RichText(
                                  text: const TextSpan(
                                    style: TextStyle(
                                      fontFamily: 'Poppins',
                                      fontSize: 36,
                                      fontWeight: FontWeight.w800,
                                      height: 1.15,
                                      color: AppTheme.secondaryColor,
                                    ),
                                    children: [
                                      TextSpan(text: 'Keep Every\n'),
                                      TextSpan(
                                        text: 'Student Safe\n',
                                        style: TextStyle(color: AppTheme.primaryColor),
                                      ),
                                      TextSpan(text: 'On Every Trip'),
                                    ],
                                  ),
                                ),

                                const SizedBox(height: 16),

                                const Text(
                                  'Real-time GPS, QR attendance, and instant parent alerts — all in one app for teachers, students, and parents.',
                                  style: TextStyle(
                                    fontFamily: 'Poppins',
                                    fontSize: 14,
                                    color: Color(0xFF6B7280),
                                    height: 1.65,
                                  ),
                                ),

                                const SizedBox(height: 36),

                                // Feature chips
                                Wrap(
                                  spacing: 10, runSpacing: 10,
                                  children: const [
                                    _FeatureChip(icon: Icons.location_on_rounded, label: 'Live GPS'),
                                    _FeatureChip(icon: Icons.qr_code_scanner_rounded, label: 'QR Attendance'),
                                    _FeatureChip(icon: Icons.notifications_rounded, label: 'Parent Alerts'),
                                    _FeatureChip(icon: Icons.chat_bubble_rounded, label: 'Bus Chat'),
                                  ],
                                ),

                                const SizedBox(height: 48),

                                // Illustration card
                                Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.all(20),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(20),
                                    border: Border.all(color: const Color(0xFFE5E7EB)),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(alpha: .05),
                                        blurRadius: 20, offset: const Offset(0, 8),
                                      ),
                                    ],
                                  ),
                                  child: Column(
                                    children: [
                                      Row(
                                        children: [
                                          Container(
                                            width: 40, height: 40,
                                            decoration: BoxDecoration(
                                              color: AppTheme.primaryColor.withValues(alpha: .1),
                                              borderRadius: BorderRadius.circular(10),
                                            ),
                                            child: const Icon(Icons.directions_bus_rounded, color: AppTheme.primaryColor, size: 22),
                                          ),
                                          const SizedBox(width: 12),
                                          const Expanded(
                                            child: Column(
                                              crossAxisAlignment: CrossAxisAlignment.start,
                                              children: [
                                                Text('Bus 1 — En Route', style: TextStyle(fontFamily: 'Poppins', fontSize: 13, fontWeight: FontWeight.w600, color: AppTheme.secondaryColor)),
                                                Text('Science Museum Trip', style: TextStyle(fontFamily: 'Poppins', fontSize: 11, color: Color(0xFF6B7280))),
                                              ],
                                            ),
                                          ),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                            decoration: BoxDecoration(
                                              color: Colors.green.shade50,
                                              borderRadius: BorderRadius.circular(999),
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Container(width: 6, height: 6, decoration: const BoxDecoration(color: Colors.green, shape: BoxShape.circle)),
                                                const SizedBox(width: 5),
                                                Text('Live', style: TextStyle(fontFamily: 'Poppins', fontSize: 10, fontWeight: FontWeight.w600, color: Colors.green.shade700)),
                                              ],
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 14),
                                      const Divider(color: Color(0xFFE5E7EB), height: 1),
                                      const SizedBox(height: 14),
                                      _StatusRow(icon: Icons.people_rounded, label: '24 / 25 students present', color: AppTheme.primaryColor),
                                      const SizedBox(height: 8),
                                      _StatusRow(icon: Icons.location_on_rounded, label: 'Next stop: Mall of Asia', color: Colors.orange),
                                      const SizedBox(height: 8),
                                      _StatusRow(icon: Icons.notifications_active_rounded, label: 'Parents notified', color: Colors.green),
                                    ],
                                  ),
                                ),

                                const SizedBox(height: 48),
                              ],
                            ),
                          ),
                        ),
                      ),

                      // Bottom CTAs
                      Container(
                        padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
                        decoration: const BoxDecoration(
                          color: Color(0xFFF0FFFE),
                          border: Border(top: BorderSide(color: Color(0xFFE5E7EB))),
                        ),
                        child: Column(
                          children: [
                            // Sign In
                            SizedBox(
                              width: double.infinity,
                              height: 52,
                              child: ElevatedButton(
                                onPressed: () {
                                  Navigator.push(
                                    context,
                                    MaterialPageRoute(builder: (_) => const LoginView()),
                                  );
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppTheme.primaryColor,
                                  foregroundColor: Colors.white,
                                  elevation: 0,
                                  shadowColor: Colors.transparent,
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                                ),
                                child: const Text(
                                  'Sign In',
                                  style: TextStyle(fontFamily: 'Poppins', fontSize: 16, fontWeight: FontWeight.w700),
                                ),
                              ),
                            ),
                            const SizedBox(height: 12),
                            // Stats row
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: const [
                                _StatChip(value: '4 Roles', sub: 'Supported'),
                                SizedBox(width: 6),
                                _StatChip(value: 'Real-time', sub: 'GPS Tracking'),
                                SizedBox(width: 6),
                                _StatChip(value: 'Instant', sub: 'Alerts'),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Helpers ────────────────────────────────────────────────────────────────

class _Blob extends StatelessWidget {
  final double size;
  final Color color;
  const _Blob({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size, height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }
}

class _FeatureChip extends StatelessWidget {
  final IconData icon;
  final String label;
  const _FeatureChip({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFFE5E7EB)),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: .04), blurRadius: 6, offset: const Offset(0, 2))],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: AppTheme.primaryColor),
          const SizedBox(width: 6),
          Text(label, style: const TextStyle(fontFamily: 'Poppins', fontSize: 12, fontWeight: FontWeight.w500, color: AppTheme.secondaryColor)),
        ],
      ),
    );
  }
}

class _StatusRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _StatusRow({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontFamily: 'Poppins', fontSize: 12, color: Color(0xFF4B5563), fontWeight: FontWeight.w500)),
      ],
    );
  }
}

class _StatChip extends StatelessWidget {
  final String value;
  final String sub;
  const _StatChip({required this.value, required this.sub});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFFE5E7EB)),
        ),
        child: Column(
          children: [
            Text(value, style: const TextStyle(fontFamily: 'Poppins', fontSize: 11, fontWeight: FontWeight.w700, color: AppTheme.secondaryColor)),
            Text(sub, style: const TextStyle(fontFamily: 'Poppins', fontSize: 9, color: Color(0xFF9CA3AF))),
          ],
        ),
      ),
    );
  }
}
