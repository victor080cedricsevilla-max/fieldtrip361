import 'package:flutter/material.dart';

/// Swaps between tab pages with a directional slide and fade, without losing
/// what each page had built.
///
/// [IndexedStack] keeps state but cannot animate; [AnimatedSwitcher] animates
/// but rebuilds the incoming page from scratch, which drops scroll position,
/// re-runs every query and clears half-filled forms. This keeps all pages
/// mounted — so their state survives — and animates only the two involved in
/// the change.
///
/// Direction follows the tab order: moving right through the bar brings the
/// next page in from the right, and moving back brings it in from the left.
class AnimatedTabView extends StatefulWidget {
  final int index;
  final List<Widget> children;
  final Duration duration;

  const AnimatedTabView({
    super.key,
    required this.index,
    required this.children,
    this.duration = const Duration(milliseconds: 260),
  });

  @override
  State<AnimatedTabView> createState() => _AnimatedTabViewState();
}

class _AnimatedTabViewState extends State<AnimatedTabView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: 1,
  );

  late int _current = widget.index;
  int? _previous;
  int _direction = 1;

  @override
  void didUpdateWidget(covariant AnimatedTabView old) {
    super.didUpdateWidget(old);
    if (widget.index == _current) return;
    setState(() {
      _previous = _current;
      _direction = widget.index > _current ? 1 : -1;
      _current = widget.index;
    });
    _controller
      ..value = 0
      ..forward().whenComplete(() {
        if (mounted) setState(() => _previous = null);
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = reduceMotion ? 1.0 : Curves.easeOutCubic.transform(_controller.value);
        return Stack(
          children: [
            for (var i = 0; i < widget.children.length; i++)
              _layer(i, t),
          ],
        );
      },
    );
  }

  Widget _layer(int i, double t) {
    final isCurrent = i == _current;
    final isLeaving = i == _previous;

    // Everything else stays mounted but takes no space, paints nothing, and
    // has its tickers stopped so off-screen pages cost no frames.
    if (!isCurrent && !isLeaving) {
      return Offstage(
        offstage: true,
        child: TickerMode(enabled: false, child: widget.children[i]),
      );
    }

    // A short travel: the slide is there to say which way the tabs moved, not
    // to make the page look like it came from somewhere far away.
    const travel = 0.045;
    final dx = isCurrent
        ? (1 - t) * travel * _direction
        : -t * travel * _direction;

    return Positioned.fill(
      child: IgnorePointer(
        ignoring: isLeaving,
        child: Opacity(
          opacity: isCurrent ? t : (1 - t),
          child: FractionalTranslation(
            translation: Offset(dx, 0),
            child: widget.children[i],
          ),
        ),
      ),
    );
  }
}
