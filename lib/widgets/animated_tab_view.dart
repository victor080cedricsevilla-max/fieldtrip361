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
        // A Stack takes its size from its non-positioned children, and every
        // layer here is either positioned or zero-sized, so left alone it
        // collapses to nothing along whichever axis its parent leaves loose.
        // The column above gives a tight height and a loose width, which
        // rendered the pages zero-wide — blank, with only the bar visible.
        return SizedBox.expand(
          child: Stack(
            fit: StackFit.expand,
            children: [
              for (var i = 0; i < widget.children.length; i++)
                _layer(i, t),
            ],
          ),
        );
      },
    );
  }

  /// Builds one page's layer.
  ///
  /// Every layer gets the identical chain of wrappers and differs only in
  /// their arguments. Swapping a hidden page to a different set of widgets
  /// would change the shape of the tree, Flutter would fail to match the
  /// element underneath, and the page's State — its scroll offset, its loaded
  /// data, its half-typed form — would be thrown away on every tab change,
  /// which is the one thing this widget exists to prevent.
  Widget _layer(int i, double t) {
    final isCurrent = i == _current;
    final isLeaving = i == _previous;
    final visible = isCurrent || isLeaving;

    // A short travel: the slide is there to say which way the tabs moved, not
    // to make the page look like it came from somewhere far away.
    const travel = 0.045;
    final dx = isCurrent
        ? (1 - t) * travel * _direction
        : -t * travel * _direction;

    // Positioned like the rest: a bare Offstage is a zero-sized non-positioned
    // child, and a Stack sizes itself to those — it would collapse the lot.
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !isCurrent,
        child: Offstage(
          offstage: !visible,
          child: TickerMode(
            enabled: visible,
            child: Opacity(
              opacity: !visible ? 1 : (isCurrent ? t : 1 - t),
              child: FractionalTranslation(
                translation: Offset(visible ? dx : 0, 0),
                child: widget.children[i],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
