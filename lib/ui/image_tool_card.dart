import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_fs.dart';
import '../agent/models.dart';
import '../agent/pricing.dart';
import 'attachment_viewer.dart';
import 'i18n.dart';
import 'live_clock.dart';
import 'sheet.dart';
import 'theme.dart';

/// The colour pictures are drawn in across the app (the Settings row, the card, the shimmer).
const imageViolet = Color(0xFF7C3AED);

/// Pictures larger than this are not decoded on the card (a broken or hostile file could take all the memory).
const _maxPictureBytes = 16 * 1024 * 1024;

/// Width pictures are decoded at on the card: tiles are at most a phone's width, and a 1536-pixel PNG decoded in full
/// is 9 MB of memory each. The full-screen viewer decodes the file itself.
const _tileDecodeWidth = 768;

/// generate_image in the chat: what is being made, with which model and for how much, and a tile per picture that
/// shimmers until its picture lands, then reveals it. Each tile has the picture's final shape from the start, so
/// nothing around it moves when a picture arrives. A tap opens a picture full screen; a long press saves or shares it.
class ImageToolCard extends StatelessWidget {
  const ImageToolCard({
    super.key,
    required this.job,
    required this.status,
    this.output = '',
    this.fs = const LocalFs(),
    this.onSave,
    this.onShare,
  });

  final ImageJob job;

  /// The tool's own status: an error before any picture was tried (a limit, declined) has no slots running.
  final ToolStatus? status;

  /// The tool's text result, shown when it failed as a whole.
  final String output;
  final AgentFs fs;

  /// Save a picture to the phone (Download/GripHub); absent where that cannot be done (a server's file).
  final Future<void> Function(String path)? onSave;
  final Future<void> Function(String path)? onShare;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    final running = job.running && status != ToolStatus.failed;
    final n = job.slots.length;
    final title = running
        ? (n == 1
              ? tr('Making a picture')
              : tr('Making {n} pictures · {d} done').replaceAll('{n}', '$n').replaceAll('{d}', '${job.done}'))
        : job.done == 0
        ? tr('No picture was made')
        : job.done == n
        ? (n == 1 ? tr('Picture made') : tr('{n} pictures made').replaceAll('{n}', '$n'))
        : tr('{d} of {n} pictures made').replaceAll('{d}', '${job.done}').replaceAll('{n}', '$n');
    final credits = job.credits;
    final cost = running
        ? (job.rate == null ? null : '≈${_credits(job.rate! * n)}')
        : (credits == null || job.done == 0 ? null : _credits(credits));
    final meta = [job.model, if (job.cheapest) tr('cheapest'), ?cost].join(' · ');
    final took = job.startedAt != null && job.finishedAt != null ? job.finishedAt!.difference(job.startedAt!) : null;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: LiveClock(
                  label: title,
                  startedAt: job.startedAt,
                  took: took,
                  showTime: running || took != null,
                  state: running
                      ? ClockState.running
                      : job.done > 0
                      ? ClockState.done
                      : job.slots.every((s) => s.status == ImageSlotStatus.stopped)
                      ? ClockState.stopped
                      : ClockState.failed,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Padding(
            padding: const EdgeInsets.only(left: 20),
            child: Text(
              meta,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: t.labelSmall?.copyWith(color: p.faint),
            ),
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, c) {
              // Two to a row (one alone keeps a readable size); a lone wide picture takes the width.
              final cols = n == 1 ? 1 : 2;
              final gap = 8.0;
              final w = n == 1 ? (job.aspect >= 1 ? c.maxWidth : c.maxWidth * 0.66) : (c.maxWidth - gap) / cols;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final (i, s) in job.slots.indexed)
                    SizedBox(
                      width: w,
                      child: AspectRatio(
                        aspectRatio: job.aspect,
                        child: ImageTile(
                          key: ValueKey('${job.startedAt?.millisecondsSinceEpoch}-$i'),
                          slot: s,
                          fs: fs,
                          label: n > 1 ? '${tr('Picture')} ${i + 1}' : tr('Picture'),
                          prompt: job.prompt,
                          onSave: onSave,
                          onShare: onShare,
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
          if (job.asked > n) ...[
            const SizedBox(height: 8),
            Text(
              tr('{n} of {a} made: the limit is {n} per request (Settings → Pictures).')
                  .replaceAll('{n}', '$n')
                  .replaceAll('{a}', '${job.asked}'),
              style: t.bodySmall?.copyWith(color: p.muted),
            ),
          ],
          for (final s in job.slots.where((s) => s.status == ImageSlotStatus.failed).take(2)) ...[
            const SizedBox(height: 8),
            _FailureLine(slot: s),
          ],
          if (job.prompt.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              job.prompt,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: t.bodySmall?.copyWith(color: p.muted),
            ),
          ],
        ],
      ),
    );
  }
}

String _credits(double v) => '${localNumber(formatCredits(v))} ${tr('credits')}';

/// Why one picture failed, and whether it was billed: said every time, since the answer decides whether to try again.
class _FailureLine extends StatelessWidget {
  const _FailureLine({required this.slot});
  final ImageSlot slot;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final t = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(LucideIcons.imageOff, size: 14, color: p.danger),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '${slot.error ?? tr('Failed')} · ${slot.maybeBilled ? tr('may still have been billed: check Usage before trying again') : tr('not billed')}',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: t.bodySmall?.copyWith(color: p.muted),
          ),
        ),
      ],
    );
  }
}

/// One picture's tile: a shimmer while it is being made, then the picture coming in (blur to sharp, a slight zoom
/// out, fading in over the shimmer). The picture is decoded before the reveal starts, so it never flashes empty.
/// A picture that was already there when the tile was first built (a chat opened again) shows at once.
class ImageTile extends StatefulWidget {
  const ImageTile({
    super.key,
    required this.slot,
    required this.label,
    this.prompt = '',
    this.fs = const LocalFs(),
    this.onSave,
    this.onShare,
  });
  final ImageSlot slot;
  final String label;
  final String prompt;
  final AgentFs fs;
  final Future<void> Function(String path)? onSave;
  final Future<void> Function(String path)? onShare;

  /// How long the reveal takes.
  static const reveal = Duration(milliseconds: 600);

  /// One sweep of the shimmer.
  static const sweep = Duration(milliseconds: 1600);

  @override
  State<ImageTile> createState() => _ImageTileState();
}

class _ImageTileState extends State<ImageTile> with TickerProviderStateMixin {
  late final AnimationController _shimmer = AnimationController(vsync: this, duration: ImageTile.sweep);
  late final AnimationController _reveal = AnimationController(vsync: this, duration: ImageTile.reveal);
  Uint8List? _bytes;
  ImageProvider? _image;
  String? _loaded;
  bool _loadFailed = false;

  /// True when the picture was there before this tile first showed: no reveal then. Set in initState: a lazy `late`
  /// field would be read first once the picture is done, and always say so.
  late final bool _wasDone;

  @override
  void initState() {
    super.initState();
    _wasDone = widget.slot.status == ImageSlotStatus.done;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncShimmer();
    _load();
  }

  @override
  void didUpdateWidget(ImageTile old) {
    super.didUpdateWidget(old);
    _syncShimmer();
    if (old.slot.file != widget.slot.file || old.slot.status != widget.slot.status) _load();
  }

  void _syncShimmer() {
    final waiting = widget.slot.status == ImageSlotStatus.running;
    if (waiting && !Motion.reduced(context)) {
      if (!_shimmer.isAnimating) _shimmer.repeat();
    } else {
      _shimmer.stop();
    }
  }

  Future<void> _load() async {
    final file = widget.slot.file;
    if (widget.slot.status != ImageSlotStatus.done || file == null || file == _loaded) return;
    _loaded = file;
    try {
      final st = await widget.fs.stat(file);
      if (st.size > _maxPictureBytes) throw StateError('too large');
      final bytes = await widget.fs.read(file);
      if (!mounted || _loaded != file) return;
      // Decoded before it is shown (the same provider the tile then draws), so the reveal starts with the picture
      // there: no empty frame.
      final image = ResizeImage.resizeIfNeeded(_tileDecodeWidth, null, MemoryImage(bytes));
      var broken = false;
      await precacheImage(image, context, onError: (_, _) => broken = true);
      if (!mounted || _loaded != file) return;
      if (broken) throw StateError('not a picture');
      setState(() {
        _bytes = bytes;
        _image = image;
      });
      // Shown at once when it was already there, when animations are off, or when the tile is not on screen.
      if (_wasDone || Motion.reduced(context) || !_visible()) {
        _reveal.value = 1;
      } else {
        HapticFeedback.lightImpact();
        unawaited(_reveal.forward(from: 0));
      }
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    }
  }

  /// Whether the tile is in the screen's viewport now (a picture landing off screen is not animated).
  bool _visible() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return false;
    final top = box.localToGlobal(Offset.zero).dy;
    final h = MediaQuery.sizeOf(context).height;
    return top + box.size.height > 0 && top < h;
  }

  @override
  void dispose() {
    _shimmer.dispose();
    _reveal.dispose();
    super.dispose();
  }

  Future<void> _menu() async {
    final file = widget.slot.file;
    if (file == null || _bytes == null) return;
    HapticFeedback.selectionClick();
    final p = context.palette;
    final pick = await showSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.onSave != null)
              ListTile(
                leading: Icon(LucideIcons.download, color: p.text),
                title: Text(tr('Save to phone')),
                onTap: () => Navigator.pop(context, 'save'),
              ),
            if (widget.onShare != null)
              ListTile(
                leading: Icon(LucideIcons.share2, color: p.text),
                title: Text(tr('Share')),
                onTap: () => Navigator.pop(context, 'share'),
              ),
            ListTile(
              leading: Icon(LucideIcons.copy, color: p.text),
              title: Text(tr('Copy path')),
              onTap: () => Navigator.pop(context, 'path'),
            ),
            if (widget.prompt.isNotEmpty)
              ListTile(
                leading: Icon(LucideIcons.textQuote, color: p.text),
                title: Text(tr('Copy prompt')),
                onTap: () => Navigator.pop(context, 'prompt'),
              ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    switch (pick) {
      case 'save':
        await widget.onSave?.call(file);
      case 'share':
        await widget.onShare?.call(file);
      case 'path':
        await Clipboard.setData(ClipboardData(text: file));
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Path copied'))));
      case 'prompt':
        await Clipboard.setData(ClipboardData(text: widget.prompt));
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Prompt copied'))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final s = widget.slot;
    final bytes = _bytes;
    final failed =
        s.status == ImageSlotStatus.failed ||
        s.status == ImageSlotStatus.stopped ||
        (s.status == ImageSlotStatus.done && _loadFailed);
    final Widget body = failed
        ? _Blank(
            icon: s.status == ImageSlotStatus.stopped ? LucideIcons.circleStop : LucideIcons.imageOff,
            color: s.status == ImageSlotStatus.stopped ? p.muted : p.danger,
            label: s.status == ImageSlotStatus.stopped
                ? tr('Stopped')
                : s.status == ImageSlotStatus.done
                ? tr('Picture not found')
                : tr('Failed'),
          )
        : AnimatedBuilder(
            animation: Listenable.merge([_shimmer, _reveal]),
            builder: (context, _) => ShimmerReveal(
              shimmer: _shimmer.value,
              reveal: _image == null ? 0 : _reveal.value,
              picture: _image == null
                  ? null
                  : Image(
                      image: _image!,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) =>
                          _Blank(icon: LucideIcons.imageOff, color: p.danger, label: tr('Failed')),
                    ),
            ),
          );
    final done = bytes != null && !failed;
    return Semantics(
      image: done,
      button: done,
      label: done
          ? '${widget.label}: ${widget.prompt}'
          : s.status == ImageSlotStatus.running
          ? '${widget.label}, ${tr('being made')}'
          : '${widget.label}, ${tr('Failed')}',
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.md),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: done ? () => openImageBytesViewer(context, bytes, title: widget.label) : null,
            onLongPress: done ? _menu : null,
            child: body,
          ),
        ),
      ),
    );
  }
}

class _Blank extends StatelessWidget {
  const _Blank({required this.icon, required this.color, required this.label});
  final IconData icon;
  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return ColoredBox(
      color: p.raised,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 6),
            Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: p.muted)),
          ],
        ),
      ),
    );
  }
}

/// One frame of a tile, as a pure function of two numbers, so the look can be tested frame by frame.
///
/// [shimmer] 0..1: where the light band is in its sweep. [reveal] 0..1: how far the picture has come in (eased):
/// blur 24 → 0, scale 1.06 → 1, opacity 0 → 1, with the shimmer fading out under it.
class ShimmerReveal extends StatelessWidget {
  const ShimmerReveal({super.key, required this.shimmer, this.reveal = 0, this.picture});
  final double shimmer;
  final double reveal;
  final Widget? picture;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final r = Curves.easeOutCubic.transform(reveal.clamp(0.0, 1.0));
    final base = Color.alphaBlend(imageViolet.withValues(alpha: 0.08), p.raised);
    final band = Color.alphaBlend(imageViolet.withValues(alpha: 0.22), p.surface);
    // The band runs diagonally from off one corner to off the other.
    final x = -1.6 + shimmer * 3.2;
    final blur = 24 * (1 - r);
    return Stack(
      fit: StackFit.expand,
      children: [
        if (r < 1)
          Opacity(
            opacity: 1 - r,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment(x - 0.6, -1),
                  end: Alignment(x + 0.6, 1),
                  colors: [base, band, base],
                  stops: const [0.25, 0.5, 0.75],
                ),
              ),
              child: Center(child: Icon(LucideIcons.sparkles, size: 22, color: imageViolet.withValues(alpha: 0.55))),
            ),
          ),
        if (picture != null && r > 0)
          Opacity(
            opacity: r,
            child: Transform.scale(
              scale: 1.06 - 0.06 * r,
              child: blur < 0.5
                  ? picture
                  : ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                      child: picture,
                    ),
            ),
          ),
      ],
    );
  }
}
