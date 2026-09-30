import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../../config/theme.dart';
import '../../utils/school_context.dart';

/// Logging a stop that was not on the itinerary.
///
/// A bus pulls into a petrol station so the students can use the toilet. Nobody
/// is in danger, but until now nobody outside the bus knew it had happened: a
/// parent watching the map saw the marker stop somewhere that was not a
/// destination and had to guess why. The facilitator records it here, and the
/// record answers the question the map raises.
///
/// There are two kinds, and they reach different people on purpose.
///
///   Stopover  — routine. The school and the parents are both told, always.
///   Emergency — the school is told, always. The parents are told only while the
///               switch is on. That is the facilitator's call to make: in the
///               first minutes of an incident the facts are least reliable, and
///               the school decides how to say it.
///
/// This is not the student's SOS button. That is a student saying something is
/// wrong with them; this is a facilitator reporting something about the journey.
class UnscheduledStopView extends StatefulWidget {
  final String tripId;
  final String tripTitle;

  /// How many students are on this facilitator's bus, for the confirmation — so
  /// "tell the parents" names the number of families it reaches.
  final int passengerCount;

  const UnscheduledStopView({
    super.key,
    required this.tripId,
    required this.tripTitle,
    required this.passengerCount,
  });

  @override
  State<UnscheduledStopView> createState() => _UnscheduledStopViewState();
}

enum _Kind { stopover, emergency }

class _UnscheduledStopViewState extends State<UnscheduledStopView> {
  _Kind _kind = _Kind.stopover;
  final _place = TextEditingController();
  final _note = TextEditingController();

  /// On by default: telling the parents is what the page is for, and switching it
  /// off is the exception that needs a deliberate touch.
  bool _notifyParents = true;

  bool _busy = false;
  String? _error;

  static const _stopoverReasons = [
    'Toilet break',
    'Fuel',
    'Meal',
    'Stretch / rest',
    'Traffic',
  ];
  static const _emergencyReasons = [
    'Vehicle problem',
    'Medical',
    'Accident',
    'Student missing',
    'Unsafe situation',
  ];

  @override
  void dispose() {
    _place.dispose();
    _note.dispose();
    super.dispose();
  }

  List<String> get _reasons =>
      _kind == _Kind.emergency ? _emergencyReasons : _stopoverReasons;

  /// Where the bus is, when that can be had quickly. Best-effort: the report must
  /// never wait on a satellite fix, because a facilitator typing a message at a
  /// roadside wants it sent, not waiting.
  Future<Position?> _here() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      final perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 6),
        ),
      );
    } catch (_) {
      return null;
    }
  }

  Future<bool> _confirmEmergency() async {
    final who = _notifyParents
        ? 'the school and the parents of the ${widget.passengerCount} '
            '${widget.passengerCount == 1 ? "student" : "students"} on your bus'
        : 'the school only — parents will NOT be told';
    return (await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            icon: Icon(Icons.warning_amber_rounded, color: AppTheme.errorColor, size: 34),
            title: const Text('Send an emergency alert?'),
            content: Text(
              'This will notify $who right now.',
              style: const TextStyle(fontSize: 14, height: 1.5),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: AppTheme.errorColor),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Send alert'),
              ),
            ],
          ),
        )) ==
        true;
  }

  Future<void> _submit() async {
    FocusScope.of(context).unfocus();
    if (_kind == _Kind.emergency && !await _confirmEmergency()) return;

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final pos = await _here();
      final res = await FirebaseFunctions.instance
          .httpsCallable('logUnscheduledStop')
          .call<Map<String, dynamic>>({
        'tripId': widget.tripId,
        'kind': _kind == _Kind.emergency ? 'emergency' : 'stopover',
        'place': _place.text.trim(),
        'reason': _note.text.trim(),
        'notifyParents': _kind == _Kind.stopover ? true : _notifyParents,
        if (pos != null) 'lat': pos.latitude,
        if (pos != null) 'lng': pos.longitude,
      });
      if (!mounted) return;

      final reached = (res.data['parentsReached'] as num?)?.toInt() ?? 0;
      final parents = res.data['parentsNotified'] == true;
      final messenger = ScaffoldMessenger.of(context);
      Navigator.pop(context);
      messenger.showSnackBar(SnackBar(
        backgroundColor: _kind == _Kind.emergency ? AppTheme.errorColor : Colors.green,
        content: Text(
          parents
              ? 'Logged. The school and $reached ${reached == 1 ? "parent" : "parents"} have been told.'
              : 'Logged. The school has been told. Parents were not notified.',
        ),
      ));
    } on FirebaseFunctionsException catch (e) {
      if (mounted) setState(() => _error = e.message ?? 'That could not be sent.');
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Something went wrong. Check your connection and try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final emergency = _kind == _Kind.emergency;
    final tone = emergency ? AppTheme.errorColor : AppTheme.effectivePrimary;

    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0,
        foregroundColor: AppTheme.secondaryColor,
        title: const Text('Unscheduled stop',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.tripTitle,
                style: TextStyle(fontSize: 12.5, color: Colors.grey.shade600),
              ),
              const SizedBox(height: 4),
              const Text(
                'What happened?',
                style: TextStyle(
                    fontSize: 21, fontWeight: FontWeight.bold, color: AppTheme.darkText),
              ),
              const SizedBox(height: 14),

              _kindCard(
                kind: _Kind.stopover,
                icon: Icons.local_gas_station_outlined,
                title: 'Stopover',
                body: 'A pause that was not on the route — a toilet break, fuel, a meal. '
                    'The school and the parents are both told.',
              ),
              const SizedBox(height: 10),
              _kindCard(
                kind: _Kind.emergency,
                icon: Icons.warning_amber_rounded,
                title: 'Emergency',
                body: 'Something is wrong. The school is always told immediately. '
                    'You decide whether the parents are told as well.',
              ),

              if (emergency) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFE5E7EB)),
                  ),
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _notifyParents,
                    activeThumbColor: AppTheme.errorColor,
                    onChanged: _busy ? null : (v) => setState(() => _notifyParents = v),
                    title: const Text('Also notify the parents',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                    subtitle: Text(
                      _notifyParents
                          ? 'Parents of the ${widget.passengerCount} '
                              '${widget.passengerCount == 1 ? "student" : "students"} '
                              'on your bus will get a notification.'
                          : 'Only the school will be told. Turn this on when you are '
                              'sure of the facts — the school can still tell parents itself.',
                      style: TextStyle(
                          fontSize: 12, height: 1.4, color: Colors.grey.shade600),
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 22),
              TextField(
                controller: _place,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: 'Where are you? (optional)',
                  hintText: 'e.g. Petron, Plaridel',
                  filled: true,
                  fillColor: Colors.white,
                  prefixIcon: const Icon(Icons.place_outlined),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 14),

              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final r in _reasons)
                    ActionChip(
                      label: Text(r, style: const TextStyle(fontSize: 12)),
                      backgroundColor: Colors.white,
                      side: const BorderSide(color: Color(0xFFE5E7EB)),
                      onPressed: () => setState(() => _note.text = r),
                    ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _note,
                maxLines: 3,
                minLines: 2,
                maxLength: 300,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(
                  labelText: emergency ? 'What is happening?' : 'Reason (optional)',
                  filled: true,
                  fillColor: Colors.white,
                  alignLabelWithHint: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),

              const SizedBox(height: 4),
              Row(children: [
                Icon(Icons.my_location_rounded, size: 14, color: Colors.grey.shade500),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Your current location is attached when it can be found quickly.',
                    style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500),
                  ),
                ),
              ]),

              if (_error != null) ...[
                const SizedBox(height: 14),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFDECEA),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(_error!,
                      style: const TextStyle(
                          fontSize: 13, color: Color(0xFF9B2C20), height: 1.4)),
                ),
              ],

              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: _busy ? null : _submit,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : Icon(emergency
                          ? Icons.campaign_outlined
                          : Icons.notifications_active_outlined),
                  label: Text(
                    emergency ? 'Send emergency alert' : 'Log stop and notify',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: tone,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),

              const SizedBox(height: 28),
              _RecentStops(tripId: widget.tripId),
            ],
          ),
        ),
      ),
    );
  }

  Widget _kindCard({
    required _Kind kind,
    required IconData icon,
    required String title,
    required String body,
  }) {
    final selected = _kind == kind;
    final color = kind == _Kind.emergency ? AppTheme.errorColor : AppTheme.effectivePrimary;
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: _busy
          ? null
          : () => setState(() {
                _kind = kind;
                _error = null;
              }),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.07) : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? color : const Color(0xFFE5E7EB),
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title,
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold, color: color)),
              const SizedBox(height: 3),
              Text(body,
                  style: TextStyle(
                      fontSize: 12.5, height: 1.45, color: Colors.grey.shade700)),
            ]),
          ),
          Icon(selected ? Icons.radio_button_checked : Icons.radio_button_off,
              color: selected ? color : Colors.grey.shade400, size: 20),
        ]),
      ),
    );
  }
}

/// What has already been logged on this trip, so a facilitator does not send the
/// same stop twice and a co-facilitator's entries are visible.
///
/// The query carries the school filter the security rule enforces as well as the
/// trip, because a read is checked against its query, not its results — and it
/// sorts in memory rather than ordering on the server, which would need an index.
class _RecentStops extends StatelessWidget {
  final String tripId;
  const _RecentStops({required this.tripId});

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String?>(
      future: SchoolContext.schoolId(),
      builder: (context, school) {
        final schoolId = school.data;
        if (schoolId == null) return const SizedBox.shrink();
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: FirebaseFirestore.instance
              .collection('tripEvents')
              .where('schoolId', isEqualTo: schoolId)
              .where('tripId', isEqualTo: tripId)
              .snapshots(),
          builder: (context, snap) {
            final docs = (snap.data?.docs ?? [])
              ..sort((a, b) {
                final at = a.data()['createdAt'] as Timestamp?;
                final bt = b.data()['createdAt'] as Timestamp?;
                return (bt?.millisecondsSinceEpoch ?? 0)
                    .compareTo(at?.millisecondsSinceEpoch ?? 0);
              });
            if (docs.isEmpty) return const SizedBox.shrink();

            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Logged on this trip',
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.bold, color: AppTheme.darkText)),
              const SizedBox(height: 8),
              for (final d in docs.take(6)) _row(d.data()),
            ]);
          },
        );
      },
    );
  }

  Widget _row(Map<String, dynamic> e) {
    final emergency = e['kind'] == 'emergency';
    final color = emergency ? AppTheme.errorColor : AppTheme.effectivePrimary;
    final at = (e['createdAt'] as Timestamp?)?.toDate();
    final time = at == null
        ? ''
        : '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
    final detail = [
      if ((e['place'] ?? '').toString().isNotEmpty) e['place'],
      if ((e['reason'] ?? '').toString().isNotEmpty) e['reason'],
    ].join(' — ');

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFE5E7EB)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(emergency ? Icons.warning_amber_rounded : Icons.local_gas_station_outlined,
            size: 18, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              '${emergency ? "Emergency" : "Stopover"} · Bus ${e['busLabel'] ?? ''}'
              '${time.isEmpty ? '' : ' · $time'}',
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: color),
            ),
            if (detail.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(detail,
                    style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700)),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                e['parentsNotified'] == true ? 'Parents notified' : 'Parents not notified',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
              ),
            ),
          ]),
        ),
      ]),
    );
  }
}
