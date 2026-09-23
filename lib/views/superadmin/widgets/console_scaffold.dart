import 'package:flutter/material.dart';

import '../../../config/console_theme.dart';

/// One entry in the console sidebar.
class ConsoleNavItem {
  final String label;
  final IconData icon;
  final IconData activeIcon;

  /// Shown as a count pill — what is waiting for the operator in that section.
  final int? badge;

  const ConsoleNavItem({
    required this.label,
    required this.icon,
    required this.activeIcon,
    this.badge,
  });
}

/// The console's frame: a fixed sidebar on wide screens, a drawer below
/// [Breakpoints.sidebarCollapse], and a content area that never scrolls
/// sideways.
class ConsoleScaffold extends StatelessWidget {
  final List<ConsoleNavItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final Widget child;
  final String accountName;
  final String accountEmail;
  final VoidCallback onSignOut;
  final List<Widget> headerActions;

  const ConsoleScaffold({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelect,
    required this.child,
    required this.accountName,
    required this.accountEmail,
    required this.onSignOut,
    this.headerActions = const [],
  });

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final wide = MediaQuery.sizeOf(context).width >= Breakpoints.sidebarCollapse;

    return Scaffold(
      backgroundColor: t.page,
      drawer: wide
          ? null
          : Drawer(
              backgroundColor: t.sidebar,
              child: _Sidebar(
                items: items,
                selectedIndex: selectedIndex,
                onSelect: (i) {
                  Navigator.of(context).pop();
                  onSelect(i);
                },
                accountName: accountName,
                accountEmail: accountEmail,
                onSignOut: onSignOut,
              ),
            ),
      appBar: wide
          ? null
          : AppBar(
              backgroundColor: t.surface,
              surfaceTintColor: Colors.transparent,
              elevation: 0,
              shape: Border(bottom: BorderSide(color: t.border)),
              title: Text(
                items[selectedIndex].label,
                style: TextStyle(
                  fontSize: FontSizes.bodyLg,
                  fontWeight: FontWeight.w700,
                  color: t.text,
                ),
              ),
              actions: [...headerActions, const SizedBox(width: Insets.sm)],
            ),
      body: Row(
        children: [
          if (wide)
            SizedBox(
              width: 264,
              child: _Sidebar(
                items: items,
                selectedIndex: selectedIndex,
                onSelect: onSelect,
                accountName: accountName,
                accountEmail: accountEmail,
                onSignOut: onSignOut,
              ),
            ),
          Expanded(
            child: Column(
              children: [
                if (wide)
                  _TopBar(title: items[selectedIndex].label, actions: headerActions),
                Expanded(
                  child: Container(
                    color: t.page,
                    child: child,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final String title;
  final List<Widget> actions;

  const _TopBar({required this.title, required this.actions});

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    return Container(
      height: 68,
      padding: const EdgeInsets.symmetric(horizontal: Insets.xxl),
      decoration: BoxDecoration(
        color: t.surface,
        border: Border(bottom: BorderSide(color: t.border)),
      ),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: FontSizes.bodyLg,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
              color: t.text,
            ),
          ),
          const Spacer(),
          ...actions,
        ],
      ),
    );
  }
}

class _Sidebar extends StatelessWidget {
  final List<ConsoleNavItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final String accountName;
  final String accountEmail;
  final VoidCallback onSignOut;

  const _Sidebar({
    required this.items,
    required this.selectedIndex,
    required this.onSelect,
    required this.accountName,
    required this.accountEmail,
    required this.onSignOut,
  });

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    return Container(
      color: t.sidebar,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(Insets.xl, Insets.xl, Insets.xl, Insets.lg),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(Radii.base),
                    ),
                    child: const Icon(Icons.shield_moon_outlined,
                        color: Colors.white, size: 19),
                  ),
                  const SizedBox(width: Insets.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'FieldTrip360',
                          style: TextStyle(
                            fontSize: FontSizes.body,
                            fontWeight: FontWeight.w700,
                            color: t.sidebarText,
                            letterSpacing: -0.2,
                          ),
                        ),
                        Text(
                          'Platform console',
                          style: TextStyle(
                            fontSize: 11,
                            color: t.sidebarTextMuted,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: Insets.md),
                itemCount: items.length,
                itemBuilder: (context, i) => _NavTile(
                  item: items[i],
                  selected: i == selectedIndex,
                  onTap: () => onSelect(i),
                ),
              ),
            ),
            Divider(color: Colors.white.withValues(alpha: 0.10), height: 1),
            Padding(
              padding: const EdgeInsets.all(Insets.lg),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 16,
                    backgroundColor: Colors.white.withValues(alpha: 0.16),
                    child: Text(
                      accountName.isEmpty ? '?' : accountName.characters.first.toUpperCase(),
                      style: TextStyle(
                        color: t.sidebarText,
                        fontWeight: FontWeight.w700,
                        fontSize: FontSizes.caption,
                      ),
                    ),
                  ),
                  const SizedBox(width: Insets.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          accountName,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: FontSizes.caption,
                            fontWeight: FontWeight.w600,
                            color: t.sidebarText,
                          ),
                        ),
                        Text(
                          accountEmail,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11, color: t.sidebarTextMuted),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.logout_rounded, size: 18),
                    color: t.sidebarTextMuted,
                    tooltip: 'Sign out',
                    onPressed: onSignOut,
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

class _NavTile extends StatefulWidget {
  final ConsoleNavItem item;
  final bool selected;
  final VoidCallback onTap;

  const _NavTile({required this.item, required this.selected, required this.onTap});

  @override
  State<_NavTile> createState() => _NavTileState();
}

class _NavTileState extends State<_NavTile> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final t = ConsoleTokens.of(context);
    final selected = widget.selected;
    final badge = widget.item.badge ?? 0;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: FocusableActionDetector(
        onShowFocusHighlight: (v) => setState(() => _focused = v),
        onShowHoverHighlight: (v) => setState(() => _hovered = v),
        mouseCursor: SystemMouseCursors.click,
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap();
              return null;
            },
          ),
        },
        child: Semantics(
          button: true,
          selected: selected,
          label: badge > 0
              ? '${widget.item.label}, $badge waiting'
              : widget.item.label,
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: Motion.state,
              curve: Motion.enter,
              constraints: const BoxConstraints(minHeight: 44),
              padding: const EdgeInsets.symmetric(
                horizontal: Insets.md,
                vertical: Insets.md,
              ),
              decoration: BoxDecoration(
                color: selected
                    ? t.sidebarActive
                    : (_hovered ? Colors.white.withValues(alpha: 0.07) : Colors.transparent),
                borderRadius: Radii.control,
                border: _focused
                    ? Border.all(color: Colors.white.withValues(alpha: 0.85), width: 2)
                    : Border.all(color: Colors.transparent, width: 2),
              ),
              child: Row(
                children: [
                  Icon(
                    selected ? widget.item.activeIcon : widget.item.icon,
                    size: 19,
                    color: selected ? t.sidebarText : t.sidebarTextMuted,
                  ),
                  const SizedBox(width: Insets.md),
                  Expanded(
                    child: Text(
                      widget.item.label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: FontSizes.body,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                        color: selected ? t.sidebarText : t.sidebarTextMuted,
                      ),
                    ),
                  ),
                  if (badge > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: selected ? 0.24 : 0.16),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        badge > 99 ? '99+' : '$badge',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: t.sidebarText,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Standard page padding and max width for console content, so every section
/// lines up and nothing stretches to an unreadable measure on a wide monitor.
class ConsolePage extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  const ConsolePage({super.key, required this.child, this.maxWidth = 1180});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(Insets.xxl, Insets.xxl, Insets.xxl, Insets.huge),
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: child,
        ),
      ),
    );
  }
}
