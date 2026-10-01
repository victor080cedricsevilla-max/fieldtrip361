import 'package:flutter/material.dart';

import '../../config/theme.dart';
import '../../utils/firestore_utils.dart';

/// One bus a student (or a parent's child) rides, with the facilitators on it.
class BusAssignment {
  final int busIndex;
  final String busLabel;
  final String? mainTeacher;
  final String? coTeacher;

  /// The given students who are on this bus — for a parent with two children on
  /// different buses, which child this card is about.
  final List<String> passengerIds;

  const BusAssignment({
    required this.busIndex,
    required this.busLabel,
    required this.mainTeacher,
    required this.coTeacher,
    required this.passengerIds,
  });

  bool get hasTeacher => mainTeacher != null || coTeacher != null;
}

/// The buses carrying any of [studentIds], in bus order.
List<BusAssignment> busAssignmentsFor(dynamic rawBuses, Set<String> studentIds) {
  final out = <BusAssignment>[];
  final buses = asList(rawBuses);
  for (int i = 0; i < buses.length; i++) {
    final b = buses[i];
    if (b is! Map) continue;
    final onThisBus = <String>[
      for (final p in asList(b['passengers']))
        if (p is Map && studentIds.contains(p['id']?.toString())) p['id'].toString(),
    ];
    if (onThisBus.isEmpty) continue;
    String? nameOf(dynamic t) {
      final n = t is Map ? t['name']?.toString().trim() : null;
      return (n == null || n.isEmpty) ? null : n;
    }

    out.add(BusAssignment(
      busIndex: i,
      busLabel: (b['busLabel'] ?? '${i + 1}').toString(),
      mainTeacher: nameOf(b['mainTeacher']),
      coTeacher: nameOf(b['coTeacher']),
      passengerIds: onThisBus,
    ));
  }
  return out;
}

/// "Bus 2 — Teacher: Ms Cruz · Co-teacher: Mr Reyes", so a student knows whom to
/// go to and a parent knows who has their child.
class BusTeacherCard extends StatelessWidget {
  final BusAssignment assignment;

  /// Shown when a parent has more than one child on the trip.
  final List<String> childNames;

  const BusTeacherCard({super.key, required this.assignment, this.childNames = const []});

  @override
  Widget build(BuildContext context) {
    final a = assignment;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(
          padding: const EdgeInsets.all(9),
          decoration: BoxDecoration(
            color: AppTheme.effectivePrimary.withValues(alpha: 0.1),
            shape: BoxShape.circle,
          ),
          child: Icon(Icons.directions_bus_rounded, color: AppTheme.effectivePrimary, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              'Bus ${a.busLabel}'
              '${childNames.isEmpty ? '' : ' · ${childNames.join(', ')}'}',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: AppTheme.secondaryColor),
            ),
            const SizedBox(height: 4),
            if (!a.hasTeacher)
              Text('No teacher assigned yet',
                  style: TextStyle(fontSize: 12.5, color: Colors.grey.shade500)),
            if (a.mainTeacher != null) _line(Icons.person_rounded, 'Teacher', a.mainTeacher!),
            if (a.coTeacher != null) _line(Icons.person_outline_rounded, 'Co-teacher', a.coTeacher!),
          ]),
        ),
      ]),
    );
  }

  Widget _line(IconData icon, String role, String name) => Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Row(children: [
          Icon(icon, size: 14, color: Colors.grey.shade500),
          const SizedBox(width: 6),
          Text('$role: ', style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600)),
          Expanded(
            child: Text(name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppTheme.darkText)),
          ),
        ]),
      );
}
