import 'package:flutter/material.dart';

import '../../../config/console_theme.dart';

/// The console's shared building blocks.
///
/// Every state a screen can be in — ideal, empty, loading, partial, error,
/// permission — has a widget here, so no screen has to invent "No data." on the
/// spot. Interactive pieces carry a visible focus ring and a 44px target.

// ─── Surfaces ─────────────────────────────────────────────────────────────────

class ConsoleCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? accent;

  const ConsoleCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(Insets.xl),
    this.onTap,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final card = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: t.surface,
        borderRadius: Radii.card,
        border: Border.all(color: accent ?? t.border),
        boxShadow: t.cardShadow,
      ),
      child: child,
    );
    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: Radii.card,
        child: card,
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> actions;

  const SectionHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  fontSize: FontSizes.heading,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                  color: t.text,
                ),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: Insets.xs),
                Text(
                  subtitle!,
                  style: TextStyle(
                    fontSize: FontSizes.body,
                    height: 1.5,
                    color: t.textMuted,
                  ),
                ),
              ],
            ],
          ),
        ),
        if (actions.isNotEmpty) ...[
          const SizedBox(width: Insets.lg),
          Wrap(spacing: Insets.sm, children: actions),
        ],
      ],
    );
  }
}

// ─── Status ───────────────────────────────────────────────────────────────────

/// A status pill. Always carries an icon and a word, so the meaning survives
/// for anyone who cannot distinguish the colours.
class StatusBadge extends StatelessWidget {
  final String label;
  final StatusTone tone;
  final IconData icon;
  final bool dense;

  const StatusBadge({
    super.key,
    required this.label,
    required this.tone,
    required this.icon,
    this.dense = false,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Status: $label',
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: dense ? Insets.sm : Insets.md,
          vertical: dense ? 2 : Insets.xs,
        ),
        decoration: BoxDecoration(
          color: tone.bg,
          border: Border.all(color: tone.border),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: dense ? 12 : 14, color: tone.fg),
            const SizedBox(width: Insets.xs + 2),
            Text(
              label,
              style: TextStyle(
                fontSize: dense ? 11 : FontSizes.caption,
                fontWeight: FontWeight.w600,
                color: tone.fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Buttons ──────────────────────────────────────────────────────────────────

enum ConsoleButtonKind { primary, secondary, danger, ghost }

class ConsoleButton extends StatefulWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final ConsoleButtonKind kind;
  final bool busy;

  /// Shown when [onPressed] is null. A disabled control hides its own reason,
  /// so the console explains it instead of leaving the operator guessing.
  final String? disabledReason;

  const ConsoleButton({
    super.key,
    required this.label,
    this.icon,
    this.onPressed,
    this.kind = ConsoleButtonKind.primary,
    this.busy = false,
    this.disabledReason,
  });

  @override
  State<ConsoleButton> createState() => _ConsoleButtonState();
}

class _ConsoleButtonState extends State<ConsoleButton> {
  bool _focused = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final disabled = widget.onPressed == null || widget.busy;

    late final Color bg;
    late final Color fg;
    late final Color? border;
    switch (widget.kind) {
      case ConsoleButtonKind.primary:
        bg = _hovered ? t.brandHover : t.brand;
        fg = t.onBrand;
        border = null;
        break;
      case ConsoleButtonKind.secondary:
        bg = _hovered ? t.surfaceMuted : t.surface;
        fg = t.text;
        border = t.borderStrong;
        break;
      case ConsoleButtonKind.danger:
        bg = _hovered ? t.danger.border : t.danger.bg;
        fg = t.danger.fg;
        border = t.danger.border;
        break;
      case ConsoleButtonKind.ghost:
        bg = _hovered ? t.surfaceMuted : Colors.transparent;
        fg = t.textMuted;
        border = null;
        break;
    }

    final child = Container(
      constraints: const BoxConstraints(minHeight: 44),
      padding: const EdgeInsets.symmetric(horizontal: Insets.lg, vertical: Insets.md),
      decoration: BoxDecoration(
        color: disabled ? bg.withValues(alpha: 0.45) : bg,
        borderRadius: Radii.control,
        border: border == null ? null : Border.all(color: border),
        boxShadow: _focused
            ? [BoxShadow(color: t.focusRing, spreadRadius: 2, blurRadius: 0, offset: Offset.zero)]
            : null,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.busy)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: fg),
            )
          else if (widget.icon != null)
            Icon(widget.icon, size: 18, color: fg),
          if (widget.busy || widget.icon != null) const SizedBox(width: Insets.sm),
          Text(
            widget.label,
            style: TextStyle(
              fontSize: FontSizes.body,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ],
      ),
    );

    final button = FocusableActionDetector(
      enabled: !disabled,
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      onShowHoverHighlight: (v) => setState(() => _hovered = v),
      mouseCursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onPressed?.call();
            return null;
          },
        ),
      },
      child: Semantics(
        button: true,
        enabled: !disabled,
        label: widget.label,
        child: GestureDetector(
          onTap: disabled ? null : widget.onPressed,
          child: AnimatedContainer(
            duration: Motion.state,
            curve: Motion.enter,
            child: child,
          ),
        ),
      ),
    );

    if (disabled && widget.disabledReason != null) {
      return Tooltip(message: widget.disabledReason!, child: button);
    }
    return button;
  }
}

// ─── States ───────────────────────────────────────────────────────────────────

/// First-run / nothing-matched state. Says what belongs here and what fills it,
/// never a bare "No data."
class ConsoleEmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;

  const ConsoleEmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: Insets.xxxl, horizontal: Insets.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: t.surfaceMuted,
                  shape: BoxShape.circle,
                  border: Border.all(color: t.border),
                ),
                child: Icon(icon, color: t.textFaint, size: 26),
              ),
              const SizedBox(height: Insets.lg),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: FontSizes.bodyLg,
                  fontWeight: FontWeight.w600,
                  color: t.text,
                ),
              ),
              const SizedBox(height: Insets.sm),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: FontSizes.body, height: 1.5, color: t.textMuted),
              ),
              if (action != null) ...[
                const SizedBox(height: Insets.xl),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Failure state. Says what happened in the operator's terms and what to do
/// next — never a raw exception string alone.
class ConsoleErrorState extends StatelessWidget {
  final String title;
  final String message;
  final VoidCallback? onRetry;
  final String? technicalDetail;

  const ConsoleErrorState({
    super.key,
    this.title = 'Something went wrong',
    required this.message,
    this.onRetry,
    this.technicalDetail,
  });

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Semantics(
          liveRegion: true,
          child: ConsoleCard(
            accent: t.danger.border,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.error_outline_rounded, color: t.danger.fg, size: 20),
                    const SizedBox(width: Insets.sm),
                    Expanded(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontSize: FontSizes.bodyLg,
                          fontWeight: FontWeight.w600,
                          color: t.text,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: Insets.sm),
                Text(
                  message,
                  style: TextStyle(fontSize: FontSizes.body, height: 1.5, color: t.textMuted),
                ),
                if (technicalDetail != null) ...[
                  const SizedBox(height: Insets.md),
                  SelectableText(
                    technicalDetail!,
                    style: TextStyle(
                      fontSize: FontSizes.caption,
                      fontFamily: 'monospace',
                      color: t.textFaint,
                    ),
                  ),
                ],
                if (onRetry != null) ...[
                  const SizedBox(height: Insets.lg),
                  ConsoleButton(
                    label: 'Try again',
                    icon: Icons.refresh_rounded,
                    kind: ConsoleButtonKind.secondary,
                    onPressed: onRetry,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Skeleton rows that match the final layout, so the page does not jump when
/// the data lands. Shown only past ~400ms of waiting.
class ConsoleSkeleton extends StatefulWidget {
  final int rows;
  final double rowHeight;

  const ConsoleSkeleton({super.key, this.rows = 5, this.rowHeight = 64});

  @override
  State<ConsoleSkeleton> createState() => _ConsoleSkeletonState();
}

class _ConsoleSkeletonState extends State<ConsoleSkeleton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))
        ..repeat(reverse: true);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    // Respect a reduced-motion preference: hold a steady tone instead of pulsing.
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Semantics(
      label: 'Loading',
      liveRegion: true,
      child: Column(
        children: List.generate(
          widget.rows,
          (i) => Padding(
            padding: const EdgeInsets.only(bottom: Insets.md),
            child: AnimatedBuilder(
              animation: _c,
              builder: (context, _) => Opacity(
                opacity: reduceMotion ? 0.6 : 0.4 + (_c.value * 0.3),
                child: Container(
                  height: widget.rowHeight,
                  decoration: BoxDecoration(
                    color: t.surfaceMuted,
                    borderRadius: Radii.card,
                    border: Border.all(color: t.border),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Shows [child] only after [delay], so a fast response never flashes a
/// skeleton. Under ~200ms the console shows nothing at all.
class DelayedLoader extends StatefulWidget {
  final Widget child;
  final Duration delay;

  const DelayedLoader({
    super.key,
    required this.child,
    this.delay = const Duration(milliseconds: 400),
  });

  @override
  State<DelayedLoader> createState() => _DelayedLoaderState();
}

class _DelayedLoaderState extends State<DelayedLoader> {
  bool _show = false;

  @override
  void initState() {
    super.initState();
    Future.delayed(widget.delay, () {
      if (mounted) setState(() => _show = true);
    });
  }

  @override
  Widget build(BuildContext context) =>
      _show ? widget.child : const SizedBox.shrink();
}

// ─── Inputs ───────────────────────────────────────────────────────────────────

class ConsoleSearchField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClear;

  const ConsoleSearchField({
    super.key,
    required this.controller,
    this.hint = 'Search',
    this.onChanged,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 340, minHeight: 44),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        textInputAction: TextInputAction.search,
        style: TextStyle(fontSize: FontSizes.body, color: t.text),
        decoration: InputDecoration(
          isDense: true,
          hintText: hint,
          hintStyle: TextStyle(color: t.textFaint, fontSize: FontSizes.body),
          prefixIcon: Icon(Icons.search_rounded, size: 18, color: t.textFaint),
          suffixIcon: controller.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close_rounded, size: 18),
                  tooltip: 'Clear search',
                  color: t.textFaint,
                  onPressed: () {
                    controller.clear();
                    onChanged?.call('');
                    onClear?.call();
                  },
                ),
          filled: true,
          fillColor: t.surface,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: Insets.md,
            vertical: Insets.md,
          ),
          border: OutlineInputBorder(
            borderRadius: Radii.control,
            borderSide: BorderSide(color: t.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: Radii.control,
            borderSide: BorderSide(color: t.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: Radii.control,
            borderSide: BorderSide(color: t.focusRing, width: 2),
          ),
        ),
      ),
    );
  }
}

/// A labelled field. The label sits above and stays visible — a placeholder is
/// never a label.
class ConsoleField extends StatelessWidget {
  final String label;
  final String? helper;
  final Widget child;
  final bool required;
  final String? errorText;

  const ConsoleField({
    super.key,
    required this.label,
    required this.child,
    this.helper,
    this.required = false,
    this.errorText,
  });

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: FontSizes.body,
                fontWeight: FontWeight.w600,
                color: t.text,
              ),
            ),
            if (required)
              Text(
                ' *',
                style: TextStyle(fontSize: FontSizes.body, color: t.danger.fg),
              ),
          ],
        ),
        if (helper != null) ...[
          const SizedBox(height: 2),
          Text(
            helper!,
            style: TextStyle(fontSize: FontSizes.caption, height: 1.45, color: t.textMuted),
          ),
        ],
        const SizedBox(height: Insets.sm),
        child,
        if (errorText != null) ...[
          const SizedBox(height: Insets.xs + 2),
          Semantics(
            liveRegion: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.error_outline_rounded, size: 14, color: t.danger.fg),
                const SizedBox(width: Insets.xs + 2),
                Expanded(
                  child: Text(
                    errorText!,
                    style: TextStyle(fontSize: FontSizes.caption, color: t.danger.fg),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

// ─── Metrics ──────────────────────────────────────────────────────────────────

/// One number on the Overview, with what it means and where it leads.
class MetricTile extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final StatusTone? tone;
  final String? caption;
  final VoidCallback? onTap;

  const MetricTile({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    this.tone,
    this.caption,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final tint = tone ?? t.neutral;
    return ConsoleCard(
      onTap: onTap,
      padding: const EdgeInsets.all(Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: tint.bg,
                  borderRadius: BorderRadius.circular(Radii.base),
                  border: Border.all(color: tint.border),
                ),
                child: Icon(icon, size: 17, color: tint.fg),
              ),
              const Spacer(),
              if (onTap != null)
                Icon(Icons.arrow_forward_rounded, size: 16, color: t.textFaint),
            ],
          ),
          const SizedBox(height: Insets.md),
          Text(
            value,
            style: TextStyle(
              fontSize: FontSizes.display,
              fontWeight: FontWeight.w700,
              height: 1.1,
              letterSpacing: -0.8,
              color: t.text,
            ),
          ),
          const SizedBox(height: Insets.xs),
          Text(
            label,
            style: TextStyle(
              fontSize: FontSizes.body,
              fontWeight: FontWeight.w500,
              color: t.textMuted,
            ),
          ),
          if (caption != null) ...[
            const SizedBox(height: Insets.xs),
            Text(
              caption!,
              style: TextStyle(fontSize: FontSizes.caption, color: t.textFaint),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Pagination ───────────────────────────────────────────────────────────────

class ConsolePagination extends StatelessWidget {
  final int page;
  final int pageSize;
  final int shown;
  final bool hasMore;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;

  const ConsolePagination({
    super.key,
    required this.page,
    required this.pageSize,
    required this.shown,
    required this.hasMore,
    this.onPrevious,
    this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final first = shown == 0 ? 0 : page * pageSize + 1;
    final last = page * pageSize + shown;
    return Row(
      children: [
        Text(
          shown == 0 ? 'No results' : 'Showing $first–$last',
          style: TextStyle(fontSize: FontSizes.caption, color: t.textMuted),
        ),
        const Spacer(),
        ConsoleButton(
          label: 'Previous',
          icon: Icons.chevron_left_rounded,
          kind: ConsoleButtonKind.secondary,
          onPressed: page > 0 ? onPrevious : null,
          disabledReason: 'You are on the first page',
        ),
        const SizedBox(width: Insets.sm),
        ConsoleButton(
          label: 'Next',
          kind: ConsoleButtonKind.secondary,
          onPressed: hasMore ? onNext : null,
          disabledReason: 'No more results',
        ),
      ],
    );
  }
}
