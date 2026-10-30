import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:markdown/markdown.dart' as md;

import '../agent/agent_fs.dart';
import '../agent/sent_attachments.dart';
import '../agent/updater.dart';
import 'code_view.dart';
import 'i18n.dart';
import 'theme.dart';

/// Opens [attachment] in a full-screen viewer: pictures full-screen with
/// pinch zoom, markdown rendered, other readable text as code, anything
/// else as file info. Never crashes on a missing, huge, or undecodable file.
/// The copy lives on the agent's machine ([fs]: the phone, or a server).
Future<void> openAttachmentViewer(BuildContext context, SentAttachment attachment, {AgentFs fs = const LocalFs()}) {
  return Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => AttachmentViewerScreen(attachment: attachment, fs: fs),
    ),
  );
}

/// Shows a picture held in memory (one a tool returned) full screen, to zoom and pan.
Future<void> openImageBytesViewer(BuildContext context, Uint8List bytes, {required String title}) {
  return Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => ImageBytesViewerScreen(bytes: bytes, title: title)),
  );
}

class ImageBytesViewerScreen extends StatelessWidget {
  const ImageBytesViewerScreen({super.key, required this.bytes, required this.title});
  final Uint8List bytes;
  final String title;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Scaffold(
      appBar: AppBar(title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis)),
      body: InteractiveViewer(
        maxScale: 4.0,
        child: Center(
          child: Image.memory(
            bytes,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => Text(tr('Preview is not available for this file'), style: TextStyle(color: p.muted)),
          ),
        ),
      ),
    );
  }
}

class AttachmentViewerScreen extends StatelessWidget {
  const AttachmentViewerScreen({super.key, required this.attachment, this.fs = const LocalFs()});
  final SentAttachment attachment;
  final AgentFs fs;

  /// Text previews stop here; larger files show info instead of eating RAM.
  static const maxTextBytes = 512 * 1024;

  /// Picture previews stop here; larger pictures show info instead of
  /// decoding a bitmap that could exhaust memory.
  static const maxImageBytes = 16 * 1024 * 1024;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(attachment.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      body: _ViewerBody(attachment: attachment, fs: fs),
    );
  }
}

/// What the viewer found: a picture on the phone to show, text, or why there is nothing to show.
typedef _Loaded = ({String? image, String? text, String? message, int? size});

class _ViewerBody extends StatefulWidget {
  const _ViewerBody({required this.attachment, required this.fs});
  final SentAttachment attachment;
  final AgentFs fs;

  @override
  State<_ViewerBody> createState() => _ViewerBodyState();
}

class _ViewerBodyState extends State<_ViewerBody> {
  late final Future<_Loaded> _loaded = _load();

  Future<_Loaded> _load() async {
    final a = widget.attachment;
    final fs = widget.fs;
    _Loaded info(String message, [int? size]) => (image: null, text: null, message: message, size: size);
    final FsStat st;
    try {
      st = await fs.stat(a.path);
    } catch (_) {
      return info(tr('File could not be read'));
    }
    if (!st.exists || st.isDir) return info(tr('File no longer available'));
    if (sentIsImage(a)) {
      if (st.size > AttachmentViewerScreen.maxImageBytes) return info(tr('File is too large to preview'), st.size);
      try {
        // On a server the picture is fetched to the phone once (kept while unchanged).
        return (image: await fs.toPhoneFile(a.path), text: null, message: null, size: st.size);
      } catch (_) {
        return info(tr('File could not be read'));
      }
    }
    if (st.size > AttachmentViewerScreen.maxTextBytes) return info(tr('File is too large to preview'), st.size);
    List<int> bytes;
    try {
      bytes = await fs.read(a.path);
    } catch (_) {
      return info(tr('File could not be read'));
    }
    if (bytes.length > AttachmentViewerScreen.maxTextBytes) {
      return info(tr('File is too large to preview'), bytes.length);
    }
    try {
      return (image: null, text: utf8.decode(bytes), message: null, size: bytes.length);
    } catch (_) {
      return info(tr('Preview is not available for this file type'), bytes.length);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<_Loaded>(
      future: _loaded,
      builder: (context, snap) {
        final loaded = snap.data;
        if (loaded == null) return const Center(child: CircularProgressIndicator());
        return _content(context, loaded);
      },
    );
  }

  Widget _content(BuildContext context, _Loaded loaded) {
    final a = widget.attachment;
    if (loaded.message != null) return _Info(attachment: a, message: loaded.message!, size: loaded.size);
    if (loaded.image != null) {
      return InteractiveViewer(
        maxScale: 4.0,
        child: Center(
          child: Image.file(
            File(loaded.image!),
            errorBuilder: (_, _, _) => _Info(attachment: a, message: tr('Preview is not available for this file')),
          ),
        ),
      );
    }
    final text = loaded.text!;
    final content = text;
    final ext = a.name.contains('.') ? a.name.split('.').last.toLowerCase() : '';
    if (ext == 'md' || a.mime == 'text/markdown') {
      final theme = Theme.of(context);
      final p = context.palette;
      final body = theme.textTheme.bodyLarge!;
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: MarkdownBody(
          data: text,
          selectable: true,
          extensionSet: md.ExtensionSet.gitHubFlavored,
          styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
            p: body,
            a: body.copyWith(decoration: TextDecoration.underline, decorationColor: p.faint),
            h1: theme.textTheme.headlineSmall,
            h2: theme.textTheme.titleLarge,
            h3: theme.textTheme.titleMedium,
            strong: body.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.all(16),
      child: LayoutBuilder(
        builder: (context, constraints) => CodeBox(
          text: content,
          label: a.name,
          language: ext.isEmpty ? null : ext,
          maxHeight: constraints.maxHeight,
        ),
      ),
    );
  }
}

/// A picture on the agent's machine ([fs]). On the phone it is shown straight from disk; on a server it is fetched to
/// the phone once (kept while unchanged), and anything over [maxBytes] or unreadable shows [errorBuilder].
class AgentImage extends StatefulWidget {
  const AgentImage({
    super.key,
    required this.fs,
    required this.path,
    required this.maxBytes,
    this.width,
    this.height,
    this.fit,
    required this.errorBuilder,
  });
  final AgentFs fs;
  final String path;
  final int maxBytes;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final Widget Function(BuildContext context, Object error, StackTrace? stack) errorBuilder;

  @override
  State<AgentImage> createState() => _AgentImageState();
}

class _AgentImageState extends State<AgentImage> {
  Future<String>? _phonePath;

  @override
  void didUpdateWidget(AgentImage old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path || old.fs != widget.fs) _phonePath = null;
  }

  Future<String> _fetch() async {
    final st = await widget.fs.stat(widget.path);
    if (!st.exists || st.isDir) throw PathNotFoundException(widget.path, const OSError('Not a file'));
    if (st.size > widget.maxBytes) throw FileSystemException('Too large to show', widget.path);
    return widget.fs.toPhoneFile(widget.path);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.fs.isLocal) return _image(widget.path);
    _phonePath ??= _fetch();
    return FutureBuilder<String>(
      future: _phonePath,
      builder: (context, snap) {
        if (snap.hasError) return widget.errorBuilder(context, snap.error!, snap.stackTrace);
        if (!snap.hasData) {
          return SizedBox(
            width: widget.width,
            height: widget.height,
            child: Center(
              child: SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 1.6, color: context.palette.muted),
              ),
            ),
          );
        }
        return _image(snap.data!);
      },
    );
  }

  Widget _image(String path) => Image.file(
    File(path),
    width: widget.width,
    height: widget.height,
    fit: widget.fit,
    errorBuilder: widget.errorBuilder,
  );
}

/// File facts when there is nothing to preview (or the preview failed).
class _Info extends StatelessWidget {
  const _Info({required this.attachment, required this.message, this.size});
  final SentAttachment attachment;
  final String message;
  final int? size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final a = attachment;
    final bytes = size ?? (a.size >= 0 ? a.size : null);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
      children: [
        Icon(LucideIcons.fileText, size: 40, color: p.muted),
        const SizedBox(height: 16),
        Text(a.name, style: Theme.of(context).textTheme.titleMedium, textAlign: TextAlign.center),
        const SizedBox(height: 8),
        Text(
          message,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: p.muted),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        if (bytes != null) _InfoRow(label: tr('Size'), value: formatBytes(bytes)),
        if (a.mime != null) _InfoRow(label: tr('Type'), value: a.mime!),
        _InfoRow(label: tr('Path'), value: a.path),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: p.muted)),
          const SizedBox(height: 2),
          SelectableText(value, style: Theme.of(context).textTheme.bodyMedium),
        ],
      ),
    );
  }
}
