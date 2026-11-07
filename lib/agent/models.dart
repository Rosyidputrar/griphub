import 'dart:convert';
import 'dart:typed_data';

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

  /// A plain conversation (agent/src/chatmode.ts), not a coding chat. An older host does not say: coding, as every
  /// chat was before.
  bool get isChat => json['chatMode'] == 'chat';

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
  UserEntry(this.text, {this.images = 0, this.attachments = const [], this.visionReads = const []});
  final String text;
  final int images;

  /// The pictures of this message (or of an earlier one it asks about) read into text by a vision model for a model
  /// that cannot read them (agent/src/visiontranslate.ts). Hidden from the bubble; the answer's footer names the reader.
  final List<VisionRead> visionReads;

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

  /// This model request's usage, once the message is final (null while streaming, or for a message without it).
  RequestUsage? usage;

  /// How long the whole turn took, on a turn's last reply once it is over (from the host: live at the turn's end, and
  /// kept with the chat).
  int? turnMs;

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
    usage = RequestUsage.fromMessage(message);
    turnMs = (message['griphubTurnMs'] as num?)?.toInt() ?? turnMs;
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

/// The chat's older turns being summarized to keep its context in bounds (pi's compaction): running, done or failed.
class CompactionEntry extends ChatEntry {
  CompactionEntry({this.startedAt, this.limit, this.running = true, this.tokensBefore, this.tokensAfter});

  /// When the summary began, by this phone's clock; null for one read back from the chat's history.
  final DateTime? startedAt;

  /// The context limit that set it off (Settings > Usage), when the host started it for that.
  final int? limit;
  bool running;
  int? tokensBefore;
  int? tokensAfter;

  /// What the summary cost: it is a model request too. Null when unknown (the host's estimate has no price for the
  /// model, or the chat is from before the host said).
  double? credits;

  /// How long it took, once it ended.
  Duration? took;

  /// Why it failed, if it did.
  String? error;

  /// The user stopped it.
  bool aborted = false;
}

/// A background job's result coming back to its chat: a notice, not a bubble (the user did not send it), and the start
/// of the turn in which the agent carries on with it.
/// Evidence of self-verification (agent/src/verify.ts): the project's check, run by the app in this session after the
/// agent changed files. A block of its own in the chat, never a tool card.
class VerifyEntry extends ChatEntry {
  VerifyEntry(Map<String, dynamic> details)
    : evidence = (details['evidence'] as Map? ?? const {}).cast<String, dynamic>(),
      next = details['next'] as String? ?? 'close';
  final Map<String, dynamic> evidence;

  /// What the agent was told to do next: fix (another round) or close.
  final String next;

  /// passed, failed, none (no test could be run), declined (not allowed to run) or tests-changed.
  String get status => evidence['status'] as String? ?? 'none';
  String? get command => evidence['command'] as String?;
  String? get source => evidence['source'] as String?;
  int? get exitCode => (evidence['exitCode'] as num?)?.toInt();
  Duration get took => Duration(milliseconds: (evidence['durationMs'] as num?)?.toInt() ?? 0);
  String get summary => evidence['summary'] as String? ?? '';
  String? get outputId => evidence['outputId'] as String?;
  int get round => (evidence['round'] as num?)?.toInt() ?? 0;
  int get maxRounds => (evidence['maxRounds'] as num?)?.toInt() ?? 0;
  List<String> get testsTouched => (evidence['testsTouched'] as List? ?? const []).whereType<String>().toList();
  String? get reason => evidence['reason'] as String?;
  bool get timedOut => evidence['timedOut'] == true;
  bool get passed => status == 'passed';
}

class JobEntry extends ChatEntry {
  JobEntry(this.job);

  /// The job as it was when it ended (agent/src/jobs.ts `jobWire`).
  final Map<String, dynamic> job;

  String get id => job['id'] as String? ?? '';
  String get label => job['label'] as String? ?? job['command'] as String? ?? '';
  String get status => job['status'] as String? ?? 'done';
  int? get exitCode => (job['exitCode'] as num?)?.toInt();
  Duration get took => Duration(milliseconds: (job['elapsedMs'] as num?)?.toInt() ?? 0);
  String get tail => job['tail'] as String? ?? '';
  String get command => job['command'] as String? ?? '';
}

enum ToolStatus { running, done, failed }

class ToolRun {
  ToolRun(this.id);
  final String id;
  ToolStatus status = ToolStatus.running;
  String output = '';

  /// Pictures in the result (a `read` of an image): shown as thumbnails on the tool's card.
  List<ToolImage> images = const [];

  /// generate_image's progress and result (its `details`), while running and once done.
  ImageJob? imageJob;

  /// The result's `details`, for tools whose card reads them (remember: the memory proposal).
  Map<String, dynamic>? details;
}

/// One picture of a generate_image call.
class ImageSlot {
  const ImageSlot({required this.status, this.file, this.error, this.maybeBilled = false});
  factory ImageSlot.fromJson(Map<String, dynamic> j) => ImageSlot(
    status: switch (j['status']) {
      'done' => ImageSlotStatus.done,
      'failed' => ImageSlotStatus.failed,
      'stopped' => ImageSlotStatus.stopped,
      _ => ImageSlotStatus.running,
    },
    file: j['file'] as String?,
    error: j['error'] as String?,
    maybeBilled: j['maybeBilled'] == true,
  );
  final ImageSlotStatus status;

  /// The saved picture, on the agent's machine (the phone, or a server).
  final String? file;
  final String? error;

  /// A failure that may still have been billed (it timed out, or was stopped after it was sent).
  final bool maybeBilled;
}

enum ImageSlotStatus { running, done, failed, stopped }

/// What generate_image reports (agent/src/image.ts ImageDetails): the model, the pictures as they land, the cost.
class ImageJob {
  const ImageJob({
    required this.model,
    required this.size,
    required this.prompt,
    required this.slots,
    this.asked = 1,
    this.rate,
    this.credits,
    this.cheapest = false,
    this.startedAt,
    this.finishedAt,
  });

  /// From a tool result's or update's `details`; null when it is not one (an older host, another tool).
  static ImageJob? fromDetails(Object? details) {
    if (details is! Map || details['slots'] is! List || details['model'] is! String) return null;
    final slots = [for (final s in (details['slots'] as List).whereType<Map>()) ImageSlot.fromJson(s.cast<String, dynamic>())];
    if (slots.isEmpty) return null;
    DateTime? at(Object? v) => v is num ? DateTime.fromMillisecondsSinceEpoch(v.toInt()) : null;
    return ImageJob(
      model: details['model'] as String,
      size: details['size'] as String? ?? '1024x1024',
      prompt: details['prompt'] as String? ?? '',
      slots: slots,
      asked: (details['asked'] as num?)?.toInt() ?? slots.length,
      rate: (details['rate'] as num?)?.toDouble(),
      credits: (details['credits'] as num?)?.toDouble(),
      cheapest: details['cheapest'] == true,
      startedAt: at(details['startedAt']),
      finishedAt: at(details['finishedAt']),
    );
  }

  final String model;
  final String size;
  final String prompt;
  final List<ImageSlot> slots;
  final int asked;
  final double? rate;
  final double? credits;
  final bool cheapest;
  final DateTime? startedAt;
  final DateTime? finishedAt;

  int get done => slots.where((s) => s.status == ImageSlotStatus.done).length;
  bool get running => slots.any((s) => s.status == ImageSlotStatus.running);

  /// Width over height of the pictures, from the size ("1536x1024" -> 1.5); square when it cannot be read.
  double get aspect {
    final m = RegExp(r'^(\d+)x(\d+)$').firstMatch(size);
    if (m == null) return 1;
    final w = int.parse(m[1]!), h = int.parse(m[2]!);
    return w > 0 && h > 0 ? w / h : 1;
  }
}

/// A picture a tool returned, decoded once.
typedef ToolImage = ({Uint8List bytes, String mimeType});

/// Pictures a card shows at most; a result with more says how many there were.
const maxToolImages = 4;

/// The pictures in a tool result's [content] (`{type: image, data: <base64>, mimeType}` blocks). Blocks that do not
/// decode are skipped.
List<ToolImage> contentImageData(dynamic content) {
  if (content is! List) return const [];
  final out = <ToolImage>[];
  for (final c in content.whereType<Map>()) {
    if (c['type'] != 'image' || c['data'] is! String) continue;
    try {
      out.add((bytes: base64Decode(c['data'] as String), mimeType: c['mimeType'] as String? ?? 'image/png'));
    } on FormatException {
      continue;
    }
    if (out.length == maxToolImages) break;
  }
  return out;
}

String contentText(dynamic content) {
  if (content is String) return content;
  if (content is List) {
    return content.whereType<Map>().where((c) => c['type'] == 'text').map((c) => c['text'] as String? ?? '').join('\n');
  }
  return '';
}

/// One reading of pictures by the vision translator, as the host adds it to the user's turn.
class VisionRead {
  const VisionRead({required this.model, required this.name, required this.kind, this.credits});
  final String model;
  final String name;

  /// full (the pictures of this message) or targeted (a detail of an earlier one, for a question about it).
  final String kind;
  final double? credits;
}

final _visionBlock = RegExp(r'\n*<griphub-vision\b([^>]*)>[\s\S]*?</griphub-vision>');
final _visionAttr = RegExp(r'(\w+)="([^"]*)"');

String _unescapeAttr(String v) =>
    v.replaceAll('&quot;', '"').replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&amp;', '&');

/// A user message's text split into what the user wrote and the readings the host added to it.
(String, List<VisionRead>) splitVisionReads(String text) {
  if (!text.contains('<griphub-vision')) return (text, const []);
  final reads = <VisionRead>[];
  for (final m in _visionBlock.allMatches(text)) {
    final a = {for (final x in _visionAttr.allMatches(m.group(1) ?? '')) x.group(1)!: _unescapeAttr(x.group(2)!)};
    reads.add(
      VisionRead(
        model: a['model'] ?? '',
        name: a['name'] ?? a['model'] ?? '',
        kind: a['kind'] ?? 'full',
        credits: double.tryParse(a['credits'] ?? ''),
      ),
    );
  }
  return (text.replaceAll(_visionBlock, '').trimRight(), reads);
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
    'background_job' => pick(['label', 'command']),
    'generate_image' => pick(['prompt']),
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

/// One model request: its tokens as pi reports them, and the host's GripHub estimate for it
/// (agent/src/pricing.ts messageCost; [credits] null when the price is unknown or it went to another provider).
class RequestUsage {
  const RequestUsage({
    this.input = 0,
    this.output = 0,
    this.cacheRead = 0,
    this.cacheWrite = 0,
    this.credits,
    this.floored = false,
  });

  final int input;
  final int output;
  final int cacheRead;
  final int cacheWrite;
  final double? credits;

  /// Billed at the model's per-request minimum.
  final bool floored;

  static RequestUsage? fromMessage(Map<String, dynamic> message) {
    final u = message['usage'];
    if (u is! Map) return null;
    int n(Object? v) => (v as num?)?.toInt() ?? 0;
    final cost = message['griphubCost'];
    return RequestUsage(
      input: n(u['input']),
      output: n(u['output']),
      cacheRead: n(u['cacheRead']),
      cacheWrite: n(u['cacheWrite']),
      credits: cost is Map ? (cost['credits'] as num?)?.toDouble() : null,
      floored: cost is Map && cost['floored'] == true,
    );
  }
}

/// What a whole turn cost: every model request from the user's message to the final answer, summed.
/// Subagents the turn started are counted apart (their cards carry their own cost).
class TurnCost {
  TurnCost(Iterable<RequestUsage> requests, {this.subagentCalls = const []}) {
    var unknown = false;
    var credits = 0.0;
    for (final r in requests) {
      this.requests++;
      if (r.floored) floored++;
      input += r.input;
      output += r.output;
      cacheRead += r.cacheRead;
      cacheWrite += r.cacheWrite;
      if (r.credits == null) {
        unknown = true;
      } else {
        credits += r.credits!;
      }
    }
    // One request of unknown price makes the total unknown: never a made-up number.
    this.credits = unknown || this.requests == 0 ? null : credits;
  }

  int requests = 0;
  int floored = 0;
  int input = 0;
  int output = 0;
  int cacheRead = 0;
  int cacheWrite = 0;
  late final double? credits;

  /// Tool call ids of the subagents this turn started.
  final List<String> subagentCalls;

  int get tokens => input + output + cacheRead + cacheWrite;
  int get cached => cacheRead + cacheWrite;
}

/// How a turn ended: its clock in the footer says so, not just how long it ran.
enum TurnOutcome { done, stopped, failed }

/// What the copy-and-model footer under an assistant reply shows, with how long the turn took when known.
typedef TurnFooter = ({String text, String? model, TurnCost? cost, Duration? took, TurnOutcome outcome});

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
    final turn = entries.sublist(start, end).whereType<AssistantEntry>();
    final requests = [for (final e in turn) ?e.usage];
    out[tail] = (
      text: _replyText(answer),
      model: lastEntry.model ?? answer.model,
      took: lastEntry.turnMs == null ? null : Duration(milliseconds: lastEntry.turnMs!),
      // A turn that was stopped or died on an error must not get the green "Done": say what happened instead.
      outcome: lastEntry.aborted
          ? TurnOutcome.stopped
          : lastEntry.error != null
          ? TurnOutcome.failed
          : TurnOutcome.done,
      cost: requests.isEmpty
          ? null
          : TurnCost(
              requests,
              subagentCalls: [
                for (final e in turn)
                  for (final b in e.orderedBlocks)
                    if (b.kind == BlockKind.toolCall && b.toolName == 'subagent' && b.toolCallId != null) b.toolCallId!,
              ],
            ),
    );
  }

  for (var i = 0; i < entries.length; i++) {
    // A background job's result starts a turn too: the agent goes on with it without a message from the user.
    if (entries[i] is UserEntry || entries[i] is JobEntry) {
      close(i, last: false);
      start = i + 1;
    }
  }
  close(entries.length, last: true);
  return out;
}

/// Tokens the running turn has used so far: its finished model requests since the last user message (or job result).
int turnTokensSoFar(List<ChatEntry> entries) {
  var tokens = 0;
  for (final e in entries.reversed) {
    if (e is UserEntry || e is JobEntry) break;
    final u = e is AssistantEntry ? e.usage : null;
    if (u != null) tokens += u.input + u.output + u.cacheRead + u.cacheWrite;
  }
  return tokens;
}

String _replyText(AssistantEntry e) => [
  for (final b in e.orderedBlocks)
    if (b.kind == BlockKind.text && b.text.trim().isNotEmpty) b.text.trim(),
].join('\n\n');

/// A follow-up sent while the agent works, waiting for the turn's boundary.
class QueuedPrompt {
  QueuedPrompt(Map<String, dynamic> j)
    : id = j['id'] as String? ?? '',
      text = j['text'] as String? ?? '',
      images = (j['images'] as num?)?.toInt() ?? 0;
  final String id;
  final String text;
  final int images;
}

/// The smart router's state for the open chat (agent/src/smartrouter.ts): whether Settings allow it, whether this chat
/// picks its model automatically, and the class floor earlier failures raised it to.
class SmartRouterState {
  const SmartRouterState({this.enabled = false, this.auto = false, this.floor = 0});
  factory SmartRouterState.fromJson(Map<String, dynamic>? j) => j == null
      ? const SmartRouterState()
      : SmartRouterState(
          enabled: j['enabled'] == true,
          auto: j['auto'] == true,
          floor: (j['floor'] as num?)?.toInt() ?? 0,
        );
  final bool enabled;
  final bool auto;
  final int floor;
}

/// One entry of a chat's routing log: a model picked for a turn, a class climbed, nothing fitting, a hand pick.
class RoutingDecision {
  RoutingDecision(Map<String, dynamic> j)
    : at = DateTime.fromMillisecondsSinceEpoch((j['at'] as num?)?.toInt() ?? 0),
      turn = (j['turn'] as num?)?.toInt() ?? 0,
      kind = j['kind'] as String? ?? 'route',
      model = j['model'] as String?,
      modelName = j['modelName'] as String?,
      band = (j['band'] as num?)?.toInt(),
      difficulty = (j['difficulty'] as num?)?.toInt(),
      reason = j['reason'] as String? ?? '',
      why = (j['why'] as List? ?? const []).whereType<String>().toList(),
      estimate = (j['estimate'] as num?)?.toDouble();
  final DateTime at;

  /// User turns before the one this decision was for: the first message of a chat is turn 0.
  final int turn;

  /// route, none, escalate, manual, on, off or fallback.
  final String kind;
  final String? model;
  final String? modelName;
  final int? band;
  final int? difficulty;
  final String reason;

  /// The reason as codes (agent/src/smartrouter.ts Decision.why), worded by the app.
  final List<String> why;
  final double? estimate;
}

/// The host asks before a paid reading of a picture (Settings → Vision translator → Ask first): which model would read
/// it, and about what it would cost.
class VisionAsk {
  VisionAsk(Map<String, dynamic> j)
    : model = j['model'] as String? ?? '',
      modelName = j['modelName'] as String? ?? j['model'] as String? ?? '',
      estimate = (j['estimate'] as num?)?.toDouble();
  final String model;
  final String modelName;
  final double? estimate;
}

/// A chat shown read-only while the open chat works (Fitur 8): read from its file (host `session_read`), never opened
/// on the host, so the chat at work stays the only one. A chat not started yet ([isNew]) waits the same way.
class ChatView {
  ChatView.chat(String this.path) : newDir = null, newChatMode = false;
  ChatView.newChat({this.newDir, this.newChatMode = false}) : path = null, loaded = true;

  /// The chat's file; null for a new chat that starts once the agent is free.
  final String? path;
  final String? newDir;
  final bool newChatMode;
  bool get isNew => path == null;

  String? sessionId;
  String? name;
  bool isChat = false;
  bool loaded = false;
  Object? error;
  final entries = <ChatEntry>[];
  final tools = <String, ToolRun>{};

  /// What its draft is kept under: the chat's id once known (as when it is open), else its file or new-chat key.
  String get key => sessionId ?? path ?? 'new:${newChatMode ? 'chat' : newDir ?? ''}';

  /// Its title, as the open chat's: a name, else the first message.
  String get title {
    if (name != null && name!.trim().isNotEmpty) return name!;
    final first = entries.whereType<UserEntry>().firstOrNull?.text.trim();
    return first == null || first.isEmpty ? 'New chat' : first.split('\n').first;
  }
}

/// The last verification evidence in the turn that entry [i] ends (from the turn's user message, or job result, to
/// [i]); null when the turn has none.
VerifyEntry? lastVerifyOfTurn(List<ChatEntry> entries, int i) {
  for (var k = i; k >= 0; k--) {
    final e = entries[k];
    if (e is VerifyEntry) return e;
    if (e is UserEntry || e is JobEntry) return null;
  }
  return null;
}

/// A fact in the agent's memory (agent/src/memory.ts).
class MemoryEntry {
  MemoryEntry(Map<String, dynamic> j)
    : id = j['id'] as String? ?? '',
      text = j['text'] as String? ?? '',
      source = j['source'] as String? ?? '',
      sessionId = j['sessionId'] as String?,
      createdAt = j['createdAt'] as String? ?? '',
      confirmedAt = j['confirmedAt'] as String? ?? '',
      replaced = (j['replaced'] as List? ?? const []).whereType<String>().toList();
  final String id;
  final String text;
  final String source;
  final String? sessionId;
  final String createdAt;
  final String confirmedAt;
  final List<String> replaced;
}

/// The agent proposed to remember something; the user decides.
class MemoryProposal {
  MemoryProposal(Map<String, dynamic> j)
    : id = j['id'] as String? ?? '',
      text = j['text'] as String? ?? '',
      layer = j['layer'] as String? ?? 'global',
      project = j['project'] as String?,
      replacesText = j['replacesText'] as String?,
      status = j['status'] as String? ?? 'pending';
  final String id;
  final String text;
  final String layer;
  final String? project;
  final String? replacesText;

  /// pending, saved or rejected.
  final String status;
}

/// What a chat started with from memory.
class MemorySnapshotInfo {
  MemorySnapshotInfo(Map<String, dynamic> j)
    : global = [for (final e in (j['global'] as List? ?? const [])) ((e as Map)['text'] as String? ?? '')],
      project = [for (final e in (j['project'] as List? ?? const [])) ((e as Map)['text'] as String? ?? '')],
      projectPath = j['projectPath'] as String?,
      left = (j['left'] as num?)?.toInt() ?? 0;
  final List<String> global;
  final List<String> project;
  final String? projectPath;

  /// Facts left out to stay within the budget.
  final int left;
  bool get isEmpty => global.isEmpty && project.isEmpty;
}
