import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:markdown/markdown.dart' as md;

import '../agent/sent_attachments.dart';
import '../agent/updater.dart';
import 'code_view.dart';
import 'i18n.dart';
import 'theme.dart';

/// Opens [attachment] in a full-screen viewer: pictures full-screen with
/// pinch zoom, markdown rendered, other readable text as code, anything
/// else as file info. Never crashes on a missing, huge, or undecodable file.
Future<void> openAttachmentViewer(BuildContext context, SentAttachment attachment) {
  return Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => AttachmentViewerScreen(attachment: attachment)),
  );
}

class AttachmentViewerScreen extends StatelessWidget {
  const AttachmentViewerScreen({super.key, required this.attachment});
  final SentAttachment attachment;

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
      body: _ViewerBody(attachment: attachment),
    );
  }
}

class _ViewerBody extends StatelessWidget {
  const _ViewerBody({required this.attachment});
  final SentAttachment attachment;

  @override
  Widget build(BuildContext context) {
    final a = attachment;
    final file = File(a.path);
    if (!file.existsSync()) {
      return _Info(attachment: a, message: tr('File no longer available'));
    }
    if (sentIsImage(a)) {
      final size = _safeLength(file);
      if (size > AttachmentViewerScreen.maxImageBytes) {
        return _Info(attachment: a, message: tr('File is too large to preview'), size: size);
      }
      return InteractiveViewer(
        maxScale: 4.0,
        child: Center(
          child: Image.file(
            file,
            errorBuilder: (_, _, _) =>
                _Info(attachment: a, message: tr('Preview is not available for this file')),
          ),
        ),
      );
    }
    List<int> bytes;
    try {
      bytes = file.readAsBytesSync();
    } catch (_) {
      return _Info(attachment: a, message: tr('File could not be read'));
    }
    if (bytes.length > AttachmentViewerScreen.maxTextBytes) {
      return _Info(attachment: a, message: tr('File is too large to preview'), size: bytes.length);
    }
    String? text;
    try {
      text = utf8.decode(bytes);
    } catch (_) {
      text = null;
    }
    if (text == null) {
      return _Info(attachment: a, message: tr('Preview is not available for this file type'), size: bytes.length);
    }
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

int _safeLength(File file) {
  try {
    return file.lengthSync();
  } catch (_) {
    return -1;
  }
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
