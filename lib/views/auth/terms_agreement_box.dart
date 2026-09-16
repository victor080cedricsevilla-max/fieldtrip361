import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../config/theme.dart';
import 'terms_content.dart';

/// The Terms and Privacy Notice, in a panel whose "I agree" tick box only
/// unlocks once the reader has scrolled to the bottom of the notice.
///
/// The same widget serves web and mobile — it sizes itself to the window and
/// shows a visible scrollbar, which is the only hint a mouse user gets that
/// there is more text below.
///
/// The tick state itself lives in the parent form, so the submit button can
/// read it; this widget owns only "have they reached the end".
class TermsAgreementBox extends StatefulWidget {
  const TermsAgreementBox({
    super.key,
    required this.accepted,
    required this.onAcceptedChanged,
    this.maxHeight = 260,
  });

  /// Whether the tick box is ticked right now.
  final bool accepted;

  /// Fired when the reader ticks or unticks the box. Never fires before the
  /// notice has been scrolled to the end.
  final ValueChanged<bool> onAcceptedChanged;

  /// Tallest the scrolling panel may be. It shrinks on short screens.
  final double maxHeight;

  @override
  State<TermsAgreementBox> createState() => _TermsAgreementBoxState();
}

class _TermsAgreementBoxState extends State<TermsAgreementBox> {
  /// Treat "a dozen pixels from the bottom" as the end: a trackpad fling often
  /// settles a pixel or two short, and nobody would call that unread.
  static const double _endSlack = 12;

  final ScrollController _controller = ScrollController();

  bool _readToEnd = false;
  double _progress = 0;

  /// Set briefly when someone taps the tick box before reading, to point them
  /// back at the panel.
  bool _nudge = false;
  Timer? _nudgeTimer;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
    // A short notice in a tall window never scrolls, so no scroll event would
    // ever arrive and the box could never unlock. Check once it has laid out.
    WidgetsBinding.instance.addPostFrameCallback((_) => _onScroll());
  }

  @override
  void dispose() {
    _nudgeTimer?.cancel();
    _controller.removeListener(_onScroll);
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_controller.hasClients) return;
    if (!_controller.position.hasContentDimensions) return;
    _sync(_controller.position);
  }

  /// [defer] when the metrics arrive during layout — calling setState then is
  /// an error, so the update waits for the frame to finish.
  void _sync(ScrollMetrics metrics, {bool defer = false}) {
    final double max = metrics.maxScrollExtent;
    final bool fitsOnScreen = max <= 0;
    final double progress =
        fitsOnScreen ? 1 : (metrics.pixels / max).clamp(0.0, 1.0);
    final bool atEnd = fitsOnScreen || metrics.pixels >= max - _endSlack;

    if (progress == _progress && (_readToEnd || !atEnd)) return;

    void apply() {
      if (!mounted) return;
      setState(() {
        _progress = progress;
        if (atEnd) {
          _readToEnd = true;
          _nudge = false;
          _nudgeTimer?.cancel();
        }
      });
    }

    if (defer) {
      WidgetsBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  void _nudgeToRead() {
    _nudgeTimer?.cancel();
    setState(() => _nudge = true);
    _nudgeTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _nudge = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool isDark = theme.brightness == Brightness.dark;
    final Color primary = AppTheme.effectivePrimary;

    final Color edge = _nudge
        ? AppTheme.errorColor
        : _readToEnd
            ? primary
            : (isDark ? Colors.white24 : Colors.grey.shade300);

    // Leave room for the rest of the form on a small phone, and never let the
    // panel grow past a comfortable reading height on a desktop window.
    final double panelHeight =
        math.min(widget.maxHeight, MediaQuery.sizeOf(context).height * 0.4);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: isDark ? AppTheme.darkSurface : Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: edge,
              width: _readToEnd || _nudge ? 1.5 : 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _header(theme, isDark, primary),
              Divider(height: 1, color: isDark ? Colors.white12 : Colors.grey.shade200),
              SizedBox(
                height: panelHeight,
                child: NotificationListener<ScrollMetricsNotification>(
                  // Fires when the window resizes or the text scale changes and
                  // the notice suddenly needs more or less scrolling.
                  onNotification: (notification) {
                    _sync(notification.metrics, defer: true);
                    return false;
                  },
                  child: Scrollbar(
                    controller: _controller,
                    thumbVisibility: true,
                    child: SingleChildScrollView(
                      controller: _controller,
                      padding: const EdgeInsets.fromLTRB(16, 14, 18, 18),
                      child: _notice(theme, isDark),
                    ),
                  ),
                ),
              ),
              _footer(theme, isDark, primary),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _tickBox(theme, isDark, primary),
      ],
    );
  }

  Widget _header(ThemeData theme, bool isDark, Color primary) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      color: isDark ? Colors.white.withValues(alpha: 0.03) : Colors.grey.shade50,
      child: Row(
        children: [
          Icon(Icons.privacy_tip_outlined, size: 18, color: primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  "Terms & Conditions and Privacy Notice",
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontSize: 13.5,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  "Version $kTermsVersion - $kTermsLastUpdated",
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontSize: 11,
                    color: isDark ? Colors.white54 : Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _notice(ThemeData theme, bool isDark) {
    final Color bodyColor = isDark ? AppTheme.darkText2 : Colors.grey.shade800;
    final TextStyle bodyStyle = TextStyle(
      fontSize: 12.5,
      height: 1.55,
      color: bodyColor,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(kTermsIntro, style: bodyStyle.copyWith(fontStyle: FontStyle.italic)),
        for (final TermsSection section in kTermsSections) ...[
          const SizedBox(height: 18),
          Text(
            section.heading,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: isDark ? Colors.white : AppTheme.darkText,
            ),
          ),
          const SizedBox(height: 6),
          Text(section.body, style: bodyStyle),
        ],
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.effectivePrimary.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Text(
            kTermsClosing,
            style: bodyStyle.copyWith(
              fontWeight: FontWeight.w600,
              color: isDark ? AppTheme.darkText2 : AppTheme.darkText,
            ),
          ),
        ),
      ],
    );
  }

  Widget _footer(ThemeData theme, bool isDark, Color primary) {
    final Color hintColor = _nudge
        ? AppTheme.errorColor
        : _readToEnd
            ? primary
            : (isDark ? Colors.white60 : Colors.grey.shade600);

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      color: isDark ? Colors.white.withValues(alpha: 0.03) : Colors.grey.shade50,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(begin: 0, end: _progress),
                    duration: const Duration(milliseconds: 150),
                    builder: (context, value, _) => LinearProgressIndicator(
                      value: value,
                      minHeight: 5,
                      backgroundColor:
                          isDark ? Colors.white12 : Colors.grey.shade200,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        _readToEnd ? primary : AppTheme.accentColor,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                "${(_progress * 100).round()}%",
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: _readToEnd ? primary : (isDark ? Colors.white54 : Colors.grey.shade600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                _readToEnd
                    ? Icons.check_circle_rounded
                    : Icons.keyboard_double_arrow_down_rounded,
                size: 14,
                color: hintColor,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _readToEnd
                      ? "You have reached the end. You can now tick the box below."
                      : "Scroll through the whole notice to unlock the tick box.",
                  style: TextStyle(
                    fontSize: 11.5,
                    height: 1.35,
                    fontWeight: _nudge ? FontWeight.w700 : FontWeight.w500,
                    color: hintColor,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _tickBox(ThemeData theme, bool isDark, Color primary) {
    final bool enabled = _readToEnd;

    return InkWell(
      borderRadius: BorderRadius.circular(10),
      // Tapping before the notice has been read explains itself instead of
      // doing nothing, which is how a disabled control usually feels.
      onTap: enabled
          ? () => widget.onAcceptedChanged(!widget.accepted)
          : _nudgeToRead,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(
              width: 28,
              height: 28,
              child: Checkbox(
                value: widget.accepted,
                activeColor: primary,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: enabled
                    ? (bool? value) => widget.onAcceptedChanged(value ?? false)
                    : null,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                "I have read and agree to the Terms & Conditions and the "
                "Privacy Notice, including how my personal information and my "
                "child's information are collected and used.",
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  fontWeight: widget.accepted ? FontWeight.w600 : FontWeight.w500,
                  color: enabled
                      ? (isDark ? AppTheme.darkText2 : AppTheme.darkText)
                      : (isDark ? Colors.white38 : Colors.grey.shade500),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
