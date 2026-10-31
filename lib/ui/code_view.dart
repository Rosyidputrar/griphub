import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/services.dart';
import 'package:highlight/highlight.dart' show highlight, Node;

import 'i18n.dart';
import 'theme.dart';

/// Token colors for highlight.js class names, tuned to sit on [Palette.surface].
/// The syntax colours for a theme (tested for contrast in test/contrast_test.dart).
Map<String, Color> syntaxColors(Brightness b) => b == Brightness.dark
    ? const {
        'keyword': Color(0xFFFF7B72),
        'built_in': Color(0xFFFFA657),
        'type': Color(0xFFFFA657),
        'literal': Color(0xFF79C0FF),
        'number': Color(0xFF79C0FF),
        'string': Color(0xFFA5D6FF),
        'regexp': Color(0xFFA5D6FF),
        'comment': Color(0xFF8B949E),
        'doctag': Color(0xFF8B949E),
        'meta': Color(0xFF8B949E),
        'title': Color(0xFFD2A8FF),
        'function': Color(0xFFD2A8FF),
        'class': Color(0xFFFFA657),
        'params': Color(0xFFE6EDF3),
        'attr': Color(0xFF79C0FF),
        'attribute': Color(0xFF79C0FF),
        'variable': Color(0xFFFFA657),
        'symbol': Color(0xFF79C0FF),
        'tag': Color(0xFF7EE787),
        'name': Color(0xFF7EE787),
        'selector-tag': Color(0xFF7EE787),
        'selector-class': Color(0xFFD2A8FF),
        'addition': Color(0xFF7EE787),
        'deletion': Color(0xFFFFA198),
        'section': Color(0xFF79C0FF),
        'bullet': Color(0xFFFFA657),
        'subst': Color(0xFFE6EDF3),
      }
    : const {
        'keyword': Color(0xFFCF222E),
        'built_in': Color(0xFF953800),
        'type': Color(0xFF953800),
        'literal': Color(0xFF0550AE),
        'number': Color(0xFF0550AE),
        'string': Color(0xFF0A3069),
        'regexp': Color(0xFF0A3069),
        // 4.5:1 on a card (0xFF6E7781 was 4.2).
        'comment': Color(0xFF59636E),
        'doctag': Color(0xFF59636E),
        'meta': Color(0xFF59636E),
        'title': Color(0xFF8250DF),
        'function': Color(0xFF8250DF),
        'class': Color(0xFF953800),
        'params': Color(0xFF1F2328),
        'attr': Color(0xFF0550AE),
        'attribute': Color(0xFF0550AE),
        'variable': Color(0xFF953800),
        'symbol': Color(0xFF0550AE),
        'tag': Color(0xFF116329),
        'name': Color(0xFF116329),
        'selector-tag': Color(0xFF116329),
        'selector-class': Color(0xFF8250DF),
        'addition': Color(0xFF116329),
        'deletion': Color(0xFF82071E),
        'section': Color(0xFF0550AE),
        'bullet': Color(0xFF953800),
        'subst': Color(0xFF1F2328),
      };

const _aliases = {
  'sh': 'bash',
  'shell': 'bash',
  'zsh': 'bash',
  'console': 'bash',
  'ts': 'typescript',
  'tsx': 'typescript',
  'js': 'javascript',
  'jsx': 'javascript',
  'mjs': 'javascript',
  'py': 'python',
  'kt': 'kotlin',
  'rs': 'rust',
  'yml': 'yaml',
  'html': 'xml',
  'md': 'markdown',
  'c++': 'cpp',
  'cs': 'csharp',
};

List<TextSpan> highlightSpans(String code, String? language, Brightness brightness) {
  final lang = language?.toLowerCase().trim();
  if (lang == null || lang.isEmpty || lang == 'text' || lang == 'plaintext') return [TextSpan(text: code)];
  try {
    final nodes = highlight.parse(code, language: _aliases[lang] ?? lang).nodes;
    if (nodes == null) return [TextSpan(text: code)];
    final colors = syntaxColors(brightness);
    return _spans(nodes, colors, null);
  } catch (_) {
    return [TextSpan(text: code)];
  }
}

List<TextSpan> _spans(List<Node> nodes, Map<String, Color> colors, Color? inherited) {
  final out = <TextSpan>[];
  for (final n in nodes) {
    final color = colors[n.className] ?? inherited;
    final italic = n.className == 'comment';
    final style = color == null ? null : TextStyle(color: color, fontStyle: italic ? FontStyle.italic : null);
    if (n.value != null) {
      out.add(TextSpan(text: n.value, style: style));
    } else if (n.children != null) {
      out.add(TextSpan(style: style, children: _spans(n.children!, colors, color)));
    }
  }
  return out;
}

/// A highlighted text, kept so a rebuild with the same text reuses the very same span: no new highlight pass,
/// and Flutter sees an identical span, so the text isn't laid out again. The chat rebuilds every frame while
/// the agent works, and every code panel on screen used to be re-highlighted each time.
class _Highlighted {
  _Highlighted(this.text, this.language, this.brightness, this.style, this.span);
  final String text;
  final String? language;
  final Brightness brightness;
  final TextStyle style;
  final TextSpan span;
}

final _highlighted = <_Highlighted>[];

TextSpan _highlight(String text, String? language, Brightness brightness, TextStyle style) {
  for (var i = 0; i < _highlighted.length; i++) {
    final h = _highlighted[i];
    if (h.language == language && h.brightness == brightness && h.style == style && h.text == text) {
      // Most recently used last.
      if (i != _highlighted.length - 1) _highlighted.add(_highlighted.removeAt(i));
      return h.span;
    }
  }
  final span = TextSpan(style: style, children: highlightSpans(text, language, brightness));
  _highlighted.add(_Highlighted(text, language, brightness, style, span));
  if (_highlighted.length > 32) _highlighted.removeAt(0);
  return span;
}

/// Bordered code panel: language label, copy button, line numbers, highlighting.
class CodeBox extends StatelessWidget {
  const CodeBox({
    super.key,
    required this.text,
    this.label,
    this.language,
    this.maxHeight,
    this.lineNumbers = true,
    this.followTail = false,
    this.onPreview,
    this.firstLine = 1,
    this.copyText,
  });
  final String text;
  final String? label;
  final String? language;
  final double? maxHeight;
  final bool lineNumbers;

  /// Keep the newest lines in view while the text is still being written.
  final bool followTail;
  final VoidCallback? onPreview;

  /// The line number of [text]'s first line, when it is the end of something longer.
  final int firstLine;

  /// What Copy copies, when [text] is only part of it; [text] otherwise.
  final String? copyText;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final brightness = Theme.of(context).brightness;
    final style = TextStyle(fontFamily: mono, fontSize: 12.5, height: 1.6, color: p.text);
    final lines = '\n'.allMatches(text).length + 1;
    final showNumbers = lineNumbers && (lines > 1 || firstLine > 1);

    Widget code = SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: EdgeInsets.fromLTRB(showNumbers ? 12 : 14, 12, 14, 14),
      child: SelectableText.rich(_highlight(text, language ?? label, brightness, style)),
    );
    Widget body = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showNumbers)
          Container(
            padding: const EdgeInsets.fromLTRB(12, 12, 10, 14),
            decoration: BoxDecoration(
              border: Border(right: BorderSide(color: p.border)),
            ),
            child: Text(
              List.generate(lines, (i) => '${firstLine + i}').join('\n'),
              textAlign: TextAlign.right,
              style: style.copyWith(color: p.faint),
            ),
          ),
        Expanded(child: code),
      ],
    );
    if (maxHeight != null) {
      body = ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight!),
        child: SingleChildScrollView(reverse: followTail, child: body),
      );
    }
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 36,
            decoration: BoxDecoration(
              color: p.raised.withValues(alpha: 0.5),
              border: Border(bottom: BorderSide(color: p.border)),
            ),
            child: Row(
              children: [
                const SizedBox(width: 12),
                Icon(LucideIcons.code, size: 14, color: p.faint),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    (label == null || label!.isEmpty) ? 'code' : label!,
                    style: TextStyle(fontFamily: mono, fontSize: 11.5, color: p.muted),
                  ),
                ),
                if (onPreview != null) _HeaderAction(icon: LucideIcons.play, label: tr('Preview'), onTap: onPreview!),
                CopyButton(text: copyText ?? text),
                const SizedBox(width: 4),
              ],
            ),
          ),
          body,
        ],
      ),
    );
  }
}

/// Copy action that confirms in place instead of with a snackbar.
class CopyButton extends StatefulWidget {
  const CopyButton({super.key, required this.text, this.showLabel = true});
  final String text;
  final bool showLabel;

  @override
  State<CopyButton> createState() => _CopyButtonState();
}

class _CopyButtonState extends State<CopyButton> {
  bool copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.text));
    HapticFeedback.selectionClick();
    if (!mounted) return;
    setState(() => copied = true);
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    if (mounted) setState(() => copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = copied ? p.success : p.muted;
    final said = tr(copied ? 'Copied' : 'Copy');
    // Said to a screen reader ("Copy", then "Copied" as it happens) and, when it is only an icon, in a tooltip; an icon
    // alone gets a 48 dp touch box (it was 30 x 26 under every reply).
    final button = InkWell(
      onTap: _copy,
      borderRadius: BorderRadius.circular(Radii.sm),
      child: ConstrainedBox(
        constraints: widget.showLabel ? const BoxConstraints() : const BoxConstraints(minWidth: 48, minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedSwitcher(
                duration: Motion.of(context, const Duration(milliseconds: 150)),
                child: Icon(copied ? LucideIcons.check : LucideIcons.copy, key: ValueKey(copied), size: 14, color: color),
              ),
              if (widget.showLabel) ...[
                const SizedBox(width: 5),
                Text(said, style: TextStyle(fontSize: 11.5, color: color)),
              ],
            ],
          ),
        ),
      ),
    );
    final labelled = Semantics(
      button: true,
      label: said,
      liveRegion: copied,
      onTap: _copy,
      excludeSemantics: true,
      child: button,
    );
    return widget.showLabel ? labelled : Tooltip(message: said, child: labelled);
  }
}

class _HeaderAction extends StatelessWidget {
  const _HeaderAction({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(Radii.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 15, color: p.text),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: p.text),
            ),
          ],
        ),
      ),
    );
  }
}
