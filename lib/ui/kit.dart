import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:simple_icons/simple_icons.dart';

import 'energy.dart';
import 'i18n.dart';
import 'errors.dart';
import 'theme.dart';

/// Shared building blocks for the GripHub AI Agent look.

/// The app mark: the GripHub Router logo, with no tile behind it.
class LogoMark extends StatelessWidget {
  const LogoMark({super.key, this.size = 40, this.glow = true});
  final double size;
  final bool glow;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: Image.asset('assets/brand/logo.png', filterQuality: FilterQuality.medium),
  );
}

/// Primary call to action: solid, high-contrast, full width.
class PrimaryButton extends StatelessWidget {
  const PrimaryButton({super.key, required this.label, required this.onPressed, this.icon, this.busy = false});
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final enabled = onPressed != null && !busy;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: p.text,
        borderRadius: BorderRadius.circular(Radii.lg),
        child: InkWell(
          borderRadius: BorderRadius.circular(Radii.lg),
          onTap: enabled ? onPressed : null,
          // 54 dp tall, and taller when a long label with large text needs a second line (it ran off the side).
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 54),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (busy)
                    BusySpinner(color: p.inverse)
                  else if (icon != null)
                    Icon(icon, size: 18, color: p.inverse),
                  if (busy || icon != null) const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: p.inverse, fontWeight: FontWeight.w600, fontSize: 15),
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

/// A soft grey surface; tappable when [onTap] is set.
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(18),
    this.onTap,
    this.highlight = false,
  });
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: p.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.xl),
        side: highlight ? BorderSide(color: p.text, width: 1.5) : BorderSide.none,
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: padding,
          child: OnSurface(child: child),
        ),
      ),
    );
  }
}

/// Text fields are filled with the surface colour, so inside a surface card
/// they vanish into it. Under this widget they are filled with the page colour
/// instead and read as inset wells.
class OnSurface extends StatelessWidget {
  const OnSurface({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(inputDecorationTheme: theme.inputDecorationTheme.copyWith(fillColor: context.palette.bg)),
      child: child,
    );
  }
}

/// The app's one segmented control: the options sit in a soft track and the
/// chosen one in a solid pill. Every segment keeps its rounded shape (a
/// SegmentedButton squares off the inner corners of the middle ones).
class PillSegments<T> extends StatelessWidget {
  const PillSegments({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.icons = const {},
    this.expand = true,
  });
  final T value;
  final Map<T, String> options;
  final Map<T, IconData> icons;
  final ValueChanged<T> onChanged;

  /// Full width with equal segments; false hugs the labels (a "7 / 30 days" switch).
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = Theme.of(context).textTheme.labelMedium;
    final selected = options.containsKey(value) ? value : options.keys.first;

    // [touch]: in a row, the track's 4 dp above and below belong to each segment's touch box (48 dp, for a 40 dp pill).
    Widget segment(T key, String label, {bool touch = false}) {
      final on = key == selected;
      final fg = on ? p.inverse : p.muted;
      final icon = icons[key];
      void pick() {
        HapticFeedback.selectionClick();
        onChanged(key);
      }

      final pill = AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: on ? p.text : Colors.transparent,
          borderRadius: BorderRadius.circular(Radii.pill),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            customBorder: const StadiumBorder(),
            onTap: on ? null : pick,
            child: ConstrainedBox(
              // A one-character label ("2") would make a 36 dp segment.
              constraints: const BoxConstraints(minHeight: 40, minWidth: 48),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (icon != null) ...[Icon(icon, size: 16, color: fg), const SizedBox(width: 6)],
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style?.copyWith(color: fg),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    return Semantics(
        button: true,
        selected: on,
        inMutuallyExclusiveGroup: true,
        child: touch
            ? GestureDetector(
                behavior: HitTestBehavior.opaque,
                excludeFromSemantics: true,
                onTap: on ? null : pick,
                child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: pill),
              )
            : pill,
      );
    }

    // Natural width of one segment: label, icon and padding, at the user's text size.
    final scaler = MediaQuery.textScalerOf(context);
    double natural(T key, String label) {
      final painter = TextPainter(
        text: TextSpan(text: label, style: style),
        textScaler: scaler,
        maxLines: 1,
        textDirection: Directionality.of(context),
      )..layout();
      final w = painter.width + 28 + (icons[key] != null ? 22 : 0);
      painter.dispose();
      return w < 48 ? 48 : w;
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final widths = [for (final e in options.entries) natural(e.key, e.value)];
        final needed =
            8 + (expand ? widths.fold<double>(0, (m, w) => w > m ? w : m) * widths.length : widths.fold<double>(0, (a, w) => a + w));
        // Labels that don't fit side by side (a narrow phone, large text, a long
        // translation) stack instead of clipping or overflowing.
        if (constraints.hasBoundedWidth && needed > constraints.maxWidth) {
          return Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(Radii.lg)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final e in options.entries) segment(e.key, e.value)],
            ),
          );
        }
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(Radii.pill)),
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            children: [
              for (final e in options.entries)
                if (expand)
                  Expanded(child: segment(e.key, e.value, touch: true))
                else
                  segment(e.key, e.value, touch: true),
            ],
          ),
        );
      },
    );
  }
}

/// A rounded square holding an icon, tinted by [color] (or the accent).
class IconTile extends StatelessWidget {
  const IconTile({super.key, required this.icon, this.color, this.size = 36, this.solid = false});
  final IconData icon;
  final Color? color;
  final double size;

  /// Solid tiles use a white glyph on the colour (brand marks); soft ones tint.
  final bool solid;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final c = color ?? p.accent;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: solid ? c : c.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(size * 0.3),
        border: solid ? null : Border.all(color: c.withValues(alpha: 0.22)),
      ),
      alignment: Alignment.center,
      child: Icon(icon, size: size * 0.5, color: solid ? Colors.white : c),
    );
  }
}

/// Small uppercase label above a group.
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.label, {super.key, this.trailing, this.padding = const EdgeInsets.fromLTRB(4, 24, 4, 10)});
  final String label;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Row(
      children: [
        Expanded(child: Text(label.toUpperCase(), style: Theme.of(context).textTheme.labelSmall)),
        if (trailing != null) SectionAction(child: trailing!),
      ],
    ),
  );
}

/// A text button next to a section label ("Stage all", "Add server"): small and in the accent,
/// like the "See all" link, so it reads as an action on the section instead of a second heading.
class SectionAction extends StatelessWidget {
  const SectionAction({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => TextButtonTheme(
    data: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: context.palette.accent,
        textStyle: Theme.of(context).textTheme.labelMedium,
        // Small to look at, 48 dp to touch.
        padding: const EdgeInsets.symmetric(horizontal: 10),
        iconSize: 16,
      ),
    ),
    child: child,
  );
}

/// Inset grouped rows, separated by hairlines.
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(Radii.xl)),
      clipBehavior: Clip.antiAlias,
      child: OnSurface(
        child: Column(
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Divider(height: 1, indent: 66, endIndent: 16, color: p.border),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}

class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.title,
    this.icon,
    this.leading,
    this.color,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.destructive = false,
  });
  final String title;
  final IconData? icon;
  final Widget? leading;
  final Color? color;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        child: Row(
          children: [
            leading ?? (icon != null ? IconTile(icon: icon!, color: color, size: 36) : const SizedBox.shrink()),
            if (leading != null || icon != null) const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: text.titleSmall?.copyWith(color: destructive ? p.danger : null)),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(subtitle!, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[
              trailing!,
              // A status pill doesn't say the row opens something; keep the chevron beside it.
              if (onTap != null && trailing is Pill) ...[
                const SizedBox(width: 6),
                Icon(LucideIcons.chevronRight, size: 18, color: p.faint),
              ],
            ] else if (onTap != null)
              Icon(LucideIcons.chevronRight, size: 18, color: p.faint),
          ],
        ),
      ),
    );
  }
}

/// A compact status pill.
class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, this.color, this.icon, this.dot = false});
  final String label;
  final Color? color;
  final IconData? icon;
  final bool dot;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final c = color ?? p.muted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(Radii.pill),
        border: Border.all(color: c.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dot) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: c, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
          ] else if (icon != null) ...[
            Icon(icon, size: 12, color: c),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: c),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Brand marks and tool icons

class Brand {
  const Brand(this.icon, this.color);
  final IconData icon;
  final Color color;
}

/// The provider's own mark when Simple Icons has it; a neutral glyph otherwise.
Brand providerBrand(BuildContext context, String id) {
  final p = context.palette;
  final dark = Theme.of(context).brightness == Brightness.dark;
  // Near-black brand colours vanish on the dark theme; lift them to the text colour.
  Color c(Color brand) => dark && brand.computeLuminance() < 0.05 ? p.text : brand;
  final key = id.toLowerCase();
  if (key.contains('anthropic')) return Brand(SimpleIcons.anthropic, c(SimpleIconColors.anthropic));
  if (key.contains('claude')) return Brand(SimpleIcons.claude, c(SimpleIconColors.claude));
  if (key.contains('google') || key.contains('gemini') || key.contains('vertex')) {
    return Brand(SimpleIcons.googlegemini, c(SimpleIconColors.googlegemini));
  }
  if (key.contains('xiaomi') || key.contains('mimo')) return Brand(SimpleIcons.xiaomi, c(SimpleIconColors.xiaomi));
  if (key.contains('deepseek')) return Brand(SimpleIcons.deepseek, c(SimpleIconColors.deepseek));
  if (key.contains('openrouter')) return Brand(SimpleIcons.openrouter, c(SimpleIconColors.openrouter));
  if (key.contains('mistral')) return Brand(SimpleIcons.mistralai, c(SimpleIconColors.mistralai));
  if (key.contains('ollama')) return Brand(SimpleIcons.ollama, c(SimpleIconColors.ollama));
  if (key.contains('hugging')) return Brand(SimpleIcons.huggingface, c(SimpleIconColors.huggingface));
  if (key.contains('nvidia')) return Brand(SimpleIcons.nvidia, c(SimpleIconColors.nvidia));
  if (key.contains('perplexity')) return Brand(SimpleIcons.perplexity, c(SimpleIconColors.perplexity));
  if (key.contains('cloudflare')) return Brand(SimpleIcons.cloudflare, c(SimpleIconColors.cloudflare));
  if (key.contains('meta') || key.contains('llama')) return Brand(SimpleIcons.meta, c(SimpleIconColors.meta));
  if (key == 'xai' || key.contains('grok')) return Brand(SimpleIcons.x, c(SimpleIconColors.x));
  if (key.contains('github')) return Brand(SimpleIcons.github, c(SimpleIconColors.github));
  if (key.contains('vercel')) return Brand(SimpleIcons.vercel, c(SimpleIconColors.vercel));
  if (key.contains('openai') || key.contains('azure') || key.contains('codex')) {
    return Brand(LucideIcons.sparkle, p.text);
  }
  if (key.contains('bedrock') || key.contains('amazon')) return Brand(LucideIcons.cloud, const Color(0xFFFF9900));
  if (key.contains('llama.cpp') || key.contains('local')) return Brand(LucideIcons.cpu, p.muted);
  return Brand(LucideIcons.bot, p.muted);
}

/// Brand mark rendered in a soft tile.
class BrandTile extends StatelessWidget {
  const BrandTile({super.key, required this.id, this.size = 36});
  final String id;
  final double size;

  @override
  Widget build(BuildContext context) {
    final b = providerBrand(context, id);
    return IconTile(icon: b.icon, color: b.color, size: size);
  }
}

IconData toolIcon(String? name) => switch (name) {
  'bash' => LucideIcons.squareTerminal,
  'read' => LucideIcons.fileText,
  'write' => LucideIcons.filePlus2,
  'edit' => LucideIcons.filePen,
  'grep' => LucideIcons.textSearch,
  'find' || 'ls' => LucideIcons.folderSearch,
  'web_search' => LucideIcons.search,
  'web_fetch' => LucideIcons.globe,
  'web_screenshot' => LucideIcons.camera,
  'todo_write' => LucideIcons.listTodo,
  'background_job' => LucideIcons.hourglass,
  _ => LucideIcons.wrench,
};

/// A token count for people: 872k, 1M, 1.5M, or the number itself when small.
String formatTokens(int n) {
  if (n >= 1000000) {
    final m = n / 1000000;
    final s = m >= 10 ? m.round().toString() : m.toStringAsFixed(1);
    return '${s.endsWith('.0') ? s.substring(0, s.length - 2) : s}M';
  }
  if (n >= 1000) return '${(n / 1000).round()}k';
  return '$n';
}

// ---------------------------------------------------------------------------
// Work in progress

/// A spinner for a button or a row that is waiting on the host, or ([BusySpinner.page]) for a screen or panel with
/// nothing to show yet. [color] on a filled button, or where the colour means something; otherwise the theme's comets.
class BusySpinner extends StatelessWidget {
  const BusySpinner({super.key, this.size = 16, this.color, this.semanticsLabel});

  /// The big one, alone in the middle of a screen or panel.
  const BusySpinner.page({super.key}) : size = 44, color = null, semanticsLabel = null;

  final double size;
  final Color? color;

  /// See [EnergySpinner.semanticsLabel]: empty where the control around it already says it is busy.
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) => EnergySpinner(size: size, color: color, semanticsLabel: semanticsLabel);
}

/// A 2 px bar that runs while [busy]. It always takes its height, so the content under it never jumps when it shows.
class BusyBar extends StatelessWidget {
  const BusyBar({super.key, required this.busy});
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SizedBox(
      height: 2,
      child: busy
          ? LinearProgressIndicator(minHeight: 2, color: p.muted, backgroundColor: p.border)
          : const SizedBox.shrink(),
    );
  }
}

/// Gives a small control the 48 dp a finger needs without making it look bigger: the control keeps its size, centred,
/// and a tap on the margin around it counts as a tap on it. Wrap it in the control's [Semantics], so a screen reader's
/// box is the 48 dp too.
class TapTarget extends StatelessWidget {
  const TapTarget({super.key, required this.child, this.onTap, this.onLongPress, this.size = 48});
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double size;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    excludeFromSemantics: true,
    onTap: onTap,
    onLongPress: onLongPress,
    child: ConstrainedBox(
      constraints: BoxConstraints(minWidth: size, minHeight: size),
      child: Center(widthFactor: 1, heightFactor: 1, child: child),
    ),
  );
}

/// A [Switch] that says what it switches. Beside a row's title a bare one is its own stop for a screen reader and
/// reads "switch, on" with nothing else.
class LabeledSwitch extends StatelessWidget {
  const LabeledSwitch({super.key, required this.label, required this.value, required this.onChanged});
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => Semantics(
    label: label,
    child: Switch(value: value, onChanged: onChanged),
  );
}

/// Something that failed to load, in the user's words ([friendlyError]), with a way to try again: an error alone in
/// the middle of a screen leaves nothing to do but find the refresh icon.
class ErrorNotice extends StatelessWidget {
  const ErrorNotice({super.key, required this.error, this.onRetry, this.center = false});
  final Object? error;
  final VoidCallback? onRetry;

  /// Centred, alone on a screen or panel; otherwise aligned to the start, in a card or a list.
  final bool center;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: p.danger);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: center ? CrossAxisAlignment.center : CrossAxisAlignment.start,
      children: [
        Text(friendlyError(error), style: style, textAlign: center ? TextAlign.center : TextAlign.start),
        if (onRetry != null) ...[
          const SizedBox(height: 4),
          TextButton.icon(
            onPressed: onRetry,
            icon: const Icon(LucideIcons.rotateCcw, size: 16),
            label: Text(tr('Try again')),
          ),
        ],
      ],
    );
  }
}

/// One action at a time per key: a second tap while the first is still waiting on the host does nothing, instead of
/// running it twice (two sheets, the same message sent twice, two screens pushed). [busy] says what is running, for the
/// spinner, and the state rebuilds when it starts and ends.
mixin BusyActions<T extends StatefulWidget> on State<T> {
  final Set<Object> _running = {};

  /// Whether the action [key] is running, or any action when [key] is null.
  bool busy([Object? key]) => key == null ? _running.isNotEmpty : _running.contains(key);

  /// Runs [action] under [key] unless it is already running (then returns null at once). Errors are rethrown.
  Future<R?> runBusy<R>(Object key, Future<R> Function() action) async {
    if (_running.contains(key)) return null;
    setState(() => _running.add(key));
    try {
      return await action();
    } finally {
      if (mounted) {
        setState(() => _running.remove(key));
      } else {
        _running.remove(key);
      }
    }
  }
}

/// Runs [task] behind a small dialog that says what it waits for and cannot be dismissed, for work that has no button
/// of its own to show a spinner on. A failure turns the spinner into a cross for a moment, then says why in a snackbar
/// (the result is null then). With [confirm] success shows a check the same way: for work whose result nothing else on
/// screen shows; where the next screen opening says it worked, the dialog just goes.
Future<T?> runWithProgress<T>(
  BuildContext context,
  String label,
  Future<T> Function() task, {
  bool confirm = false,
}) async {
  final nav = Navigator.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);
  final hold = Motion.of(context, EnergySpinner.outcomeDuration);
  final outcome = ValueNotifier<EnergyOutcome?>(null);
  // This dialog and no other is taken down when the work ends, whatever opened on top of it meanwhile.
  final route = DialogRoute<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            ValueListenableBuilder(
              valueListenable: outcome,
              // The label next to it says the same.
              builder: (_, o, _) => EnergySpinner(size: 36, outcome: o, semanticsLabel: ''),
            ),
            const SizedBox(width: 14),
            // "Restoring…" next to a check would still read as running.
            Expanded(
              child: ValueListenableBuilder(
                valueListenable: outcome,
                builder: (_, o, _) => Text(switch (o) {
                  EnergyOutcome.success => tr('Done'),
                  EnergyOutcome.failure => tr('Failed'),
                  null => label,
                }),
              ),
            ),
          ],
        ),
      ),
    ),
  );

  // Only while the dialog is the one on screen: under something else nobody would see it.
  Future<void> show(EnergyOutcome o) async {
    if (!route.isCurrent) return;
    outcome.value = o;
    if (hold > Duration.zero) await Future<void>.delayed(hold);
  }

  unawaited(nav.push(route));
  try {
    final result = await task();
    if (confirm) await show(EnergyOutcome.success);
    return result;
  } catch (e) {
    await show(EnergyOutcome.failure);
    messenger?.showSnackBar(SnackBar(content: Text(friendlyError(e))));
    return null;
  } finally {
    if (route.isActive) nav.removeRoute(route);
  }
}

/// A bottom sheet that is never cut off: as tall as its content, up to the whole screen, and it scrolls past that. A plain
/// sheet stops at 9/16 of the screen's height, which in landscape left a menu's last rows (Delete) out of reach.
Future<T?> showAppSheet<T>({required BuildContext context, required WidgetBuilder builder}) => showModalBottomSheet<T>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (context) => SingleChildScrollView(child: builder(context)),
);
