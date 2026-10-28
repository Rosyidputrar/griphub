import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../agent/agent_fs.dart';
import '../agent/models.dart';
import '../agent/pricing.dart';
import '../agent/sent_attachments.dart';
import '../agent/updater.dart';
import 'attachment_viewer.dart';
import 'code_view.dart';
import 'preview_screen.dart';
import 'kit.dart';
import 'i18n.dart';
import 'theme.dart';
import 'todo_views.dart';

class UserMessageView extends StatelessWidget {
  const UserMessageView(this.entry, {super.key, this.onLongPress, this.fs = const LocalFs()});
  final UserEntry entry;

  /// Where the attachment copies are (the agent's machine).
  final AgentFs fs;

  /// The message menu, supplied by the chat; gets the bubble's own context so the menu can sit next to it.
  final void Function(BuildContext bubbleContext)? onLongPress;

  @override
  Widget build(BuildContext context) {
    // Attachments recorded for this message (empty for messages sent before
    // this feature, which keep rendering exactly as before: text only).
    final attachments = entry.attachments;
    final text = attachments.isEmpty ? entry.text : stripAttachedNote(entry.text);
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.82),
        child: Builder(
          builder: (bubbleContext) => GestureDetector(
            onLongPress: onLongPress == null ? null : () => onLongPress!(bubbleContext),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (attachments.isNotEmpty) ...[
                  MessageAttachments(attachments: attachments, fs: fs),
                  const SizedBox(height: 8),
                ],
                if (text.isNotEmpty) UserBubble(text),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Thumbnails and file chips for a sent message's attachments, shown above
/// its bubble. Photos open full-screen; files open the attachment viewer.
class MessageAttachments extends StatelessWidget {
  const MessageAttachments({super.key, required this.attachments, this.fs = const LocalFs()});
  final List<SentAttachment> attachments;
  final AgentFs fs;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final photos = attachments.where(sentIsImage).toList();
    final files = attachments.where((a) => !sentIsImage(a)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (photos.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [
              for (final a in photos)
                GestureDetector(
                  onTap: () => openAttachmentViewer(context, a, fs: fs),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(Radii.md),
                    child: AgentImage(
                      fs: fs,
                      path: a.path,
                      maxBytes: AttachmentViewerScreen.maxImageBytes,
                      width: 160,
                      height: 160,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        width: 160,
                        height: 160,
                        color: p.raised,
                        child: Icon(LucideIcons.imageOff, size: 24, color: p.muted),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        if (files.isNotEmpty) ...[
          if (photos.isNotEmpty) const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: [for (final a in files) _AttachmentFileChip(attachment: a, fs: fs)],
          ),
        ],
      ],
    );
  }
}

class _AttachmentFileChip extends StatelessWidget {
  const _AttachmentFileChip({required this.attachment, required this.fs});
  final SentAttachment attachment;
  final AgentFs fs;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final a = attachment;
    return GestureDetector(
      onTap: () => openAttachmentViewer(context, a, fs: fs),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 240),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: p.raised,
          borderRadius: BorderRadius.circular(Radii.md),
          border: Border.all(color: p.accent.withValues(alpha: 0.18)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.fileText, size: 16, color: p.muted),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                a.name == pastedName ? tr('Pasted content') : a.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            if (a.size >= 0) ...[
              const SizedBox(width: 6),
              Text(
                formatBytes(a.size),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: p.muted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The user's message bubble; also drawn on its own above the blur when its menu is open.
class UserBubble extends StatelessWidget {
  const UserBubble(this.text, {super.key});
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: p.raised,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(Radii.lg),
          topRight: Radius.circular(Radii.lg),
          bottomLeft: Radius.circular(Radii.lg),
          bottomRight: Radius.circular(Radii.sm),
        ),
        border: Border.all(color: p.accent.withValues(alpha: 0.18)),
      ),
      // Plain text so the long-press menu wins over text selection ("Select text" in the menu covers that).
      child: Text(text, style: Theme.of(context).textTheme.bodyLarge),
    );
  }
}

class AssistantMessageView extends StatelessWidget {
  const AssistantMessageView(
    this.entry, {
    super.key,
    required this.tools,
    this.cwd,
    this.fs = const LocalFs(),
    this.live,
    this.modelLabel,
    this.subagentCard,
    this.subagentCost,
    this.footer,
  });
  final AssistantEntry entry;
  final Map<String, ToolRun> tools;

  /// Where relative tool paths resolve, for previews.
  final String? cwd;

  /// The agent's files (on the phone or a server), for previews of what a tool wrote.
  final AgentFs fs;

  /// Fires as the agent streams; live previews re-render on it.
  final Listenable? live;

  /// Display name for the model id saved with the reply.
  final String Function(String id)? modelLabel;

  /// The live subagent card for a `subagent` tool call, or null when the app
  /// knows no subagent for it (a chat from before a restart): then the call
  /// shows as a plain tool card with the report as its output.
  final Widget? Function(String toolCallId)? subagentCard;

  /// What the subagent a `subagent` tool call started has cost: found, with its credits (null when unknown);
  /// null when the app knows no subagent for the call. Counted apart from the turn's own cost.
  final ({double? credits})? Function(String toolCallId)? subagentCost;

  /// The turn's copy-and-model footer, when this is the turn's last message
  /// and the turn is over (see [turnFooters]); null draws none.
  final TurnFooter? footer;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final blocks = entry.orderedBlocks;
    final children = <Widget>[];
    for (final b in blocks) {
      switch (b.kind) {
        case BlockKind.text:
          if (b.text.trim().isNotEmpty) {
            children.add(TypewriterMarkdown(text: b.text, live: entry.streaming && identical(b, blocks.last)));
          }
        case BlockKind.thinking:
          if (b.text.trim().isNotEmpty) {
            children.add(ThinkingView(text: b.text, live: entry.streaming && identical(b, blocks.last)));
          }
        case BlockKind.toolCall:
          // The subagent's own call is not a tool card: its live card sits here instead.
          final card = b.toolName == 'subagent' && b.toolCallId != null ? subagentCard?.call(b.toolCallId!) : null;
          children.add(
            card ??
                (b.toolName == 'todo_write'
                    ? TodoCard(block: b, run: tools[b.toolCallId])
                    : ToolCallView(block: b, run: tools[b.toolCallId], cwd: cwd, fs: fs, live: live)),
          );
      }
    }
    if (entry.streaming && children.isEmpty) children.add(const _Pending());
    if (entry.error != null) children.add(_ErrorNote(entry.error!));
    if (entry.aborted) {
      children.add(Text(tr('Stopped'), style: Theme.of(context).textTheme.labelMedium?.copyWith(color: p.faint)));
    }
    if (footer case final f?) {
      final model = f.model;
      final subagents = [for (final id in f.cost?.subagentCalls ?? const <String>[]) ?subagentCost?.call(id)];
      children.add(
        _MessageFooter(
          text: f.text,
          model: model == null ? null : (modelLabel?.call(model) ?? model),
          cost: f.cost,
          subagents: subagents.isEmpty
              ? null
              : (count: subagents.length, credits: subagents.any((c) => c.credits == null) ? null : subagents.fold<double>(0, (a, c) => a + c.credits!)),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[if (i > 0) const SizedBox(height: 10), children[i]],
      ],
    );
  }
}

/// Bubbles up when a message grows on its own, so the transcript can keep
/// following the bottom between agent updates.
class TranscriptGrew extends Notification {
  const TranscriptGrew();
}

/// Reveals streamed text at a steady pace so bursty providers still read as
/// typing. The pace scales with the backlog, so it never falls far behind.
class TypewriterMarkdown extends StatefulWidget {
  const TypewriterMarkdown({super.key, required this.text, required this.live});
  final String text;
  final bool live;

  @override
  State<TypewriterMarkdown> createState() => _TypewriterMarkdownState();
}

class _TypewriterMarkdownState extends State<TypewriterMarkdown> with SingleTickerProviderStateMixin {
  late final _ticker = createTicker(_tick);
  late int _shown = widget.live ? 0 : widget.text.length;
  Duration _last = Duration.zero;
  double _carry = 0;

  bool get _behind => _shown < widget.text.length;

  @override
  void initState() {
    super.initState();
    if (_behind) _ticker.start();
  }

  @override
  void didUpdateWidget(TypewriterMarkdown old) {
    super.didUpdateWidget(old);
    if (_shown > widget.text.length) _shown = widget.text.length;
    if (_behind && !_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _tick(Duration elapsed) {
    final dt = (elapsed - _last).inMicroseconds / 1e6;
    _last = elapsed;
    final backlog = widget.text.length - _shown;
    if (backlog <= 0) {
      _ticker.stop();
      return;
    }
    // ~160 chars/s baseline, draining any backlog within about a quarter second;
    // faster once the stream has ended.
    final rate = (widget.live ? 160.0 : 500.0) + backlog * (widget.live ? 4.0 : 8.0);
    _carry += rate * dt;
    final step = _carry.floor();
    if (step == 0) return;
    _carry -= step;
    setState(() => _shown = (_shown + step).clamp(0, widget.text.length));
    const TranscriptGrew().dispatch(context);
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final typing = widget.live || _behind;
    // U+258D left block as the caret; markdown renders it inline with the text.
    final visible = widget.text.substring(0, _shown);
    return MarkdownText(typing ? '$visible▍' : widget.text);
  }
}

/// The subagents a turn started: how many, and what they cost together (null when any is unknown).
typedef SubagentsCost = ({int count, double? credits});

String _creditsText(double c) => '~${localNumber(formatCredits(c))} ${tr('credits')}';

class _MessageFooter extends StatelessWidget {
  const _MessageFooter({required this.text, this.model, this.cost, this.subagents});
  final String text;
  final String? model;
  final TurnCost? cost;
  final SubagentsCost? subagents;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final style = TextStyle(fontSize: 11.5, color: p.faint);
    final c = cost;
    // Tokens and credits are never cut off.
    final usage = c == null
        ? null
        : [
            tr('{n} tokens').replaceAll('{n}', localNumber(formatTokens(c.tokens))),
            if (c.credits case final credits?) _creditsText(credits),
            if (subagents?.credits case final sub?) '(+${localNumber(formatCredits(sub))} ${tr('subagent')})',
          ].join(' · ');
    // Side by side when they fit; on a narrow screen or with large text, the cost wraps under the model.
    final details = Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (model != null)
          Text(
            // The separator ends the model's line, so a wrapped cost starts clean.
            usage == null ? model! : '${model!} · ',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            // The model's name, as in the composer chip, not a code-styled id.
            style: style,
          ),
        if (usage != null) Text(usage, style: style),
      ],
    );
    return Row(
      children: [
        Transform.translate(
          offset: const Offset(-8, 0),
          child: CopyButton(text: text, showLabel: false),
        ),
        if (model != null || c != null)
          Expanded(
            child: c == null
                ? details
                : GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      builder: (_) => TurnCostSheet(cost: c, model: model, subagents: subagents),
                    ),
                    child: details,
                  ),
          ),
      ],
    );
  }
}

/// What one turn cost, line by line, as the subagent panel shows it: requests (and how many were raised to the
/// model's minimum), tokens billed (cache included), the estimate, and the subagents it started, apart.
class TurnCostSheet extends StatelessWidget {
  const TurnCostSheet({super.key, required this.cost, this.model, this.subagents});
  final TurnCost cost;
  final String? model;
  final SubagentsCost? subagents;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final c = cost;
    Widget row(IconData icon, String label, String value, {Color? color}) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(icon, size: 15, color: p.faint),
          const SizedBox(width: 8),
          Expanded(child: Text(label, style: text.bodySmall)),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.end,
              style: text.bodyMedium?.copyWith(color: color, fontFeatures: const [FontFeature.tabularFigures()]),
            ),
          ),
        ],
      ),
    );
    String money(double? v) => v == null ? '—' : '${_creditsText(v)} · Rp ${(v * kRupiahPerCredit).round()}';
    final sub = subagents;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr('This turn'), style: text.titleLarge),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(Radii.md)),
              child: Column(
                children: [
                  if (model case final m?) row(LucideIcons.cpu, tr('Model'), m),
                  row(
                    LucideIcons.activity,
                    tr('Requests'),
                    c.floored > 0
                        ? tr('{n} ({m} at the minimum)').replaceAll('{n}', '${c.requests}').replaceAll('{m}', '${c.floored}')
                        : '${c.requests}',
                  ),
                  row(
                    LucideIcons.layers,
                    tr('Tokens billed'),
                    c.cached > 0 && c.tokens > 0
                        ? tr('{n} ({m}% cache)')
                              .replaceAll('{n}', localNumber(formatTokens(c.tokens)))
                              .replaceAll('{m}', '${(c.cached / c.tokens * 100).round()}')
                        : localNumber(formatTokens(c.tokens)),
                  ),
                  row(LucideIcons.coins, tr('Cost'), money(c.credits), color: c.credits == null ? p.faint : null),
                  if (sub != null)
                    row(
                      LucideIcons.bot,
                      sub.count == 1 ? tr('Subagent') : tr('{n} subagents').replaceAll('{n}', '${sub.count}'),
                      money(sub.credits),
                      color: sub.credits == null ? p.faint : null,
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Text(
              tr(
                c.credits == null
                    ? 'No GripHub price is known for this model, so only its tokens are shown.'
                    : 'Estimated per request at GripHub\'s live rate, including cache and each model\'s minimum; the exact charge is in Usage.',
              ),
              style: text.bodySmall?.copyWith(color: p.faint),
            ),
          ],
        ),
      ),
    );
  }
}

/// A table column as wide as its content, but no wider than [max] (cells
/// wrap past it) and no narrower than its longest word.
///
/// It must be an [IntrinsicColumnWidth]: flutter_markdown_plus only wraps a
/// table in its horizontal scroller for that type (or a fixed width).
class CappedColumnWidth extends IntrinsicColumnWidth {
  const CappedColumnWidth({this.max = 280});
  final double max;

  @override
  double minIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) {
    var result = 0.0;
    for (final cell in cells) {
      result = math.max(result, cell.getMinIntrinsicWidth(double.infinity));
    }
    return result;
  }

  @override
  double maxIntrinsicWidth(Iterable<RenderBox> cells, double containerWidth) {
    var widest = 0.0;
    for (final cell in cells) {
      widest = math.max(widest, cell.getMaxIntrinsicWidth(double.infinity));
    }
    return math.max(math.min(widest, max), minIntrinsicWidth(cells, containerWidth));
  }

  @override
  double? flex(Iterable<RenderBox> cells) => null;
}

class MarkdownText extends StatelessWidget {
  const MarkdownText(this.data, {super.key});
  final String data;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = context.palette;
    final body = theme.textTheme.bodyLarge!;
    final code = TextStyle(fontFamily: mono, fontSize: 13, height: 1.5, color: p.text);
    // One selection area for the whole message instead of a SelectableText
    // per paragraph and table cell: each of those claimed horizontal drags for
    // its own selection, so a wide table could not be swiped sideways. Text is
    // still selectable (long-press, across paragraphs too).
    return SelectionArea(child: _markdown(context, body: body, code: code, theme: theme, p: p));
  }

  Widget _markdown(
    BuildContext context, {
    required TextStyle body,
    required TextStyle code,
    required ThemeData theme,
    required Palette p,
  }) {
    return MarkdownBody(
      data: data,
      selectable: false,
      extensionSet: md.ExtensionSet.gitHubFlavored,
      builders: {'pre': _CodeBlockBuilder(context)},
      onTapLink: (text, href, title) {
        if (href != null) Clipboard.setData(ClipboardData(text: href));
      },
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: body,
        a: body.copyWith(decoration: TextDecoration.underline, decorationColor: p.faint),
        h1: theme.textTheme.headlineSmall,
        h2: theme.textTheme.titleLarge,
        h3: theme.textTheme.titleMedium,
        h4: theme.textTheme.titleSmall,
        strong: body.copyWith(fontWeight: FontWeight.w600),
        listBullet: body.copyWith(color: p.muted),
        code: code.copyWith(backgroundColor: p.raised, fontSize: 13.5),
        blockquote: body.copyWith(color: p.muted),
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(color: p.border, width: 3)),
        ),
        blockquotePadding: const EdgeInsets.only(left: 12),
        tableHead: body.copyWith(fontWeight: FontWeight.w600),
        tableBody: body,
        tableBorder: TableBorder.all(color: p.border),
        tableCellsPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        // Columns size to their content, capped so prose wraps at a readable
        // width; a table wider than the screen scrolls sideways (the package
        // only adds the horizontal scroller for intrinsic/fixed widths). The
        // default FlexColumnWidth squeezed every column into the screen, one
        // word per line.
        tableColumnWidth: const CappedColumnWidth(),
        tableScrollbarThumbVisibility: true,
        horizontalRuleDecoration: BoxDecoration(
          border: Border(top: BorderSide(color: p.border)),
        ),
        blockSpacing: 10,
        listIndent: 20,
      ),
    );
  }
}

/// Fenced code: bordered, horizontally scrollable, with language and copy.
class _CodeBlockBuilder extends MarkdownElementBuilder {
  _CodeBlockBuilder(this.context);
  final BuildContext context;

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final codeEl = element.children?.whereType<md.Element>().firstOrNull;
    final text = (codeEl?.textContent ?? element.textContent).replaceFirst(RegExp(r'\n$'), '');
    final lang = (codeEl?.attributes['class'] ?? '').replaceFirst('language-', '');
    final previewable = const {'html', 'htm', 'svg'}.contains(lang.toLowerCase());
    // Markdown rebuilds this subtree while streaming; the navigator outlives it.
    final navigator = Navigator.of(context);
    return CodeBox(
      text: text,
      label: lang.isEmpty ? null : lang,
      language: lang,
      onPreview: previewable
          ? () => HtmlPreviewScreen.open(navigator.context, title: tr('Preview'), source: () => text)
          : null,
    );
  }
}

class ThinkingView extends StatefulWidget {
  const ThinkingView({super.key, required this.text, required this.live});
  final String text;
  final bool live;

  @override
  State<ThinkingView> createState() => _ThinkingViewState();
}

class _ThinkingViewState extends State<ThinkingView> {
  bool open = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final label = Theme.of(context).textTheme.labelMedium;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => open = !open),
          borderRadius: BorderRadius.circular(Radii.sm),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(tr(widget.live ? 'Thinking' : 'Thought process'), style: label),
                const SizedBox(width: 4),
                AnimatedRotation(
                  turns: open ? 0.25 : 0,
                  duration: Motion.of(context, Motion.fast),
                  child: Icon(LucideIcons.chevronRight, size: 16, color: p.muted),
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: Motion.of(context, Motion.normal),
          curve: Motion.curve,
          alignment: Alignment.topLeft,
          child: open
              ? Container(
                  margin: const EdgeInsets.only(top: 6),
                  padding: const EdgeInsets.only(left: 12),
                  decoration: BoxDecoration(
                    border: Border(left: BorderSide(color: p.border, width: 2)),
                  ),
                  child: SelectableText(
                    widget.text.trim(),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: p.muted),
                  ),
                )
              : widget.live
              // While the model thinks, show the newest lines as they stream.
              ? Container(
                  margin: const EdgeInsets.only(top: 6),
                  padding: const EdgeInsets.only(left: 12),
                  constraints: const BoxConstraints(maxHeight: 96),
                  decoration: BoxDecoration(
                    border: Border(left: BorderSide(color: p.border, width: 2)),
                  ),
                  child: SingleChildScrollView(
                    reverse: true,
                    physics: const NeverScrollableScrollPhysics(),
                    child: Text(
                      widget.text.trim(),
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(color: p.faint),
                    ),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// What the agent is writing right now: only the newest lines, with the real line numbers and the size so far.
/// The whole file arrives a few characters at a time and the chat redraws ~30 times a second; highlighting and
/// laying out all of it on every frame made the app crawl on long files. The full text shows once it lands.
class _LiveTail extends StatelessWidget {
  const _LiveTail({required this.text, required this.name, required this.language});
  final String text;
  final String? name;
  final String? language;

  /// Lines on screen while writing; about what fits in the panel.
  static const lines = 14;

  @override
  Widget build(BuildContext context) {
    // Start of the last [lines] lines, scanning back from the end only.
    var start = text.length;
    for (var n = 0; n < lines && start > 0; n++) {
      start = text.lastIndexOf('\n', start - 1);
      if (start < 0) break;
    }
    final cut = start > 0;
    final from = cut ? start + 1 : 0;
    final total = '\n'.allMatches(text).length + 1;
    final shown = '\n'.allMatches(text, from).length + 1;
    final kb = text.length / 1024;
    final size = kb < 1 ? '${text.length} B' : '${localNumber(kb.toStringAsFixed(1))} KB';
    final count = total == 1 ? tr('1 line') : tr('{n} lines').replaceAll('{n}', localNumber('$total'));
    return CodeBox(
      text: text.substring(from),
      firstLine: total - shown + 1,
      copyText: text,
      label: [?name, count, size].join(' · '),
      language: language,
      followTail: true,
    );
  }
}

class ToolCallView extends StatefulWidget {
  const ToolCallView({
    super.key,
    required this.block,
    required this.run,
    this.cwd,
    this.fs = const LocalFs(),
    this.live,
  });
  final Block block;
  final ToolRun? run;
  final String? cwd;
  final AgentFs fs;
  final Listenable? live;

  @override
  State<ToolCallView> createState() => _ToolCallViewState();
}

class _ToolCallViewState extends State<ToolCallView> {
  bool open = false;

  /// Set once this card has streamed live content; it then stays visible
  /// after the call lands instead of folding away (which made the transcript
  /// jump). Cards restored from history start folded.
  bool sawLive = false;

  String? _absolute(String? path) {
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('/') || (widget.cwd ?? '').isEmpty) return path;
    return '${widget.cwd}/$path';
  }

  /// The page as it stands: the file on disk once written, else the content
  /// streamed so far.
  String _htmlSource() {
    final args = widget.block.liveArgs;
    final file = _absolute(args?['path'] as String?);
    if (widget.fs.isLocal && widget.block.args != null && file != null) {
      try {
        final f = File(file);
        if (f.existsSync()) return f.readAsStringSync();
      } catch (_) {}
    }
    return args?['content'] as String? ?? '';
  }

  Future<void> _preview(String path, {required bool writing}) async {
    final file = _absolute(path);
    final fs = widget.fs;
    var source = _htmlSource;
    // On a server the written file is read once, over the link; while it streams the preview shows what came so far.
    if (!fs.isLocal && !writing && file != null && widget.block.args != null) {
      final streamed = widget.block.liveArgs?['content'] as String? ?? '';
      final html = await fs.readString(file).catchError((Object _) => streamed);
      if (!mounted) return;
      source = () => html;
    }
    await HtmlPreviewScreen.open(
      context,
      title: path.split('/').last,
      source: source,
      baseDir: file == null || !fs.isLocal ? null : File(file).parent.path,
      // Re-render as it streams; a finished file is static.
      live: writing ? widget.live : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = widget.block;
    final run = widget.run;
    final status = run?.status;
    final args = b.liveArgs;
    final cwd = widget.cwd ?? '';
    // Paths inside the workspace read better relative to it.
    final summary = cwd.isEmpty ? toolSummary(b.toolName, args) : toolSummary(b.toolName, args).replaceAll('$cwd/', '');

    // Arguments still streaming in: show what the model is writing, live.
    final writing = b.args == null && run == null;
    if (writing) sawLive = true;
    final path = args?['path'] as String?;
    final ext = path != null && path.contains('.') ? path.split('.').last.toLowerCase() : null;
    final previewable =
        path != null && (b.toolName == 'write' || b.toolName == 'edit') && const {'html', 'htm', 'svg'}.contains(ext);
    final liveText = switch (b.toolName) {
      'write' => args?['content'],
      'edit' => args?['newText'],
      'bash' => args?['command'],
      _ => null,
    } as String?;

    final Widget indicator = switch (status) {
      ToolStatus.done => Icon(LucideIcons.check, size: 15, color: p.success),
      ToolStatus.failed => Icon(LucideIcons.x, size: 15, color: p.danger),
      _ => SizedBox.square(dimension: 12, child: CircularProgressIndicator(strokeWidth: 1.6, color: p.muted)),
    };

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(Radii.md),
            onTap: () => setState(() => open = !open),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
              child: Row(
                children: [
                  SizedBox.square(dimension: 16, child: Center(child: indicator)),
                  const SizedBox(width: 10),
                  Icon(toolIcon(b.toolName), size: 15, color: p.accent),
                  const SizedBox(width: 6),
                  Text(
                    b.toolName ?? 'tool',
                    style: TextStyle(fontFamily: mono, fontSize: 12.5, fontWeight: FontWeight.w600, color: p.text),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      writing && summary.isEmpty ? 'preparing…' : summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontFamily: mono, fontSize: 12.5, color: p.muted),
                    ),
                  ),
                  if (previewable)
                    TextButton.icon(
                      onPressed: () => _preview(path, writing: writing),
                      style: TextButton.styleFrom(
                        foregroundColor: p.text,
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        // From the theme: a bare TextStyle here drops the app font (Roboto on Android).
                        textStyle: Theme.of(context).textTheme.labelMedium?.copyWith(fontSize: 12),
                      ),
                      icon: const Icon(LucideIcons.play, size: 16),
                      label: Text(tr(writing ? 'Live' : 'Preview')),
                    ),
                  AnimatedRotation(
                    turns: open ? 0.5 : 0,
                    duration: Motion.of(context, Motion.fast),
                    curve: Motion.curve,
                    child: Icon(LucideIcons.chevronDown, size: 18, color: p.faint),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
          ),
          if ((writing || sawLive) && !open && liveText != null && liveText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: writing
                  ? _LiveTail(
                      text: liveText,
                      name: path?.split('/').last ?? b.toolName,
                      language: b.toolName == 'bash' ? 'bash' : ext,
                    )
                  : CodeBox(
                      text: liveText,
                      label: path?.split('/').last ?? b.toolName,
                      language: b.toolName == 'bash' ? 'bash' : ext,
                      maxHeight: 260,
                      followTail: true,
                    ),
            ),
          // Opens and closes instead of jumping; the header stays put.
          ClipRect(
            child: AnimatedSize(
              duration: Motion.of(context, Motion.normal),
              curve: Motion.curve,
              alignment: Alignment.topCenter,
              child: !open
                  ? const SizedBox(width: double.infinity)
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Divider(height: 1, color: p.border),
                        Padding(
                          padding: const EdgeInsets.all(10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (b.toolName == 'write' && liveText != null)
                                _Section(
                                  label: tr('Content'),
                                  child: writing
                                      ? _LiveTail(text: liveText, name: path?.split('/').last, language: ext)
                                      : CodeBox(
                                          text: liveText,
                                          label: path?.split('/').last,
                                          language: ext,
                                          maxHeight: 320,
                                        ),
                                )
                              else
                                _Section(
                                  label: tr('Input'),
                                  child: CodeBox(
                                    text: const JsonEncoder.withIndent('  ').convert(args ?? {}),
                                    label: 'json',
                                    maxHeight: 220,
                                  ),
                                ),
                              if (run != null && run.output.isNotEmpty) ...[
                                const SizedBox(height: 10),
                                _Section(
                                  label: tr(status == ToolStatus.failed ? 'Error' : 'Output'),
                                  child: CodeBox(
                                    text: run.output.trimRight(),
                                    label: 'output',
                                    lineNumbers: false,
                                    maxHeight: 320,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.label, required this.child});
  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 6),
          child: Text(label.toUpperCase(), style: Theme.of(context).textTheme.labelSmall),
        ),
        child,
      ],
    );
  }
}

class NoticeView extends StatelessWidget {
  const NoticeView(this.entry, {super.key});
  final NoticeEntry entry;

  @override
  Widget build(BuildContext context) {
    if (entry.error) return _ErrorNote(entry.text);
    return Text(entry.text, style: Theme.of(context).textTheme.bodySmall);
  }
}

class _ErrorNote extends StatelessWidget {
  const _ErrorNote(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: p.danger.withValues(alpha: 0.4)),
      ),
      child: SelectableText(text, style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: p.danger)),
    );
  }
}

class _Pending extends StatelessWidget {
  const _Pending();

  @override
  Widget build(BuildContext context) => const AgentActivity();
}

/// What the agent is doing when nothing else on screen moves: pulsing dots, and a shimmering
/// [label] ("Thinking…", "Running bash…") that cross-fades as the step changes.
class AgentActivity extends StatefulWidget {
  const AgentActivity({super.key, this.label});
  final String? label;

  @override
  State<AgentActivity> createState() => _AgentActivityState();
}

class _AgentActivityState extends State<AgentActivity> with SingleTickerProviderStateMixin {
  late final controller = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Still dots when animations are off; the label alone says what is happening.
    if (Motion.reduced(context)) {
      controller.stop();
      controller.value = 0.5;
    } else if (!controller.isAnimating) {
      controller.repeat();
    }
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  /// Triangle wave in [0.25, 1] over one animation cycle.
  static double _pulse(double t) => 0.25 + 0.75 * (1 - ((t % 1) * 2 - 1).abs());

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final label = widget.label;
    final style = Theme.of(context).textTheme.labelMedium?.copyWith(color: p.muted);
    return Align(
      alignment: Alignment.centerLeft,
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < 3; i++)
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(right: 5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: p.muted.withValues(alpha: _pulse(controller.value - i * 0.18)),
                ),
              ),
            if (label != null) ...[
              const SizedBox(width: 5),
              Flexible(
                child: AnimatedSwitcher(
                  duration: Motion.of(context, Motion.normal),
                  switchInCurve: Motion.curve,
                  layoutBuilder: (current, previous) =>
                      Stack(alignment: Alignment.centerLeft, children: [...previous, ?current]),
                  child: ShaderMask(
                    key: ValueKey(label),
                    blendMode: BlendMode.srcIn,
                    // A highlight sweeping across the text, in step with the dots.
                    shaderCallback: (rect) => LinearGradient(
                      colors: [p.muted, p.text, p.muted],
                      stops: const [0, 0.5, 1],
                      begin: Alignment(-2.5 + 4 * controller.value, 0),
                      end: Alignment(-0.5 + 4 * controller.value, 0),
                    ).createShader(rect),
                    child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
