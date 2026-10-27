import 'dart:convert';

import 'sent_attachments.dart';

class ModelInfo {
  ModelInfo(this.json);
  final Map<String, dynamic> json;

  String get provider => json['provider'] as String;
  String get id => json['id'] as String;
  String get name => json['name'] as String? ?? id;
  bool get reasoning => json['reasoning'] == true;
  int? get contextWindow => json['contextWindow'] as int?;
  int? get maxTokens => (json['maxTokens'] as num?)?.toInt();
  bool get acceptsImages => (json['input'] as List?)?.contains('image') ?? false;
  String get key => '$provider/$id';

  /// GripHub pricing, when the host knows it (router.ts): credits per 1M
  /// tokens, the per-request minimum, a running promo, and availability.
  ModelPricing? get pricing => json['pricing'] is Map ? ModelPricing((json['pricing'] as Map).cast<String, dynamic>()) : null;
}

class ModelPricing {
  ModelPricing(this.json);
  final Map<String, dynamic> json;
  double? get credits => (json['credits'] as num?)?.toDouble();
  double? get list => (json['list'] as num?)?.toDouble();
  double? get floor => (json['floor'] as num?)?.toDouble();
  String? get promo => json['promo'] as String?;
  DateTime? get promoEndsAt => DateTime.tryParse(json['promoEndsAt'] as String? ?? '');
  bool get available => json['available'] != false;

  /// A promo that has not ended yet.
  bool get onPromo => list != null && (promoEndsAt == null || promoEndsAt!.isAfter(DateTime.now()));
}

/// Favorite models in the order they were starred, not catalog order. Keys
/// missing from the catalog are skipped here but stay in storage, so they
/// reappear if the model returns. Repeated keys show the model once.
List<ModelInfo> favoriteModelsInOrder(List<ModelInfo> models, List<String> favoriteKeys) {
  final byKey = {for (final m in models) m.key: m};
  final seen = <String>{};
  return [
    for (final key in favoriteKeys)
      if (byKey[key] != null && seen.add(key)) byKey[key]!,
  ];
}

class ProviderInfo {
  ProviderInfo(this.json);
  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get name => json['name'] as String? ?? id;
  bool get configured => json['configured'] == true;
  bool get oauth => json['oauth'] == true;
  List<String> get methods => (json['methods'] as List? ?? const []).cast<String>();
  int get modelCount => json['models'] as int? ?? 0;

  /// Added by the user with a base URL and API key (see agent/src/providers.ts).
  bool get custom => json['custom'] == true;
}

/// A user-added endpoint as stored by the host; the API key itself never comes back.
class CustomProvider {
  CustomProvider(this.json);
  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String get name => json['name'] as String? ?? id;
  String get api => json['api'] as String? ?? 'openai-completions';
  String get baseUrl => json['baseUrl'] as String? ?? '';
  bool get hasKey => json['hasKey'] == true;
  List<CustomModel> get models =>
      (json['models'] as List? ?? const []).map((e) => CustomModel((e as Map).cast<String, dynamic>())).toList();
}

class CustomModel {
  CustomModel(this.json);
  final Map<String, dynamic> json;

  String get id => json['id'] as String;
  String? get name => json['name'] as String?;
  int? get contextWindow => (json['contextWindow'] as num?)?.toInt();
  int? get maxTokens => (json['maxTokens'] as num?)?.toInt();
  bool get reasoning => json['reasoning'] == true;

  /// False for models that always think: they get effort levels but no "off".
  bool get canDisableThinking => json['canDisableThinking'] != false;
  bool get vision => (json['input'] as List?)?.contains('image') ?? false;

  /// False when the endpoint says effort levels make no difference.
  bool get effort => json['effort'] != false;

  /// A copy with reasoning or vision switched by hand, for endpoints that don't say.
  CustomModel copyWith({bool? reasoning, bool? vision}) => CustomModel({
    ...json,
    'reasoning': ?reasoning,
    if (reasoning == false) 'canDisableThinking': null,
    if (vision != null) 'input': vision ? ['text', 'image'] : ['text'],
  });
}

class ProjectDeleteCheck {
  ProjectDeleteCheck(this.json);
  final Map<String, dynamic> json;

  int get chats => json['chats'] as int? ?? 0;
  bool get isGit => json['git'] == true;
  int get changes => json['changes'] as int? ?? 0;
  int get unpushed => json['unpushed'] as int? ?? 0;
  List<String> get blockers => (json['blockers'] as List? ?? const []).cast<String>();

  /// Work that exists only on this phone and is lost with the folder.
  bool get losesWork => changes > 0 || unpushed > 0;
}

class SessionSummary {
  SessionSummary(this.json);
  final Map<String, dynamic> json;

  String get path => json['path'] as String;
  String get id => json['id'] as String;
  String? get name => json['name'] as String?;
  String get cwd => json['cwd'] as String? ?? '';
  String get firstMessage => json['firstMessage'] as String? ?? '';
  int get messageCount => json['messageCount'] as int? ?? 0;
  DateTime get modified => DateTime.fromMillisecondsSinceEpoch(json['modified'] as int);

  String get title {
    final n = name?.trim();
    if (n != null && n.isNotEmpty) return n;
    final first = firstMessage.trim().split('\n').first;
    return first.isEmpty ? 'Untitled session' : first;
  }
}

// ---------------------------------------------------------------------------
// Transcript

sealed class ChatEntry {}

class UserEntry extends ChatEntry {
  UserEntry(this.text, {this.images = 0, this.attachments = const []});
  final String text;
  final int images;

  /// Files/pictures sent with this message, from the sent-attachments
  /// store. Empty for messages sent before attachment display existed:
  /// those still show their text unchanged.
  final List<SentAttachment> attachments;
}

enum BlockKind { text, thinking, toolCall }

class Block {
  Block(this.kind);
  final BlockKind kind;
  final StringBuffer buffer = StringBuffer();
  String? toolCallId;
  String? toolName;
  Map<String, dynamic>? args;

  String get text => buffer.toString();

  /// Reads the streamed argument JSON incrementally: each call only scans what
  /// arrived since the last one, so a long file being written costs the same
  /// per frame at its end as at its start.
  PartialJsonReader? _reader;

  /// Arguments so far: final ones once known, else string fields read from
  /// the streamed JSON (for tool calls the buffer holds raw argument JSON).
  Map<String, dynamic>? get liveArgs {
    if (args != null) return args;
    if (buffer.isEmpty) return null;
    var reader = _reader;
    // The buffer only grows while streaming; if it was replaced, read it again from the start.
    if (reader == null || buffer.length < reader.length) reader = _reader = PartialJsonReader();
    if (buffer.length != reader.length) reader.update(text);
    return reader.values;
  }

  set text(String value) {
    _reader = null;
    buffer
      ..clear()
      ..write(value);
  }
}

class AssistantEntry extends ChatEntry {
  final blocks = <int, Block>{};
  bool streaming = true;
  String? error;
  bool aborted = false;
  String? model;

  List<Block> get orderedBlocks {
    final keys = blocks.keys.toList()..sort();
    return [for (final k in keys) blocks[k]!];
  }

  Block block(int index, BlockKind kind) => blocks.putIfAbsent(index, () => Block(kind));

  /// Replaces streamed state with the authoritative final message.
  void applyMessage(Map<String, dynamic> message) {
    blocks.clear();
    final content = message['content'] as List? ?? const [];
    for (var i = 0; i < content.length; i++) {
      final c = content[i] as Map<String, dynamic>;
      switch (c['type']) {
        case 'text':
          block(i, BlockKind.text).text = c['text'] as String? ?? '';
        case 'thinking':
          block(i, BlockKind.thinking).text = c['thinking'] as String? ?? '';
        case 'toolCall':
          block(i, BlockKind.toolCall)
            ..toolCallId = c['id'] as String?
            ..toolName = c['name'] as String?
            ..args = (c['arguments'] as Map?)?.cast<String, dynamic>();
      }
    }
    streaming = false;
    model = message['model'] as String?;
    final stop = message['stopReason'];
    aborted = stop == 'aborted';
    if (stop == 'error') error = readableError(message['errorMessage'] as String? ?? 'The model returned an error.');
  }
}

/// Turns a provider's `400 {"error":{"message":...}}` into `message (400)`.
String readableError(String raw) {
  final match = RegExp(r'^(\d{3})\s+(\{.*\})$', dotAll: true).firstMatch(raw.trim());
  if (match == null) return raw;
  try {
    final body = jsonDecode(match.group(2)!);
    final error = body is Map ? body['error'] : null;
    final message = error is Map ? error['message'] : (body is Map ? body['message'] : null);
    if (message is String && message.isNotEmpty) return '$message (${match.group(1)})';
  } on FormatException {
    // Not JSON after all; show it as is.
  }
  return raw;
}

class NoticeEntry extends ChatEntry {
  NoticeEntry(this.text, {this.error = false});
  final String text;
  final bool error;
}

enum ToolStatus { running, done, failed }

class ToolRun {
  ToolRun(this.id);
  final String id;
  ToolStatus status = ToolStatus.running;
  String output = '';
}

String contentText(dynamic content) {
  if (content is String) return content;
  if (content is List) {
    return content.whereType<Map>().where((c) => c['type'] == 'text').map((c) => c['text'] as String? ?? '').join('\n');
  }
  return '';
}

int contentImages(dynamic content) =>
    content is List ? content.whereType<Map>().where((c) => c['type'] == 'image').length : 0;

/// One-line summary of a tool call for collapsed display.
String toolSummary(String? name, Map<String, dynamic>? args) {
  if (args == null) return '';
  String? pick(List<String> keys) {
    for (final k in keys) {
      final v = args[k];
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }

  final value = switch (name) {
    'bash' => pick(['command'])?.replaceAllMapped(
      RegExp(r'''(?:/data/(?:data|user/\d+)/id\.griphub\.agent|/storage/emulated/\d+|/sdcard)(?:/[^\s'"/;|&>]+)+'''),
      (m) => _shortPath(m[0]) ?? m[0]!,
    ),
    'read' || 'write' || 'edit' || 'ls' => _shortPath(pick(['path', 'file_path'])),
    'grep' => pick(['pattern']),
    'find' => pick(['pattern', 'path']),
    _ => null,
  };
  return (value ?? jsonEncode(args)).split('\n').first;
}

/// Full paths on the phone are long and say little; the file name is what matters. Generic names
/// (SKILL.md, index.html, …) keep their folder so it's clear which one, e.g. `ui-designer/SKILL.md`.
String? _shortPath(String? path) {
  if (path == null) return null;
  final parts = path.split('/').where((s) => s.isNotEmpty).toList();
  if (parts.isEmpty) return path;
  final base = parts.last;
  const generic = {'skill.md', 'readme.md', 'agents.md', 'package.json', 'main.py', 'main.dart'};
  final stem = base.contains('.') ? base.substring(0, base.lastIndexOf('.')).toLowerCase() : base.toLowerCase();
  if (parts.length > 1 && (generic.contains(base.toLowerCase()) || stem == 'index')) {
    return '${parts[parts.length - 2]}/$base';
  }
  return base;
}

/// Reads top-level-looking `"key": "string"` pairs from possibly truncated
/// JSON. The last value may be cut off; it is returned as far as it goes.
/// Repeated keys keep the latest value (e.g. the edit being written now).
Map<String, dynamic> partialJsonStrings(String raw) => (PartialJsonReader()..update(raw)).values;

/// [partialJsonStrings] for text that keeps growing: [update] with the whole
/// text so far, and only the part after the previous call is scanned. A value
/// still being written is kept in a buffer, so an unfinished escape at the end
/// (`\`, `\u00`) waits for the rest instead of being re-read from the start.
class PartialJsonReader {
  static final _key = RegExp(r'"([A-Za-z_][A-Za-z0-9_]*)"\s*:\s*"');

  /// The values read so far; the one being written holds what has arrived.
  final values = <String, dynamic>{};

  /// How much of the text has been read.
  int get length => _length;
  int _length = 0;

  /// Where scanning resumes: the start of the next key, or the next character of [_key]'s value.
  int _pos = 0;
  String? _open;
  final _value = StringBuffer();

  void update(String raw) {
    _length = raw.length;
    while (_pos < raw.length) {
      if (_open == null) {
        final m = _key.firstMatch(raw.substring(_pos));
        // The next key isn't complete yet: try again from here next time.
        if (m == null) return;
        _open = m.group(1);
        _value.clear();
        values[_open!] = '';
        _pos += m.end;
      }
      var i = _pos;
      var closed = false;
      while (i < raw.length) {
        final c = raw[i];
        if (c == '"') {
          closed = true;
          break;
        }
        if (c != r'\') {
          // Copy the run of plain characters in one go.
          var j = i + 1;
          while (j < raw.length && raw[j] != '"' && raw[j] != r'\') {
            j++;
          }
          _value.write(raw.substring(i, j));
          i = j;
          continue;
        }
        // An escape cut off at the end: wait for the rest.
        if (i + 1 >= raw.length) break;
        final e = raw[i + 1];
        if (e == 'u') {
          if (i + 6 > raw.length) break;
          final code = int.tryParse(raw.substring(i + 2, i + 6), radix: 16);
          if (code != null) _value.writeCharCode(code);
          i += 6;
          continue;
        }
        _value.write(switch (e) {
          'n' => '\n',
          't' => '\t',
          'r' => '\r',
          'b' => '\b',
          'f' => '\f',
          _ => e,
        });
        i += 2;
      }
      _pos = i;
      values[_open!] = _value.toString();
      if (!closed) return;
      _open = null;
      _pos = i + 1;
    }
  }
}

/// What the copy-and-model footer under an assistant reply shows.
typedef TurnFooter = ({String text, String? model});

/// Footers for a transcript, keyed by entry index. One turn (from a user
/// message to the next) is several assistant messages — text, tools, more
/// text — and the footer belongs only under the last one, once the turn is
/// over: it copies the turn's final answer and names the model that gave it.
/// It used to appear under every step that had text, mid-run.
///
/// [busy] is whether the agent is still working on the last turn; that turn
/// gets no footer until it ends.
Map<int, TurnFooter> turnFooters(List<ChatEntry> entries, {required bool busy}) {
  final out = <int, TurnFooter>{};
  var start = 0;
  void close(int end, {required bool last}) {
    if (last && busy) return;
    // The last assistant message of the turn, and the last one with text.
    int? tail;
    AssistantEntry? answer;
    for (var i = end - 1; i >= start; i--) {
      final e = entries[i];
      if (e is! AssistantEntry) continue;
      tail ??= i;
      if (e.streaming) return;
      if (answer == null && _replyText(e).isNotEmpty) answer = e;
      if (answer != null) break;
    }
    if (tail == null || answer == null) return;
    final lastEntry = entries[tail] as AssistantEntry;
    out[tail] = (text: _replyText(answer), model: lastEntry.model ?? answer.model);
  }

  for (var i = 0; i < entries.length; i++) {
    if (entries[i] is UserEntry) {
      close(i, last: false);
      start = i + 1;
    }
  }
  close(entries.length, last: true);
  return out;
}

String _replyText(AssistantEntry e) => [
  for (final b in e.orderedBlocks)
    if (b.kind == BlockKind.text && b.text.trim().isNotEmpty) b.text.trim(),
].join('\n\n');
