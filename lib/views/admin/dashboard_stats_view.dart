import 'package:flutter/material.dart';
import '../../config/theme.dart';

class DashboardStatsView extends StatelessWidget {
  const DashboardStatsView({super.key});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // --- TITLE SECTION ---
          const Text(
            "Overview",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.grey),
          ),
          const SizedBox(height: 20),

          // --- STAT CARDS ROW ---
          // Gumamit ng Wrap para responsive (baba ang cards pag maliit ang screen)
          Wrap(
            spacing: 20, // Space between cards horizontal
            runSpacing: 20, // Space between cards vertical
            children: [
              _buildStatCard(
                title: "Active Trips",
                count: "3",
                icon: Icons.directions_bus_filled,
                color: AppTheme.primaryColor, // Mint Green
              ),
              _buildStatCard(
                title: "Total Students",
                count: "1,250",
                icon: Icons.school,
                color: AppTheme.secondaryColor, // Dolphin Blue
              ),
              _buildStatCard(
                title: "Teachers On Duty",
                count: "45",
                icon: Icons.person_pin_circle,
                color: Colors.orangeAccent, // Orange for distinction
              ),
              _buildStatCard(
                title: "Safety Alerts",
                count: "0",
                icon: Icons.warning_amber_rounded,
                color: AppTheme.errorColor, // Red for Danger
                isAlert: true,
              ),
            ],
          ),

          const SizedBox(height: 40),

          // --- RECENT ACTIVITY SECTION ---
          const Text(
            "Recent Activities",
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.grey),
          ),
          const SizedBox(height: 15),

          // Table / List Container
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey[200]!),
            ),
            child: Column(
              children: [
                _buildActivityRow("Trip to National Museum", "Started 2 hours ago", "Active"),
                const Divider(),
                _buildActivityRow("Science Center Visit", "Ended yesterday", "Completed"),
                const Divider(),
                _buildActivityRow("Grade 10 Manila Zoo", "Approved just now", "Pending"),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // --- WIDGET: STAT CARD ---
  Widget _buildStatCard({
    required String title,
    required String count,
    required IconData icon,
    required Color color,
    bool isAlert = false,
  }) {
    return Container(
      width: 260, // Fixed width per card
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
        border: isAlert ? Border.all(color: color, width: 2) : null,
      ),
      child: Row(
        children: [
          // Icon Box
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: color.withOpacity(0.2), // Light version of the color
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 30),
          ),
          const SizedBox(width: 20),
          
          // Text Info
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                count,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: isAlert ? color : AppTheme.darkText,
                ),
              ),
              Text(
                title,
                style: const TextStyle(
                  fontSize: 14,
                  color: Colors.grey,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // --- WIDGET: ACTIVITY ROW ---
  Widget _buildActivityRow(String tripName, String time, String status) {
    Color statusColor;
    if (status == "Active") statusColor = AppTheme.primaryColor;
    else if (status == "Completed") statusColor = Colors.grey;
    else statusColor = Colors.orange;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(tripName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
              Text(time, style: const TextStyle(color: Colors.grey, fontSize: 12)),
            ],
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: statusColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              status,
              style: TextStyle(color: statusColor, fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}