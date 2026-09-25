import 'package:audioplayers/audioplayers.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

/// The alarm that keeps going until somebody deals with it.
///
/// This used to be `FlutterRingtonePlayer(fromAsset:, looping: true)`, and on
/// Android that combination does not reliably loop — it played the file a few
/// times and stopped on its own. A geofence alarm that falls silent while the
/// student is still outside is worse than no alarm, because the screen still
/// says there is a problem and the room has stopped hearing one.
///
/// `audioplayers` with `ReleaseMode.loop` does loop, and the project already
/// depends on it for the custom emergency sound, so both paths now run through
/// the same player and the same stop.
class AlarmPlayer {
  AlarmPlayer._();

  static AudioPlayer? _player;
  static bool _starting = false;

  /// Plays on the alarm stream so it is audible when the ringer is low, and
  /// ducks nothing — a notification chime arriving alongside it must not be
  /// able to take the focus and end it.
  static final AudioContext _context = AudioContext(
    android: const AudioContextAndroid(
      isSpeakerphoneOn: true,
      stayAwake: true,
      contentType: AndroidContentType.sonification,
      usageType: AndroidUsageType.alarm,
      audioFocus: AndroidAudioFocus.gainTransientMayDuck,
    ),
    iOS: AudioContextIOS(
      category: AVAudioSessionCategory.playback,
      options: const {AVAudioSessionOptions.mixWithOthers},
    ),
  );

  /// Starts the alarm, looping, and keeps it going until [stop].
  ///
  /// Calling it again while it is already sounding does nothing, so a second
  /// alert for the same student cannot restart — or worse, replace — the
  /// player that is already running.
  static Future<void> start() async {
    if (_player != null || _starting) return;
    _starting = true;
    try {
      final player = AudioPlayer();
      await player.setAudioContext(_context);
      await player.setReleaseMode(ReleaseMode.loop);
      await player.setVolume(1.0);

      // A school may upload its own alarm; fall back to the bundled one if it
      // is missing or will not load, rather than leaving the room in silence.
      final custom = await _customSoundUrl();
      try {
        if (custom != null && custom.isNotEmpty) {
          await player.play(UrlSource(custom));
        } else {
          await player.play(AssetSource('audio/alarm.mp3'));
        }
      } catch (e) {
        debugPrint('[alarm] custom sound failed, using bundled: $e');
        await player.play(AssetSource('audio/alarm.mp3'));
      }
      _player = player;
    } catch (e) {
      debugPrint('[alarm] could not start: $e');
    } finally {
      _starting = false;
    }
  }

  /// Stops and releases the alarm. Safe to call when nothing is playing.
  static Future<void> stop() async {
    final player = _player;
    _player = null;
    if (player == null) return;
    try {
      await player.stop();
      await player.dispose();
    } catch (e) {
      debugPrint('[alarm] could not stop cleanly: $e');
    }
  }

  static bool get isPlaying => _player != null;

  static Future<String?> _customSoundUrl() async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return null;
      final snap =
          await FirebaseFirestore.instance.collection('users').doc(uid).get();
      return snap.data()?['emergencySoundUrl'] as String?;
    } catch (_) {
      return null;
    }
  }
}
