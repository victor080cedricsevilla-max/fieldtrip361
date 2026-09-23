import 'package:flutter/material.dart';

import '../../../config/console_theme.dart';
import 'console_ui.dart';

/// Confirms an action that cannot be undone from the console and records why.
///
/// Every destructive or outward-facing platform action — suspending an
/// administrator, rejecting an application, overriding a review warning —
/// stores the reason in the audit log, so the reason is collected here rather
/// than invented afterwards.
class ReasonDialog extends StatefulWidget {
  final String title;
  final String description;
  final String confirmLabel;
  final IconData confirmIcon;
  final ConsoleButtonKind confirmKind;
  final String reasonLabel;
  final String reasonHelper;
  final int minLength;

  /// Extra content shown between the description and the reason field —
  /// a document checklist, a consequence summary.
  final Widget? extra;

  const ReasonDialog({
    super.key,
    required this.title,
    required this.description,
    required this.confirmLabel,
    this.confirmIcon = Icons.check_rounded,
    this.confirmKind = ConsoleButtonKind.primary,
    this.reasonLabel = 'Reason',
    this.reasonHelper = 'Recorded in the audit log and, where relevant, sent to the applicant.',
    this.minLength = 10,
    this.extra,
  });

  /// Returns the typed reason, or null when dismissed.
  static Future<String?> show(BuildContext context, ReasonDialog dialog) {
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => dialog,
    );
  }

  @override
  State<ReasonDialog> createState() => _ReasonDialogState();
}

class _ReasonDialogState extends State<ReasonDialog> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  String? _error;

  @override
  void initState() {
    super.initState();
    // Focus lands on the field, and Escape closes — both expected of a modal.
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _submit() {
    final value = _controller.text.trim();
    if (value.length < widget.minLength) {
      setState(() => _error =
          'Write at least ${widget.minLength} characters so the record is useful later.');
      return;
    }
    Navigator.of(context).pop(value);
  }

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);

    return Dialog(
      backgroundColor: t.surface,
      shape: const RoundedRectangleBorder(borderRadius: Radii.card),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(Insets.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.title,
                style: TextStyle(
                  fontSize: FontSizes.title,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                  color: t.text,
                ),
              ),
              const SizedBox(height: Insets.sm),
              Text(
                widget.description,
                style: TextStyle(fontSize: FontSizes.body, height: 1.55, color: t.textMuted),
              ),
              if (widget.extra != null) ...[
                const SizedBox(height: Insets.lg),
                widget.extra!,
              ],
              const SizedBox(height: Insets.lg),
              ConsoleField(
                label: widget.reasonLabel,
                helper: widget.reasonHelper,
                required: true,
                errorText: _error,
                child: TextField(
                  controller: _controller,
                  focusNode: _focus,
                  minLines: 3,
                  maxLines: 6,
                  onChanged: (_) {
                    if (_error != null) setState(() => _error = null);
                  },
                  decoration: const InputDecoration(
                    hintText: 'Be specific — this is what the record will say.',
                  ),
                ),
              ),
              const SizedBox(height: Insets.xl),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  ConsoleButton(
                    label: 'Cancel',
                    kind: ConsoleButtonKind.ghost,
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: Insets.sm),
                  ConsoleButton(
                    label: widget.confirmLabel,
                    icon: widget.confirmIcon,
                    kind: widget.confirmKind,
                    onPressed: _submit,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
