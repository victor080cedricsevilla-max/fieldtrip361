import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

class LogsView extends StatelessWidget {
  const LogsView({super.key});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text("Activity Logs", style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
        const SizedBox(height: 20),
        Expanded(
          child: StreamBuilder<QuerySnapshot>(
            stream: FirebaseFirestore.instance.collection('activity_logs').orderBy('timestamp', descending: true).snapshots(),
            builder: (context, snapshot) {
              if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
              final logs = snapshot.data!.docs;

              return ListView.builder(
                itemCount: logs.length,
                itemBuilder: (context, index) {
                  var data = logs[index].data() as Map<String, dynamic>;
                  var timestamp = (data['timestamp'] as Timestamp?)?.toDate() ?? DateTime.now();
                  
                  return Card(
                    margin: const EdgeInsets.only(bottom: 10),
                    child: ListTile(
                      leading: Icon(_getIcon(data['action']), color: Colors.grey),
                      title: Text(data['action']),
                      subtitle: Text("${data['details']}\nBy: ${data['adminEmail']}"),
                      trailing: Text(DateFormat('MMM dd, hh:mm a').format(timestamp), style: const TextStyle(fontSize: 12)),
                      isThreeLine: true,
                    ),
                  );
                },
              );
            },
          ),
        )
      ],
    );
  }

  IconData _getIcon(String action) {
    if (action.contains("Create")) return Icons.add_circle;
    if (action.contains("Update")) return Icons.edit;
    if (action.contains("Delete")) return Icons.delete;
    return Icons.history;
  }
}