import 'package:flutter/material.dart';

import '../../config/theme.dart';

/// A compact time picker that drops down under the field that opened it:
/// hour, minute and AM/PM columns, with "Time Now" and "Apply" underneath.
///
/// Returns the chosen time, or null when dismissed by tapping outside.
Future<TimeOfDay?> showTimePickerPopover({
  required BuildContext anchorContext,
  TimeOfDay? initial,
  int minuteStep = 15,
}) {
  final box = anchorContext.findRenderObject() as RenderBox;
  final origin = box.localToGlobal(Offset.zero);
  final anchor = origin & box.size;

  return showGeneralDialog<TimeOfDay>(
    context: anchorContext,
    barrierDismissible: true,
    barrierLabel: 'Close time picker',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 140),
    pageBuilder: (ctx, _, __) {
      final screen = MediaQuery.sizeOf(ctx);
      const width = _PopoverState.panelWidth;
      const height = _PopoverState.panelHeight;
      final left = anchor.left.clamp(8.0, (screen.width - width - 8).clamp(8.0, double.infinity));
      // Below the field when it fits, otherwise above it.
      final below = anchor.bottom + 8;
      final top = below + height <= screen.height - 8 ? below : (anchor.top - height - 8).clamp(8.0, double.infinity);
      return Stack(
        children: [
          Positioned(
            left: left.toDouble(),
            top: top.toDouble(),
            child: _Popover(initial: initial, minuteStep: minuteStep),
          ),
        ],
      );
    },
    transitionBuilder: (ctx, anim, _, child) => FadeTransition(
      opacity: anim,
      child: ScaleTransition(
        scale: Tween(begin: 0.97, end: 1.0).animate(CurvedAnimation(parent: anim, curve: Curves.easeOut)),
        alignment: Alignment.topLeft,
        child: child,
      ),
    ),
  );
}

/// "07:00 AM" — the format trip stops are saved in.
String formatTime12(TimeOfDay t) {
  final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
  final m = t.minute.toString().padLeft(2, '0');
  return '${h.toString().padLeft(2, '0')}:$m ${t.period == DayPeriod.am ? 'AM' : 'PM'}';
}

/// Reads "7:00 AM" / "07:00 PM" back into a time; null when it isn't one.
TimeOfDay? parseTime12(String text) {
  final m = RegExp(r'^\s*(\d{1,2}):(\d{2})\s*([AaPp][Mm])\s*$').firstMatch(text);
  if (m == null) return null;
  final h = int.parse(m.group(1)!);
  final min = int.parse(m.group(2)!);
  if (h < 1 || h > 12 || min > 59) return null;
  final pm = m.group(3)!.toUpperCase() == 'PM';
  return TimeOfDay(hour: (h % 12) + (pm ? 12 : 0), minute: min);
}

class _Popover extends StatefulWidget {
  final TimeOfDay? initial;
  final int minuteStep;

  const _Popover({this.initial, required this.minuteStep});

  @override
  State<_Popover> createState() => _PopoverState();
}

class _PopoverState extends State<_Popover> {
  static const panelWidth = 272.0;
  static const rowHeight = 44.0;
  static const visibleRows = 5;
  static const panelHeight = rowHeight * visibleRows + 16 + 69;

  late int _hour; // 1–12
  late int _minute;
  late bool _pm;

  late final ScrollController _hourScroll;
  late final ScrollController _minuteScroll;

  List<int> get _minutes => [for (var m = 0; m < 60; m += widget.minuteStep) m];

  @override
  void initState() {
    super.initState();
    _set(widget.initial ?? _rounded(TimeOfDay.now()));
    _hourScroll = ScrollController(initialScrollOffset: (_hour - 1) * rowHeight);
    _minuteScroll = ScrollController(initialScrollOffset: _minutes.indexOf(_minute) * rowHeight);
  }

  @override
  void dispose() {
    _hourScroll.dispose();
    _minuteScroll.dispose();
    super.dispose();
  }

  TimeOfDay _rounded(TimeOfDay t) {
    final step = widget.minuteStep;
    var total = t.hour * 60 + ((t.minute / step).round() * step);
    total %= 24 * 60;
    return TimeOfDay(hour: total ~/ 60, minute: total % 60);
  }

  void _set(TimeOfDay t) {
    final snapped = _minutes.contains(t.minute) ? t : _rounded(t);
    _hour = snapped.hourOfPeriod == 0 ? 12 : snapped.hourOfPeriod;
    _minute = snapped.minute;
    _pm = snapped.period == DayPeriod.pm;
  }

  TimeOfDay get _value => TimeOfDay(hour: (_hour % 12) + (_pm ? 12 : 0), minute: _minute);

  void _scrollTo(ScrollController c, int index) {
    if (!c.hasClients) return;
    c.animateTo(
      (index * rowHeight).clamp(0.0, c.position.maxScrollExtent),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  void _timeNow() {
    setState(() => _set(_rounded(TimeOfDay.now())));
    _scrollTo(_hourScroll, _hour - 1);
    _scrollTo(_minuteScroll, _minutes.indexOf(_minute));
  }

  @override
  Widget build(BuildContext context) {
    final primary = AppTheme.effectivePrimary;
    final divider = Colors.grey.shade200;

    Widget column<T>({
      required List<T> items,
      required T selected,
      required String Function(T) label,
      required ValueChanged<T> onTap,
      ScrollController? controller,
    }) {
      return Expanded(
        child: ListView.builder(
          controller: controller,
          padding: EdgeInsets.zero,
          itemExtent: rowHeight,
          itemCount: items.length,
          itemBuilder: (_, i) {
            final item = items[i];
            final isSelected = item == selected;
            return Center(
              child: Material(
                color: isSelected ? primary : Colors.transparent,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => onTap(item),
                  child: SizedBox(
                    width: 38,
                    height: 38,
                    child: Center(
                      child: Text(
                        label(item),
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                          color: isSelected ? Colors.white : Colors.grey.shade700,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
    }

    return Material(
      color: Colors.white,
      elevation: 10,
      shadowColor: Colors.black.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        width: panelWidth,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: divider),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: rowHeight * visibleRows + 16,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    column<int>(
                      items: [for (var h = 1; h <= 12; h++) h],
                      selected: _hour,
                      label: (h) => h.toString().padLeft(2, '0'),
                      onTap: (h) => setState(() => _hour = h),
                      controller: _hourScroll,
                    ),
                    column<int>(
                      items: _minutes,
                      selected: _minute,
                      label: (m) => m.toString().padLeft(2, '0'),
                      onTap: (m) => setState(() => _minute = m),
                      controller: _minuteScroll,
                    ),
                    VerticalDivider(width: 1, thickness: 1, color: divider),
                    column<bool>(
                      items: const [false, true],
                      selected: _pm,
                      label: (pm) => pm ? 'PM' : 'AM',
                      onTap: (pm) => setState(() => _pm = pm),
                    ),
                  ],
                ),
              ),
            ),
            Divider(height: 1, thickness: 1, color: divider),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  TextButton(
                    onPressed: _timeNow,
                    style: TextButton.styleFrom(
                      foregroundColor: primary,
                      backgroundColor: primary.withValues(alpha: 0.08),
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Text('Time Now', style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  const Spacer(),
                  FilledButton(
                    onPressed: () => Navigator.of(context).pop(_value),
                    style: FilledButton.styleFrom(
                      backgroundColor: primary,
                      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Text('Apply', style: TextStyle(fontWeight: FontWeight.w600)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
