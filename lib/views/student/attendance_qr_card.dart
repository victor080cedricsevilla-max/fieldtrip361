import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../config/theme.dart';
import '../../utils/attendance_service.dart';
import '../../utils/firestore_utils.dart';
import '../../utils/trip_queries.dart';

/// The code a student shows to be marked present.
///
/// It is short-lived and single-use, and it is reissued while the screen is
/// open. A screenshot forwarded to a classmate is therefore worth nothing a few
/// seconds later — and even inside the window the server still checks that the
/// student's own device is at the destination before recording anything.
///
/// This is separate from the student's USQIC, which identifies them and does
/// not expire; that code stays exactly where it was.
class AttendanceQrCard extends StatefulWidget {
  final String myUid;

  const AttendanceQrCard({super.key, required this.myUid});

  @override
  State<AttendanceQrCard> createState() => _AttendanceQrCardState();
}

class _AttendanceQrCardState extends State<AttendanceQrCard> {
  static const _refreshEvery = Duration(seconds: 20);

  Timer? _refreshTimer;
  Timer? _countdownTimer;

  String? _tripId;
  String? _payload;
  DateTime? _expiresAt;
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _refreshTimer?.cancel();
    _countdownTimer?.cancel();
    super.dispose();
  }

  void _startCycle(String tripId) {
    if (_tripId == tripId && _refreshTimer != null) return;
    _tripId = tripId;
    _refreshTimer?.cancel();
    _issue();
    _refreshTimer = Timer.periodic(_refreshEvery, (_) => _issue());
    _countdownTimer ??= Timer.periodic(
      const Duration(seconds: 1),
      (_) => mounted ? setState(() {}) : null,
    );
  }

  void _stopCycle() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _countdownTimer?.cancel();
    _countdownTimer = null;
    _tripId = null;
    _payload = null;
    _expiresAt = null;
  }

  /// A fresh position goes up *before* the code is issued, so the position the
  /// server checks is the one from the moment the student is standing there.
  Future<void> _issue() async {
    final tripId = _tripId;
    if (tripId == null || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await AttendanceService.publishFreshFix();
      final res = await AttendanceService.issueToken(tripId);
      if (!mounted) return;
      setState(() {
        _payload = jsonEncode({'t': res['tokenId'], 'j': res['jti']});
        _expiresAt = DateTime.fromMillisecondsSinceEpoch(
          (res['expiresAt'] as num).toInt(),
        );
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _payload = null;
        _error = AttendanceService.describeError(e).message;
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  int get _secondsLeft {
    final exp = _expiresAt;
    if (exp == null) return 0;
    final left = exp.difference(DateTime.now()).inSeconds;
    return left < 0 ? 0 : left;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: TripQueries.mine(),
      builder: (context, snap) {
        if (!snap.hasData) return const SizedBox.shrink();

        QueryDocumentSnapshot<Map<String, dynamic>>? active;
        for (final doc in snap.data!.docs) {
          if (doc.data()['status'] == 'in_progress') {
            active = doc;
            break;
          }
        }

        if (active == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _tripId != null) setState(_stopCycle);
          });
          return const SizedBox.shrink();
        }

        final trip = active.data();
        final stopIndex = trip['activeStopIndex'];
        final stops = asList(trip['stops']);
        final atStop = stopIndex is int && stopIndex >= 0 && stopIndex < stops.length;

        if (!atStop) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _tripId != null) setState(_stopCycle);
          });
          return _Shell(
            title: 'Attendance code',
            child: _Message(
              icon: Icons.directions_bus_rounded,
              text: 'Your code appears once the bus arrives at a destination.',
            ),
          );
        }

        final tripId = active.id;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _startCycle(tripId);
        });

        final stopName = (stops[stopIndex] as Map)['name']?.toString() ?? 'this stop';

        return _Shell(
          title: 'Attendance code',
          subtitle: 'For $stopName',
          child: Column(
            children: [
              if (_error != null)
                _Message(icon: Icons.error_outline_rounded, text: _error!, isError: true)
              else if (_payload == null)
                const SizedBox(
                  height: 220,
                  child: Center(child: CircularProgressIndicator()),
                )
              else
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Opacity(
                      opacity: _secondsLeft == 0 ? 0.25 : 1,
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          border: Border.all(
                            color: AppTheme.effectivePrimary.withValues(alpha: 0.2),
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: QrImageView(
                          data: _payload!,
                          version: QrVersions.auto,
                          size: 200,
                          backgroundColor: Colors.white,
                        ),
                      ),
                    ),
                    if (_secondsLeft == 0)
                      const Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.refresh_rounded, size: 28),
                          SizedBox(height: 6),
                          Text('Refreshing…', style: TextStyle(fontWeight: FontWeight.w600)),
                        ],
                      ),
                  ],
                ),
              const SizedBox(height: 14),
              _Countdown(secondsLeft: _secondsLeft, busy: _loading),
              const SizedBox(height: 10),
              Text(
                'This code changes every few seconds and works only once. '
                'Sharing a screenshot will not mark anyone present.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, height: 1.5, color: Colors.grey.shade600),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Shell extends StatelessWidget {
  final String title;
  final String? subtitle;
  final Widget child;

  const _Shell({required this.title, this.subtitle, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 24),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(24),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.08),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppTheme.secondaryColor,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(
              subtitle!,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
            ),
          ],
          const SizedBox(height: 18),
          child,
        ],
      ),
    );
  }
}

class _Countdown extends StatelessWidget {
  final int secondsLeft;
  final bool busy;

  const _Countdown({required this.secondsLeft, required this.busy});

  @override
  Widget build(BuildContext context) {
    final color = secondsLeft <= 5 ? Colors.orange.shade700 : AppTheme.effectivePrimary;
    return Semantics(
      liveRegion: true,
      label: busy
          ? 'Refreshing your attendance code'
          : 'Code expires in $secondsLeft seconds',
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(busy ? Icons.sync_rounded : Icons.timer_outlined, size: 15, color: color),
          const SizedBox(width: 6),
          Text(
            busy ? 'Refreshing…' : 'Expires in ${secondsLeft}s',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: color),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final IconData icon;
  final String text;
  final bool isError;

  const _Message({required this.icon, required this.text, this.isError = false});

  @override
  Widget build(BuildContext context) {
    final color = isError ? Colors.red.shade700 : Colors.grey.shade600;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          Icon(icon, size: 26, color: color),
          const SizedBox(height: 10),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, height: 1.5, color: color),
          ),
        ],
      ),
    );
  }
}
