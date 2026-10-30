import 'dart:convert';
import 'dart:io';

import 'drafts.dart';
import 'sent_attachments.dart';

/// A message typed while the server could not be reached (server mode): kept, in order, until the link is back, then
/// sent as if it had gone through at once. The chat it was typed in is kept with it, so it goes to that chat.
class OfflinePrompt {
  OfflinePrompt({
    required this.id,
    required this.text,
    this.images = const [],
    this.attachments = const [],
    this.session,
    this.error,
  });

  final String id;
  final String text;

  /// Pictures as the host takes them (`{data, mimeType}`, base64).
  final List<Map<String, String>> images;
  final List<SentAttachment> attachments;
  final String? session;

  /// Why the host refused it once the link was back (no budget left, no model): it then waits for the user, who sends
  /// it again or drops it, and nothing after it goes first.
  String? error;

  Map<String, dynamic> toJson() => {
    'id': id,
    'text': text,
    if (images.isNotEmpty) 'images': images,
    if (attachments.isNotEmpty)
      'attachments': [for (final a in attachments) {'path': a.path, 'name': a.name, 'mime': a.mime, 'size': a.size}],
    'session': ?session,
    'error': ?error,
  };

  static OfflinePrompt? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], text = j['text'];
    if (id is! String || text is! String) return null;
    return OfflinePrompt(
      id: id,
      text: text,
      images: [
        for (final i in (j['images'] as List? ?? const []))
          if (i is Map) {for (final e in i.entries) '${e.key}': '${e.value}'},
      ],
      attachments: [
        for (final a in (j['attachments'] as List? ?? const []))
          if (a is Map && a['path'] is String && a['name'] is String)
            (
              path: a['path'] as String,
              name: a['name'] as String,
              mime: a['mime'] as String?,
              size: (a['size'] as num?)?.toInt() ?? -1,
            ),
      ],
      session: j['session'] as String?,
      error: j['error'] as String?,
    );
  }
}

/// Where waiting messages are kept between app runs: one JSON file next to the drafts, so a message typed in a tunnel
/// is still there after the app was closed.
class OfflinePromptStore {
  OfflinePromptStore._();
  static final instance = OfflinePromptStore._();

  File get _file => File('${Drafts.root}/offline-prompts.json');

  List<OfflinePrompt> load() {
    try {
      final data = jsonDecode(_file.readAsStringSync());
      return [for (final j in (data as List)) ?OfflinePrompt.fromJson(j)];
    } catch (_) {
      return [];
    }
  }

  void save(List<OfflinePrompt> prompts) {
    try {
      if (prompts.isEmpty) {
        if (_file.existsSync()) _file.deleteSync();
        return;
      }
      _file.parent.createSync(recursive: true);
      _file.writeAsStringSync(jsonEncode([for (final p in prompts) p.toJson()]));
    } catch (_) {
      // Storage full or gone: they still wait in memory for this run.
    }
  }
}
