import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../config/theme.dart';
import '../../controllers/auth_controller.dart';
import '../auth/login_view.dart';
import '../shared/settings_view.dart';
import 'logs_view.dart';
import 'create_trip_view.dart';
import 'manage_trips_view.dart';
import 'admin_overview.dart';
import 'reports_view.dart';
import 'students_view.dart';
import 'documents_view.dart';

class AdminDashboard extends StatefulWidget {
  const AdminDashboard({super.key});

  @override
  State<AdminDashboard> createState() => _AdminDashboardState();
}

class _AdminDashboardState extends State<AdminDashboard> {
  // 0=Dashboard, 1=Create, 2=Manage, 3=Logs, 4=Settings, 5=Reports,
  // 6=Students, 7=Documents
  int _selectedIndex = 0;

  late final List<Widget> _pages = [
    const AdminOverview(),
    const CreateTripView(),
    const ManageTripsView(),
    const LogsView(),
    const SettingsView(allowEmergencySoundUpload: false),
    const ReportsView(),
    const StudentsView(),
    const DocumentsView(),
  ];

  Future<void> _handleLogout() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text("Log out?"),
        content: const Text("You'll need to sign in again to access the admin panel."),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text("Cancel")),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text("Log out", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await AuthController().logout();
    if (!mounted) return;
    Navigator.pushAndRemoveUntil(
      context,
      MaterialPageRoute(builder: (_) => const LoginView()),
      (r) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          _buildSidebar(),
          Expanded(
            child: Container(
              color: const Color(0xFFF3F4F6),
              child: Column(
                children: [
                  _buildTopBar(),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.all(20.0),
                      child: _pages[_selectedIndex],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebar() {
    return Container(
      width: 250,
      color: Colors.white,
      child: Column(
        children: [
          Container(
            height: 80,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: Color(0xFFE5E7EB), width: 1)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.admin_panel_settings, color: AppTheme.effectivePrimary, size: 30),
                SizedBox(width: 10),
                Text(
                  "FieldTrip360",
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1F2937),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          _buildMenuItem(0, "Dashboard", Icons.dashboard_outlined),
          _buildMenuItem(6, "Students", Icons.groups_outlined),
          _buildMenuItem(7, "Documents", Icons.assignment_outlined),
          _buildMenuItem(1, "Create Trip", Icons.add_circle_outline),
          _buildMenuItem(2, "Manage Trips", Icons.map_outlined),
          _buildMenuItem(3, "Activity Logs", Icons.history),
          _buildMenuItem(4, "Settings", Icons.settings_outlined),
          _buildMenuItem(5, "Reports", Icons.assessment_rounded),

          const Spacer(),

          Padding(
            padding: const EdgeInsets.all(20),
            child: ElevatedButton.icon(
              onPressed: _handleLogout,
              icon: const Icon(Icons.logout, size: 18),
              label: const Text("Logout"),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.errorColor.withValues(alpha: 0.1),
                foregroundColor: AppTheme.errorColor,
                elevation: 0,
                minimumSize: const Size(double.infinity, 45),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMenuItem(int index, String title, IconData icon) {
    final bool isSelected = _selectedIndex == index;
    return InkWell(
      onTap: () => setState(() => _selectedIndex = index),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 15, vertical: 5),
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 15),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.effectivePrimary.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: isSelected ? Border.all(color: AppTheme.effectivePrimary.withValues(alpha: 0.5)) : null,
        ),
        child: Row(
          children: [
            Icon(
              icon,
              color: isSelected ? AppTheme.effectivePrimary : Colors.grey,
              size: 22,
            ),
            const SizedBox(width: 15),
            Text(
              title,
              style: TextStyle(
                color: isSelected ? AppTheme.effectivePrimary : Colors.grey[700],
                fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      height: 70,
      padding: const EdgeInsets.symmetric(horizontal: 30),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            offset: const Offset(0, 2),
            blurRadius: 5,
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            _getPageTitle(_selectedIndex),
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1F2937),
            ),
          ),
          _AdminProfileChip(
            onSettings: () => setState(() => _selectedIndex = 4),
            onLogout: _handleLogout,
          ),
        ],
      ),
    );
  }

  String _getPageTitle(int index) {
    switch (index) {
      case 0:
        return "Dashboard Overview";
      case 1:
        return "Create New Trip";
      case 2:
        return "Trip Management";
      case 3:
        return "Activity Logs";
      case 4:
        return "Settings";
      case 5:
        return "Reports";
      case 6:
        return "Students";
      case 7:
        return "Documents";
      default:
        return "Admin";
    }
  }
}

/// Top-right admin chip: shows the signed-in admin's name/email and exposes
/// quick access to Settings + Logout via a popup menu.
class _AdminProfileChip extends StatelessWidget {
  final VoidCallback onSettings;
  final VoidCallback onLogout;
  const _AdminProfileChip({required this.onSettings, required this.onLogout});

  @override
  Widget build(BuildContext context) {
    final uid = FirebaseAuth.instance.currentUser?.uid;
    if (uid == null) return const SizedBox.shrink();
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: FirebaseFirestore.instance.collection('users').doc(uid).snapshots(),
      builder: (context, snap) {
        final data = snap.data?.data() ?? const {};
        final name = (data['name'] ?? FirebaseAuth.instance.currentUser?.displayName ?? 'Admin User').toString();
        final email = (data['email'] ?? FirebaseAuth.instance.currentUser?.email ?? '').toString();
        final photoUrl = data['photoUrl'] as String?;

        return PopupMenuButton<String>(
          tooltip: "Account",
          position: PopupMenuPosition.under,
          offset: const Offset(0, 8),
          onSelected: (v) {
            if (v == 'settings') onSettings();
            if (v == 'logout') onLogout();
          },
          itemBuilder: (ctx) => [
            PopupMenuItem(
              value: 'settings',
              child: Row(
                children: const [
                  Icon(Icons.settings_outlined, size: 18),
                  SizedBox(width: 10),
                  Text("Settings"),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'logout',
              child: Row(
                children: const [
                  Icon(Icons.logout, size: 18, color: AppTheme.errorColor),
                  SizedBox(width: 10),
                  Text("Log out", style: TextStyle(color: AppTheme.errorColor)),
                ],
              ),
            ),
          ],
          child: Row(
            children: [
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    name,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                      color: Color(0xFF1F2937),
                    ),
                  ),
                  Text(
                    email,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
              const SizedBox(width: 15),
              CircleAvatar(
                backgroundColor: AppTheme.secondaryColor,
                backgroundImage:
                    (photoUrl != null && photoUrl.isNotEmpty) ? NetworkImage(photoUrl) : null,
                child: (photoUrl == null || photoUrl.isEmpty)
                    ? Text(
                        name.isNotEmpty ? name[0].toUpperCase() : 'A',
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                      )
                    : null,
              ),
              const SizedBox(width: 6),
              Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: Colors.grey.shade600),
            ],
          ),
        );
      },
    );
  }
}

