import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'firestore_utils.dart';

/// Client-side fallback that mirrors the Cloud Function `onTripChatSync`.
/// Call this any time `trips/{tripId}.buses` is created or modified so a
/// chat document exists for every bus regardless of whether the Cloud
/// Function has been deployed.
///
/// Chat id is deterministic: `{tripId}_{busIndex}`. We use `set(..., merge:true)`
/// so calling this repeatedly is safe.
class ChatSync {
  static Future<void> syncTripChats({
    required String tripId,
    required String tripTitle,
    required List<dynamic> buses,
  }) async {
    final db = FirebaseFirestore.instance;
    for (int i = 0; i < buses.length; i++) {
      final bus = buses[i] as Map? ?? const {};
      final String busLabel = (bus['busLabel'] ?? bus['busNo'] ?? (i + 1)).toString();
      final String chatId = "${tripId}_$i";

      final Set<String> memberIds = {};
      final List<Map<String, dynamic>> members = [];

      void addMember(Map? m, String role) {
        if (m == null) return;
        final id = m['id']?.toString();
        if (id == null || id.isEmpty) return;
        if (memberIds.add(id)) {
          members.add({
            'id': id,
            'name': m['name']?.toString() ?? '',
            'role': role,
          });
        }
      }

      addMember(bus['mainTeacher'] as Map?, 'teacher');
      addMember(bus['coTeacher'] as Map?, 'teacher');
      for (final p in asList(bus['passengers'])) {
        addMember(p as Map?, 'student');
      }

      final chatRef = db.collection('chats').doc(chatId);
      try {
        final existing = await chatRef.get();
        final Map<String, dynamic> payload = {
          'tripId': tripId,
          'busIndex': i,
          'busLabel': busLabel,
          'tripTitle': tripTitle,
          'name': "$tripTitle - Bus $busLabel",
          'memberIds': memberIds.toList(),
          'members': members,
          'updatedAt': FieldValue.serverTimestamp(),
        };
        if (!existing.exists) {
          payload['createdAt'] = FieldValue.serverTimestamp();
          payload['lastMessage'] = '';
          payload['lastMessageAt'] = null;
          payload['lastSenderId'] = null;
        }
        await chatRef.set(payload, SetOptions(merge: true));
      } catch (e) {
        debugPrint("ChatSync.syncTripChats failed for $chatId: $e");
      }
    }
  }
}
