import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Smoothly interpolates each tracked person's marker position between Firestore
/// updates, the same way Life360 makes markers "walk" across the map rather
/// than teleport.
///
/// Usage:
///   1. Wrap the map screen in a [StatefulWidget] that owns a [LiveTracker].
///   2. Call `tracker.setTargets({uid: LatLng, ...})` every time Firestore
///      emits a new snapshot.
///   3. Build markers using `tracker.current(uid)` instead of the raw Firestore
///      lat/lng. The tracker rebuilds the listening widgets at the display
///      refresh rate, so positions slide smoothly toward the latest target.
///
/// Construct on a [TickerProvider] (`with TickerProviderStateMixin`) and call
/// [dispose] in your State's dispose.
class LiveTracker extends ChangeNotifier {
  /// How long the marker takes to slide to a new target.
  /// Roughly matches Life360's perceived smoothness.
  final Duration tweenDuration;

  /// Per-uid animated track.
  final Map<String, _Track> _tracks = {};

  Ticker? _ticker;

  LiveTracker({
    required TickerProvider vsync,
    this.tweenDuration = const Duration(milliseconds: 800),
  }) {
    _ticker = vsync.createTicker(_onTick)..start();
  }

  void _onTick(Duration _) {
    // Always notify so the AnimatedBuilder rebuilds every frame — this is what
    // lets own-position markers (driven by local GPS, not Firestore) update in
    // real-time without waiting for a Firestore event to trigger a rebuild.
    notifyListeners();
  }

  /// Replace the set of target positions. Anything missing from [targets]
  /// is dropped from the tracker.
  void setTargets(Map<String, LatLng> targets) {
    final now = DateTime.now();
    final keep = <String>{};

    targets.forEach((uid, target) {
      keep.add(uid);
      final existing = _tracks[uid];
      if (existing == null) {
        // First fix: snap immediately, no animation.
        _tracks[uid] = _Track(start: target, target: target, startedAt: now);
      } else if (existing.target.latitude != target.latitude ||
          existing.target.longitude != target.longitude) {
        // New target: tween from where we are right now.
        final from = existing.interpolatedAt(now, tweenDuration);
        _tracks[uid] = _Track(start: from, target: target, startedAt: now);
      }
    });

    // Drop tracks the caller no longer cares about.
    _tracks.removeWhere((uid, _) => !keep.contains(uid));

    // Surface immediately so a freshly-added user gets a marker on the next frame.
    notifyListeners();
  }

  /// Current interpolated position for [uid], or null if not tracked.
  LatLng? current(String uid) {
    final t = _tracks[uid];
    if (t == null) return null;
    return t.interpolatedAt(DateTime.now(), tweenDuration);
  }

  /// Number of tracked people.
  int get count => _tracks.length;

  @override
  void dispose() {
    _ticker?.dispose();
    _ticker = null;
    super.dispose();
  }
}

class _Track {
  final LatLng start;
  final LatLng target;
  final DateTime startedAt;

  _Track({required this.start, required this.target, required this.startedAt});

  bool isDone(DateTime now, Duration duration) =>
      now.difference(startedAt) >= duration;

  LatLng interpolatedAt(DateTime now, Duration duration) {
    final ms = duration.inMilliseconds;
    if (ms <= 0) return target;
    final t = now.difference(startedAt).inMilliseconds / ms;
    if (t >= 1.0) return target;
    if (t <= 0.0) return start;
    // Ease-out so the marker decelerates as it reaches the target.
    final eased = 1 - _pow(1 - t, 3);
    return LatLng(
      start.latitude + (target.latitude - start.latitude) * eased,
      start.longitude + (target.longitude - start.longitude) * eased,
    );
  }

  static double _pow(double x, int n) {
    double r = 1.0;
    for (int i = 0; i < n; i++) {
      r *= x;
    }
    return r;
  }
}
