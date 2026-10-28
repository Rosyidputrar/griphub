import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/agent_fs.dart';
import '../agent/features.dart';
import '../agent/sent_attachments.dart';
import '../agent/updater.dart' show formatBytes;
import 'i18n.dart';
import 'changes_screen.dart';
import 'code_view.dart';
import 'editor_screen.dart';
import 'files_screen.dart';
import 'git_screen.dart';
import 'kit.dart';
import 'preview_open.dart';
import 'search_screen.dart';
import 'tasks_screen.dart';
import 'theme.dart';
import 'usage_screen.dart';

// ---------------------------------------------------------------------------
// Attachments

/// A file or picture attached to the next message.
class Attachment {
  Attachment(this.path, this.name, {this.mime});
  final String path;
  final String name;
  final String? mime;

  static const _imageTypes = {
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'webp': 'image/webp',
    'gif': 'image/gif',
  };

  String get ext => name.contains('.') ? name.split('.').last.toLowerCase() : '';
  String? get imageMime => mime?.startsWith('image/') == true ? mime : _imageTypes[ext];
  bool get isImage => imageMime != null;

  /// Long text pasted into the composer, kept as a file (see [LongPasteFormatter]).
  bool get isPasted => name == pastedName;
}

/// Pasting more than this many characters, or at least this many lines, attaches the text as a file instead.
const longPasteChars = 1000;
const longPasteLines = 10;

/// Whether [text] is long enough to become an attachment when pasted: more
/// than [longPasteChars] characters, or [longPasteLines] lines or more (a
/// trailing line break does not count as a line).
bool isLongPaste(String text) =>
    text.length > longPasteChars || '\n'.allMatches(text.trimRight()).length + 1 >= longPasteLines;

/// Turns a long paste into an attachment: the field is left as it was and [onLongPaste] gets the text.
///
/// A paste is told apart from typing by size: one edit that inserts more than [longPasteChars] characters or
/// at least [longPasteLines] lines. Keyboards insert a word or a suggestion at a time, and text the app sets itself
/// (voice input, shared text, a restored draft) never goes through input formatters.
class LongPasteFormatter extends TextInputFormatter {
  LongPasteFormatter(this.onLongPaste);
  final void Function(String text) onLongPaste;

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final before = oldValue.text;
    final after = newValue.text;
    // What this edit inserted: newValue minus the prefix and suffix it shares with oldValue.
    var start = 0;
    final shortest = before.length < after.length ? before.length : after.length;
    while (start < shortest && before.codeUnitAt(start) == after.codeUnitAt(start)) {
      start++;
    }
    var end = 0;
    while (end < shortest - start &&
        before.codeUnitAt(before.length - 1 - end) == after.codeUnitAt(after.length - 1 - end)) {
      end++;
    }
    final inserted = after.substring(start, after.length - end);
    if (!isLongPaste(inserted)) return newValue;
    // After this edit is applied; the callback updates widgets.
    scheduleMicrotask(() => onLongPaste(inserted));
    return oldValue;
  }
}

/// Writes pasted text to a file and returns it as an attachment. Synchronous: it is a paste (kilobytes),
/// and the chip should be there the moment the field stays empty.
Attachment pastedAttachment(String text) {
  final dir = Directory('${Directory.systemTemp.path}/griphub-paste/${DateTime.now().microsecondsSinceEpoch}')
    ..createSync(recursive: true);
  final file = File('${dir.path}/$pastedName')..writeAsStringSync(text);
  return Attachment(file.path, pastedName, mime: 'text/plain');
}

/// Pictures go to the model as images; other files are copied into the
/// project's `.attachments/` folder and referenced by path in the message.
/// Every attachment is ALSO copied there (with a unique name, so two
/// same-named attachments never overwrite each other) and returned in
/// [files], so the sent message can show it later. Unreadable files are
/// skipped rather than failing the send.
///
/// The attachments live on the phone ([Attachment.path]); the project folder is on the agent's machine ([fs]), so on
/// a server they are uploaded ([onProgress], [cancel], and [onFile] naming the file being sent). A failed upload or a
/// cancel throws: nothing is sent then.
Future<({String text, List<Map<String, String>> images, List<SentAttachment> files})> preparePrompt(
  String text,
  List<Attachment> attachments,
  String cwd,
  AgentFs fs, {
  Progress? onProgress,
  CancelToken? cancel,
  void Function(String label)? onFile,
}) async {
  final images = <Map<String, String>>[];
  final paths = <String>[];
  final files = <SentAttachment>[];
  final dir = '$cwd/.attachments';
  final stamp = DateTime.now().microsecondsSinceEpoch;
  final present = [
    for (final a in attachments)
      if (File(a.path).existsSync()) a,
  ];
  if (present.isNotEmpty) await fs.mkdir(dir);
  for (var i = 0; i < attachments.length; i++) {
    final a = attachments[i];
    final file = File(a.path);
    if (!file.existsSync()) continue;
    final target = '$dir/${stamp}_${i}_${a.name}';
    cancel?.check();
    onFile?.call(present.length > 1 ? '${a.name} · ${present.indexOf(a) + 1} ${tr('of')} ${present.length}' : a.name);
    try {
      await fs.upload(a.path, target, onProgress: onProgress, cancel: cancel);
    } on FileSystemException {
      continue; // unreadable on the phone
    }
    final length = _fileSize(file);
    files.add((path: target, name: a.name, mime: a.imageMime ?? a.mime, size: length));
    if (a.isImage && length >= 0 && length < 8 * 1024 * 1024) {
      images.add({'type': 'image', 'data': base64Encode(await file.readAsBytes()), 'mimeType': a.imageMime!});
    } else {
      paths.add(target);
    }
  }
  final note = paths.isEmpty ? '' : '\n\nAttached files:\n${paths.map((p) => '- $p').join('\n')}';
  return (text: '$text$note'.trim(), images: images, files: files);
}

int _fileSize(File file) {
  try {
    return file.lengthSync();
  } catch (_) {
    return -1;
  }
}

Future<List<Attachment>> pickAttachments(BuildContext context) async {
  final choice = await showModalBottomSheet<String>(
    context: context,
    builder: (context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: SettingsGroup(
          children: [
            SettingsRow(
              icon: LucideIcons.images,
              color: context.palette.accentAlt,
              title: tr('Photos'),
              subtitle: tr('Screenshots, sketches, error photos'),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            SettingsRow(
              icon: LucideIcons.camera,
              color: const Color(0xFF30A46C),
              title: tr('Camera'),
              subtitle: tr('Take a picture now'),
              onTap: () => Navigator.pop(context, 'camera'),
            ),
            SettingsRow(
              icon: LucideIcons.paperclip,
              color: const Color(0xFFF76B15),
              title: tr('Files'),
              subtitle: tr('PDFs, code, data, anything'),
              onTap: () => Navigator.pop(context, 'files'),
            ),
          ],
        ),
      ),
    ),
  );
  final picker = ImagePicker();
  switch (choice) {
    case 'gallery':
      final images = await picker.pickMultiImage(imageQuality: 85, maxWidth: 2048);
      return [for (final x in images) Attachment(x.path, x.name, mime: x.mimeType)];
    case 'camera':
      final x = await picker.pickImage(source: ImageSource.camera, imageQuality: 85, maxWidth: 2048);
      return x == null ? [] : [Attachment(x.path, x.name, mime: x.mimeType)];
    case 'files':
      final files = await FilePicker.pickFiles();
      return [
        for (final f in files)
          if (f.path != null) Attachment(f.path!, f.name),
      ];
  }
  return const [];
}

/// Thumbnails / chips of what will be sent with the next message.
class AttachmentStrip extends StatelessWidget {
  const AttachmentStrip({super.key, required this.items, required this.onRemove, this.onOpen});
  final List<Attachment> items;
  final void Function(Attachment) onRemove;

  /// Tapping an attachment (a long paste opens its preview).
  final void Function(Attachment)? onOpen;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return SizedBox(
      height: 68,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
        itemCount: items.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final a = items[i];
          return Stack(
            clipBehavior: Clip.none,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(Radii.md),
                child: a.isPasted
                    ? GestureDetector(onTap: onOpen == null ? null : () => onOpen!(a), child: _PastedChip(attachment: a))
                    : a.isImage
                    ? Image.file(File(a.path), width: 56, height: 56, fit: BoxFit.cover)
                    : Container(
                        width: 120,
                        height: 56,
                        color: p.raised,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        alignment: Alignment.centerLeft,
                        child: Row(
                          children: [
                            Icon(LucideIcons.fileText, size: 16, color: p.muted),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                a.name,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 11, color: p.text),
                              ),
                            ),
                          ],
                        ),
                      ),
              ),
              Positioned(
                right: -6,
                top: -6,
                child: GestureDetector(
                  onTap: () => onRemove(a),
                  child: Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(color: p.text, shape: BoxShape.circle),
                    child: Icon(LucideIcons.x, size: 12, color: p.inverse),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// A long paste waiting to be sent: a TXT badge with its size, and "Pasted content".
class _PastedChip extends StatelessWidget {
  const _PastedChip({required this.attachment});
  final Attachment attachment;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    var size = -1;
    try {
      size = File(attachment.path).lengthSync();
    } catch (_) {}
    return Container(
      // Wide enough for "Konten yang ditempel" on one line.
      width: 156,
      height: 56,
      padding: const EdgeInsets.fromLTRB(10, 7, 10, 7),
      decoration: BoxDecoration(
        color: p.raised,
        borderRadius: BorderRadius.circular(Radii.md),
        border: Border.all(color: p.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(Radii.sm),
                  border: Border.all(color: p.border),
                ),
                child: Text(
                  'TXT',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: p.muted, letterSpacing: 0.4),
                ),
              ),
              if (size >= 0) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    formatBytes(size),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: p.faint),
                  ),
                ),
              ],
            ],
          ),
          Text(
            tr('Pasted content'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: p.text),
          ),
        ],
      ),
    );
  }
}

/// A long paste's preview, from its chip in the composer. Pops true for "Paste as text".
Future<bool?> showPastedSheet(BuildContext context, String text) => showModalBottomSheet<bool>(
  context: context,
  isScrollControlled: true,
  builder: (context) {
    final p = context.palette;
    final lines = '\n'.allMatches(text).length + 1;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr('Pasted content'), style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              '${lines == 1 ? tr('1 line') : tr('{n} lines').replaceAll('{n}', localNumber('$lines'))} · '
              '${formatBytes(utf8.encode(text).length)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: p.muted),
            ),
            const SizedBox(height: 12),
            CodeBox(
              // A preview: the start is enough to recognise it, and long text stays cheap to draw.
              text: text.length > 6000 ? '${text.substring(0, 6000)}\n…' : text,
              copyText: text,
              label: pastedName,
              language: 'text',
              maxHeight: MediaQuery.sizeOf(context).height * 0.4,
            ),
            const SizedBox(height: 14),
            Text(
              tr('Sent with your message as a file the agent reads, so a long log or document does not fill the chat.'),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: p.muted),
            ),
            const SizedBox(height: 14),
            OutlinedButton.icon(
              onPressed: () => Navigator.pop(context, true),
              icon: const Icon(LucideIcons.textCursorInput, size: 16),
              label: Text(tr('Paste as text')),
            ),
          ],
        ),
      ),
    );
  },
);

// ---------------------------------------------------------------------------
// Approvals

/// Asks once before turning every approval off, since pi can then delete files or push without asking.
/// The agent is mid-turn and the user picked another chat: stop it and
/// switch, or stay. Switching without stopping would drop the reply.
Future<bool> confirmStopToSwitch(BuildContext context) async {
  final p = context.palette;
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(tr('Stop the agent and switch?')),
      content: Text(
        tr('The agent is still working in this chat. Switching stops it; what it has done so far stays in the chat.'),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: p.danger, foregroundColor: Colors.white),
          onPressed: () => Navigator.pop(context, true),
          child: Text(tr('Stop and switch')),
        ),
      ],
    ),
  );
  return ok == true;
}

Future<bool> confirmBypass(BuildContext context) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('Bypass all permissions?')),
        content: Text(tr('The agent will run every command, edit any file and use every tool without asking.')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: Text(tr('Bypass'))),
        ],
      ),
    ) ??
    false;

/// The first approval in the queue. After an answer, the answered card stays
/// on screen (disabled) for a moment before the next one slides in: without
/// this, the second half of a double-tap lands on the NEXT card's Allow
/// button and approves an action the user never saw.
class ApprovalCards extends StatefulWidget {
  const ApprovalCards({super.key, required this.features});
  final Features features;

  @override
  State<ApprovalCards> createState() => _ApprovalCardsState();
}

class _ApprovalCardsState extends State<ApprovalCards> {
  Approval? _justAnswered;
  Timer? _timer;

  /// The card last announced with a buzz, so each approval buzzes once.
  String? _buzzed;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _onAnswered(Approval a) {
    _timer?.cancel();
    setState(() => _justAnswered = a);
    _timer = Timer(const Duration(milliseconds: 600), () {
      if (mounted) setState(() => _justAnswered = null);
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.features,
      builder: (context, _) {
        final approvals = widget.features.approvals;
        final a = _justAnswered ?? (approvals.isEmpty ? null : approvals.first);
        if (a != null && _justAnswered == null && a.id != _buzzed) {
          _buzzed = a.id;
          // The agent stopped to ask: worth a nudge, even if the user is looking elsewhere.
          WidgetsBinding.instance.addPostFrameCallback((_) => HapticFeedback.mediumImpact());
        }
        // Rises from the composer and folds back into it; the next card in the queue cross-fades
        // in once the answered one has had its moment on screen (see _onAnswered).
        return AnimatedSwitcher(
          duration: Motion.of(context, Motion.normal),
          switchInCurve: Motion.curve,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, animation) => SizeTransition(
            sizeFactor: animation,
            alignment: Alignment.bottomCenter,
            child: FadeTransition(
              opacity: animation,
              child: SlideTransition(
                position: Tween(begin: const Offset(0, 0.12), end: Offset.zero).animate(animation),
                // A card on its way out takes no taps, so only the card fading in can be answered.
                child: AnimatedBuilder(
                  animation: animation,
                  child: child,
                  builder: (context, child) => IgnorePointer(
                    ignoring: animation.status == AnimationStatus.reverse,
                    child: child,
                  ),
                ),
              ),
            ),
          ),
          child: a == null ? const SizedBox(key: ValueKey('none'), width: double.infinity) : _card(context, a, approvals),
        );
      },
    );
  }

  Widget _card(BuildContext context, Approval a, List<Approval> approvals) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Padding(
          key: ValueKey(a.id),
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(Radii.xl),
              border: Border.all(color: p.warning.withValues(alpha: 0.6), width: 1.2),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    IconTile(icon: toolIcon(a.toolName), color: p.warning, size: 32),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${tr('Allow')} ${a.toolName}?', style: text.titleSmall),
                          Text(tr(a.reason), style: text.bodySmall),
                        ],
                      ),
                    ),
                    if (approvals.length > 1) Pill('+${approvals.length - 1}', color: p.muted),
                  ],
                ),
                const SizedBox(height: 10),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 110),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: p.raised, borderRadius: BorderRadius.circular(Radii.md)),
                  child: SingleChildScrollView(
                    child: Text(
                      a.summary,
                      style: TextStyle(fontFamily: mono, fontSize: 12, color: p.text, height: 1.45),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                _ApprovalActions(
                  key: ValueKey(a.id),
                  features: widget.features,
                  approval: a,
                  onAnswered: () => _onAnswered(a),
                ),
                TextButton.icon(
                  onPressed: () async {
                    if (!await confirmBypass(context)) return;
                    await widget.features.client.call('settings_set', {
                      'settings': {'approvalMode': 'auto'},
                    });
                    for (final pending in [...widget.features.approvals]) {
                      await widget.features.answer(pending, allow: true);
                    }
                  },
                  style: TextButton.styleFrom(foregroundColor: p.muted),
                  icon: const Icon(LucideIcons.shieldOff, size: 16),
                  label: Text(tr('Bypass all permissions')),
                ),
              ],
            ),
          ),
        );
  }
}

/// Deny / Always / Allow for one approval card. The buttons disable on the
/// first tap, and the parent keeps the answered card on screen briefly, so
/// a double-tap cannot approve the next card in the queue unseen.
class _ApprovalActions extends StatefulWidget {
  const _ApprovalActions({super.key, required this.features, required this.approval, this.onAnswered});
  final Features features;
  final Approval approval;

  /// Called synchronously on the first tap, before the answer round-trip.
  final void Function()? onAnswered;

  @override
  State<_ApprovalActions> createState() => _ApprovalActionsState();
}

class _ApprovalActionsState extends State<_ApprovalActions> {
  bool _responded = false;

  Future<void> _answer({required bool allow, bool always = false}) async {
    if (_responded) return;
    setState(() => _responded = true);
    widget.onAnswered?.call();
    await widget.features.answer(widget.approval, allow: allow, always: always);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: _responded ? null : () => _answer(allow: false),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 42), foregroundColor: p.danger),
            child: Text(tr('Deny')),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: OutlinedButton(
            onPressed: _responded ? null : () => _answer(allow: true, always: true),
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 42)),
            child: Text(tr('Always')),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: FilledButton(
            onPressed: _responded ? null : () => _answer(allow: true),
            style: FilledButton.styleFrom(minimumSize: const Size(0, 42)),
            child: Text(tr('Allow')),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Plan mode

/// After the agent answers in plan mode: approve and run, or keep planning.
class PlanBar extends StatelessWidget {
  const PlanBar({super.key, required this.agent});
  final AgentController agent;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    if (!agent.planMode || agent.busy || agent.entries.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        decoration: BoxDecoration(color: p.accent.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(Radii.lg)),
        child: Row(
          children: [
            Icon(LucideIcons.listChecks, size: 18, color: p.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(tr('Plan mode'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
            ),
            TextButton(onPressed: () => agent.setPlanMode(false), child: Text(tr('Exit'))),
            FilledButton(
              onPressed: agent.approvePlan,
              style: FilledButton.styleFrom(minimumSize: const Size(0, 38)),
              child: Text(tr('Approve & run')),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Dev servers

/// A server the agent started: preview it, or share a public link.
class DevServerBanner extends StatefulWidget {
  const DevServerBanner({super.key, required this.agent});
  final AgentController agent;

  @override
  State<DevServerBanner> createState() => _DevServerBannerState();
}

class _DevServerBannerState extends State<DevServerBanner> {
  final opening = <int>{};

  /// Ports whose preview is being opened (on a server the port is forwarded to this phone first, which takes a moment).
  final previewing = <int>{};

  Future<void> _preview(int port, String url) async {
    setState(() => previewing.add(port));
    try {
      await openDevServer(context, widget.agent, port, url);
    } finally {
      if (mounted) setState(() => previewing.remove(port));
    }
  }

  Future<void> _share(int port) async {
    final f = widget.agent.features;
    setState(() => opening.add(port));
    try {
      final url = f.tunnels[port] ?? await f.startTunnel(port);
      await Clipboard.setData(ClipboardData(text: url));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${tr('Public link copied')}: $url'),
            action: SnackBarAction(label: tr('Open'), onPressed: () => widget.agent.client.openUrl(url)),
          ),
        );
      }
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      if (mounted) setState(() => opening.remove(port));
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final f = widget.agent.features;
    return ListenableBuilder(
      listenable: f,
      builder: (context, _) {
        if (f.devServers.isEmpty) return const SizedBox.shrink();
        return Column(
          children: [
            for (final e in f.devServers.entries)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Container(
                  padding: const EdgeInsets.fromLTRB(14, 6, 4, 6),
                  decoration: BoxDecoration(
                    color: p.success.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(Radii.lg),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(color: p.success, shape: BoxShape.circle),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          // On a server, "localhost" would read as this phone.
                          f.tunnels[e.key] ?? (widget.agent.client.isRemote ? 'server:${e.key}' : 'localhost:${e.key}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontFamily: mono, fontSize: 12.5, color: p.text),
                        ),
                      ),
                      previewing.contains(e.key)
                          ? const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                              child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                            )
                          : TextButton(onPressed: () => _preview(e.key, e.value), child: Text(tr('Preview'))),
                      opening.contains(e.key)
                          ? const Padding(
                              padding: EdgeInsets.all(12),
                              child: SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                            )
                          : IconButton(
                              tooltip: tr('Share a public link'),
                              icon: const Icon(LucideIcons.share2, size: 18),
                              onPressed: () => _share(e.key),
                            ),
                      IconButton(
                        tooltip: tr('Dismiss'),
                        icon: Icon(LucideIcons.x, size: 16, color: p.muted),
                        onPressed: () {
                          if (f.tunnels.containsKey(e.key)) f.stopTunnel(e.key);
                          f.dismissDevServer(e.key);
                        },
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Slash commands

/// Suggestions while the message starts with "/": templates and skills.
class SlashMenu extends StatelessWidget {
  const SlashMenu({super.key, required this.commands, required this.query, required this.onPick});
  final List<SlashCommand> commands;
  final String query;
  final void Function(SlashCommand) onPick;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final q = query.toLowerCase();
    final matches = commands.where((c) => c.name.toLowerCase().contains(q)).take(8).toList();
    if (matches.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      constraints: const BoxConstraints(maxHeight: 260),
      decoration: BoxDecoration(
        color: p.bg,
        borderRadius: BorderRadius.circular(Radii.lg),
        border: Border.all(color: p.border),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 20, offset: const Offset(0, 6))],
      ),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(vertical: 6),
        children: [
          for (final c in matches)
            ListTile(
              dense: true,
              leading: Icon(c.isSkill ? LucideIcons.puzzle : LucideIcons.slash, size: 18, color: p.accent),
              title: Text(
                '/${c.name}${c.hint != null ? '  ${c.hint}' : ''}',
                style: TextStyle(fontFamily: mono, fontSize: 13, color: p.text),
              ),
              subtitle: Text(c.description, maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => onPick(c),
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Project tools menu

Future<void> showProjectTools(
  BuildContext context,
  AgentController agent, {
  required void Function(String prompt) onPrompt,
}) async {
  void push(Widget w) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => w));
  final memory = '${agent.cwd}/AGENTS.md';
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (sheet) {
      void go(Widget w) {
        Navigator.pop(sheet);
        push(w);
      }

      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(tr('Project'), style: Theme.of(sheet).textTheme.titleLarge),
              const SizedBox(height: 12),
              SettingsGroup(
                children: [
                  SettingsRow(
                    icon: LucideIcons.folderOpen,
                    color: const Color(0xFFF76B15),
                    title: tr('Files'),
                    subtitle: tr('Browse and edit the project'),
                    onTap: () => go(FilesScreen(agent: agent)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.search,
                    color: context.palette.accentAlt,
                    title: tr('Search'),
                    subtitle: tr('Find text across every file'),
                    onTap: () => go(SearchScreen(agent: agent)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.history,
                    color: const Color(0xFF7C5CFC),
                    title: tr('Changes & undo'),
                    subtitle: tr('What the agent changed, and roll it back'),
                    onTap: () => go(ChangesScreen(agent: agent)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.gitBranch,
                    color: const Color(0xFF111113),
                    title: tr('Git'),
                    subtitle: tr('Commit, push, branches, issues and PRs'),
                    onTap: () => go(GitScreen(agent: agent, onWork: onPrompt)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.brain,
                    color: const Color(0xFFEC4899),
                    title: tr('Project memory'),
                    subtitle: tr('AGENTS.md: rules the agent follows in this folder'),
                    onTap: () async {
                      try {
                        if (!await agent.fs.exists(memory)) {
                          await agent.fs.writeString(
                            memory,
                            '# Project notes for the agent\n\n- Stack:\n- How to run:\n- Conventions:\n',
                          );
                        }
                      } catch (e) {
                        if (sheet.mounted) {
                          ScaffoldMessenger.of(sheet)
                              .showSnackBar(SnackBar(content: Text('${tr('Could not create it')}: $e')));
                        }
                        return;
                      }
                      if (sheet.mounted) go(EditorScreen(agent: agent, path: memory));
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              ListenableBuilder(
                listenable: agent.integrations,
                builder: (context, _) {
                  final it = agent.integrations;
                  final on = it.settings?.projectSearch[agent.cwd] ?? true;
                  Future<void> set(bool v) async {
                    final map = {...(it.settings?.projectSearch ?? {}), agent.cwd: v};
                    await it.updateSettings({'projectSearch': map});
                  }

                  return SettingsGroup(
                    children: [
                      SettingsRow(
                        icon: LucideIcons.globe,
                        color: const Color(0xFF0EA5E9),
                        title: tr('Web search'),
                        subtitle: tr('Allow the agent to search the web in this project'),
                        onTap: () => set(!on),
                        trailing: Switch(value: on, onChanged: set),
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              SettingsGroup(
                children: [
                  SettingsRow(
                    icon: LucideIcons.listTodo,
                    color: const Color(0xFF14B8A6),
                    title: tr('Background tasks'),
                    subtitle: tr('Queue, parallel agents and schedules'),
                    onTap: () => go(TasksScreen(agent: agent)),
                  ),
                  SettingsRow(
                    icon: LucideIcons.chartColumn,
                    color: const Color(0xFFF59E0B),
                    title: tr('Usage'),
                    subtitle: tr('Tokens and cost'),
                    onTap: () => go(UsageScreen(agent: agent)),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}
