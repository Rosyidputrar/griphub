import 'dart:convert';
import 'dart:io';

import 'drafts.dart';

/// One file or picture attached to a message that was already sent.
/// [path] is the copy under the project's `.attachments/` folder (or the
/// original path when copying failed); [size] is bytes, or -1 when unknown.
typedef SentAttachment = ({String path, String name, String? mime, int size});

const _imageExtensions = {'png', 'jpg', 'jpeg', 'webp', 'gif'};

/// Whether [a] is a picture (shown as a thumbnail, opened full-screen).
bool sentIsImage(SentAttachment a) {
  if (a.mime?.startsWith('image/') == true) return true;
  final name = a.name;
  if (!name.contains('.')) return false;
  return _imageExtensions.contains(name.split('.').last.toLowerCase());
}

/// Sent-message attachments, kept per chat so the transcript can show them
/// after a restart. Mirrors [Drafts]: one JSON file next to drafts.json.
/// Keyed by chat (session id) and the message's index among the chat's user
/// messages. The index is assigned when the host echoes the message, so it
/// matches the transcript order; a rewind-and-resend reuses the same index
/// (its record is replaced), and a forked chat starts a new namespace.
///
/// LIMITATION: this file lives in the app's own storage, not in the host
/// session, so it does NOT travel with GitHub sync. On another device the
/// messages still show their text (and the "Attached files:" paths), but
/// without thumbnails/chips.
class SentAttachments {
  SentAttachments._();
  static final instance = SentAttachments._();

  File get _file => File('${Drafts.root}/sent-attachments.json');

  /// chat -> ordinal -> records. Loaded lazily; tests point [Drafts.root]
  /// elsewhere before first access.
  Map<String, Map<String, List<Map<String, dynamic>>>>? _data;

  Map<String, Map<String, List<Map<String, dynamic>>>> get _all {
    if (_data != null) return _data!;
    final data = <String, Map<String, List<Map<String, dynamic>>>>{};
    try {
      final raw = jsonDecode(_file.readAsStringSync()) as Map;
      raw.forEach((chat, byOrdinal) {
        final ordinals = <String, List<Map<String, dynamic>>>{};
        (byOrdinal as Map).forEach((ordinal, records) {
          ordinals[ordinal as String] =
              (records as List).map((r) => (r as Map).cast<String, dynamic>()).toList();
        });
        data[chat as String] = ordinals;
      });
    } catch (_) {
      // Missing or corrupt: start empty rather than breaking the transcript.
    }
    _data = data;
    return data;
  }

  /// The attachments recorded for [ordinal] in [chat], in send order.
  /// Records with an empty path or name (corrupt entries) are dropped, but
  /// a file that no longer exists on disk is still returned: the viewer
  /// explains that instead of crashing.
  List<SentAttachment> forMessage(String? chat, int ordinal) {
    if (chat == null) return const [];
    final records = _all[chat]?['$ordinal'];
    if (records == null) return const [];
    return [
      for (final r in records)
        (
          path: r['path'] as String? ?? '',
          name: r['name'] as String? ?? '',
          mime: r['mime'] as String?,
          size: (r['size'] as num?)?.toInt() ?? -1,
        ),
    ].where((a) => a.path.isNotEmpty && a.name.isNotEmpty).toList();
  }

  /// Records [items] as the attachments of [ordinal] in [chat], replacing
  /// any previous record there (a rewind-and-resend reuses the index).
  /// Best-effort: a storage failure must never break sending.
  void record(String? chat, int ordinal, List<SentAttachment> items) {
    if (chat == null) return;
    final ordinals = _all.putIfAbsent(chat, () => {});
    ordinals['$ordinal'] = [
      for (final a in items)
        {'path': a.path, 'name': a.name, 'mime': a.mime, 'size': a.size},
    ];
    try {
      _file.writeAsStringSync(jsonEncode(_all));
    } catch (_) {}
  }
}

/// Removes the machine-generated "Attached files:" block that
/// [preparePrompt] appends to a sent message, so the bubble can show chips
/// instead of raw paths. Only strips a trailing block in the exact format
/// (a leading "Attached files:" line followed by "- " lines); anything else
/// — including user-typed text — is returned unchanged.
String stripAttachedNote(String text) {
  final trimmed = text.trimRight();
  const marker = '\n\nAttached files:\n';
  final at = trimmed.lastIndexOf(marker);
  if (at >= 0) {
    final tail = trimmed.substring(at + marker.length);
    if (tail.isNotEmpty && tail.split('\n').every((l) => l.startsWith('- '))) {
      return trimmed.substring(0, at);
    }
    return text;
  }
  // The note alone (an empty message with only files): no leading newlines.
  const bare = 'Attached files:\n';
  if (trimmed.startsWith(bare)) {
    final tail = trimmed.substring(bare.length);
    if (tail.isNotEmpty && tail.split('\n').every((l) => l.startsWith('- '))) {
      return '';
    }
  }
  return text;
}
