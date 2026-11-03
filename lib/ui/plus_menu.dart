import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'i18n.dart';
import 'kit.dart';
import 'theme.dart';

/// What the "+" of the bottom bar opens: two choices over the page, Chat (a plain conversation, one tap) and Coding
/// (a chat in a project folder, which asks for the folder). It is drawn in the page's stack, above the tabs and under
/// the bar, so the bar and the button (now a cross) stay lit while the page behind it dims.
///
/// The choices come out one after the other, the one nearest the button first, with a little overshoot; the scrim
/// fades in with them. With animations off they are simply there. [open] is the parent's, which also owns Back.
class PlusMenuLayer extends StatefulWidget {
  const PlusMenuLayer({
    super.key,
    required this.open,
    required this.onClose,
    required this.onChat,
    required this.onCoding,
  });
  final bool open;
  final VoidCallback onClose;
  final VoidCallback onChat;
  final VoidCallback onCoding;

  @override
  State<PlusMenuLayer> createState() => _PlusMenuLayerState();
}

class _PlusMenuLayerState extends State<PlusMenuLayer> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this);

  @override
  void initState() {
    super.initState();
    if (widget.open) _c.value = 1;
  }

  @override
  void didUpdateWidget(PlusMenuLayer old) {
    super.didUpdateWidget(old);
    if (old.open == widget.open) return;
    // Coming out takes its time; going away is quicker, so a second tap is not kept waiting.
    if (widget.open) {
      _c.animateTo(1, duration: Motion.of(context, const Duration(milliseconds: 360)));
    } else {
      _c.animateBack(0, duration: Motion.of(context, const Duration(milliseconds: 180)), curve: Curves.easeIn);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  /// [t] from [from] to [to] as 0..1, with the overshoot of the first stage.
  static double _step(double t, double from, double to) =>
      Curves.easeOutBack.transform(((t - from) / (to - from)).clamp(0.0, 1.0));

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final dark = Theme.of(context).brightness == Brightness.dark;
    // The body of a Scaffold with extendBody is told the bar's height as its bottom padding: the choices sit above it.
    final bottom = MediaQuery.paddingOf(context).bottom + 28;
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) {
        if (_c.isDismissed) return const SizedBox.shrink();
        final t = _c.value;
        final scrim = Curves.easeOut.transform(t.clamp(0.0, 1.0));
        return Stack(
          fit: StackFit.expand,
          children: [
            // Over the page only; the bar is above this layer. A tap on it closes the menu.
            Semantics(
              button: true,
              label: tr('Close'),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: widget.onClose,
                child: ColoredBox(color: Colors.black.withValues(alpha: (dark ? 0.55 : 0.38) * scrim)),
              ),
            ),
            Positioned(
              left: 24,
              right: 24,
              bottom: bottom,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Coding is the farther one, so it comes last.
                  _Choice(
                    icon: LucideIcons.code,
                    title: tr('Coding'),
                    subtitle: tr('Build in a project folder'),
                    color: p.accentAlt,
                    k: _step(t, 0.22, 0.85),
                    onTap: widget.onCoding,
                  ),
                  const SizedBox(height: 12),
                  _Choice(
                    icon: LucideIcons.messageCircle,
                    title: tr('Chat'),
                    subtitle: tr('Ask, look up news, write'),
                    color: p.accent,
                    k: _step(t, 0.05, 0.68),
                    onTap: widget.onChat,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

/// One choice: a pill with its icon, name and a line on what it is. [k] is how far out it has come (0..1, a little
/// over on the way).
class _Choice extends StatelessWidget {
  const _Choice({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.color,
    required this.k,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final Color color;
  final double k;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final shape = StadiumBorder(side: BorderSide(color: p.border));
    return Opacity(
      opacity: k.clamp(0.0, 1.0),
      child: Transform.translate(
        offset: Offset(0, (1 - k) * 28),
        child: Transform.scale(
          scale: 0.86 + 0.14 * k,
          child: Semantics(
            button: true,
            child: DecoratedBox(
              decoration: ShapeDecoration(
                shape: shape,
                shadows: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: dark ? 0.4 : 0.12),
                    blurRadius: 24,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              child: Material(
                color: p.surface,
                shape: shape,
                clipBehavior: Clip.antiAlias,
                child: InkWell(
                  onTap: () {
                    HapticFeedback.selectionClick();
                    onTap();
                  },
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 64),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(12, 10, 20, 10),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconTile(icon: icon, color: color, size: 40),
                          const SizedBox(width: 12),
                          Flexible(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(title, style: text.titleSmall),
                                Text(subtitle, style: text.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
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
