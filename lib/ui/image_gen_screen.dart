import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_client.dart';
import '../agent/agent_controller.dart';
import '../agent/models.dart';
import 'griphub_screen.dart';
import 'i18n.dart';
import 'kit.dart';
import 'theme.dart';

/// Image generation through GripHub Router's OpenAI-compatible Images API.
///
/// The API key never touches this layer: the on-device host calls
/// `POST {base}/images/generations` with the saved GripHub key and returns
/// the base64 PNG. Generation takes 20–120s and is billed only on success,
/// so there is no auto-retry: a timed-out request may already have produced
/// (and billed) an image server-side.
class ImageGenScreen extends StatefulWidget {
  const ImageGenScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<ImageGenScreen> createState() => _ImageGenScreenState();
}

const _models = ['gpt-image', 'gemini-3.1-flash-image'];
const _sizes = [
  ('1024x1024', '1024 × 1024', 1.0),
  ('1536x1024', '1536 × 1024', 1.5),
  ('1024x1536', '1024 × 1536', 2 / 3),
];

class _HistoryItem {
  _HistoryItem({required this.file, required this.prompt, required this.model, required this.size, required this.created});
  final String file;
  final String prompt;
  final String model;
  final String size;
  final int created;

  Map<String, dynamic> get json => {'file': file, 'prompt': prompt, 'model': model, 'size': size, 'created': created};

  static _HistoryItem? fromJson(Map<String, dynamic> j) {
    final file = j['file'];
    if (file is! String) return null;
    return _HistoryItem(
      file: file,
      prompt: j['prompt'] as String? ?? '',
      model: j['model'] as String? ?? '',
      size: j['size'] as String? ?? '',
      created: j['created'] as int? ?? 0,
    );
  }
}

class _ImageGenScreenState extends State<ImageGenScreen> {
  final _prompt = TextEditingController();
  final _customModel = TextEditingController();
  String _model = _models.first;
  bool _custom = false;
  String _size = _sizes.first.$1;
  bool _busy = false;
  bool _loading = true;
  bool _hasKey = false;
  String? _error;
  Uint8List? _result;
  String? _resultFile;
  int _elapsed = 0;
  Timer? _timer;
  List<_HistoryItem> _history = [];

  AgentController get agent => widget.agent;

  String? get _agentDir {
    final d = agent.info['agentDir'];
    return d is String && d.isNotEmpty ? d : null;
  }

  Directory? get _imagesDir {
    final d = _agentDir;
    return d == null ? null : Directory('$d/images');
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _prompt.dispose();
    _customModel.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    List<CustomProvider> providers = const [];
    try {
      providers = await agent.customProviders();
    } catch (_) {
      providers = const [];
    }
    await _loadHistory();
    if (mounted) {
      setState(() {
        _hasKey = providers.any((p) => p.id == 'griphub' && p.hasKey);
        _loading = false;
      });
    }
  }

  Future<void> _loadHistory() async {
    final dir = _imagesDir;
    if (dir == null) return;
    try {
      final index = File('${dir.path}/index.json');
      if (!await index.exists()) return;
      final raw = jsonDecode(await index.readAsString());
      final items = <_HistoryItem>[];
      if (raw is List) {
        for (final e in raw) {
          if (e is Map) {
            final item = _HistoryItem.fromJson(e.cast<String, dynamic>());
            if (item != null && await File('${dir.path}/${item.file}').exists()) items.add(item);
          }
        }
      }
      items.sort((a, b) => b.created.compareTo(a.created));
      _history = items;
    } catch (_) {
      _history = [];
    }
  }

  Future<void> _saveHistoryIndex() async {
    final dir = _imagesDir;
    if (dir == null) return;
    try {
      await dir.create(recursive: true);
      await File('${dir.path}/index.json').writeAsString(jsonEncode([for (final h in _history) h.json]));
    } catch (_) {}
  }

  String _elapsedLabel() {
    final m = (_elapsed ~/ 60).toString().padLeft(2, '0');
    final s = (_elapsed % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String get _effectiveModel => _custom ? _customModel.text.trim() : _model;

  double get _aspect {
    for (final s in _sizes) {
      if (s.$1 == _size) return s.$3;
    }
    return 1.0;
  }

  Future<void> _generate() async {
    final prompt = _prompt.text.trim();
    final model = _effectiveModel;
    if (prompt.isEmpty) {
      setState(() => _error = tr('Describe the image first.'));
      return;
    }
    if (model.isEmpty) {
      setState(() => _error = tr('Pick a model first.'));
      return;
    }
    FocusScope.of(context).unfocus();
    _timer?.cancel();
    setState(() {
      _busy = true;
      _error = null;
      _result = null;
      _resultFile = null;
      _elapsed = 0;
    });
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _elapsed++);
    });
    try {
      final data = await agent.client.call<Map<String, dynamic>>('custom_provider_images_generate', {
        'model': model,
        'prompt': prompt,
        'size': _size,
      });
      final b64 = data['b64_json'];
      if (b64 is! String || b64.isEmpty) throw AgentError(tr('The endpoint returned no image data'));
      final bytes = base64Decode(b64);
      String? file;
      final dir = _imagesDir;
      if (dir != null) {
        try {
          await dir.create(recursive: true);
          final name = '${DateTime.now().millisecondsSinceEpoch}.png';
          await File('${dir.path}/$name').writeAsBytes(bytes);
          file = name;
          _history.insert(0, _HistoryItem(file: name, prompt: prompt, model: model, size: _size, created: DateTime.now().millisecondsSinceEpoch));
          while (_history.length > 30) {
            final old = _history.removeLast();
            try {
              await File('${dir.path}/${old.file}').delete();
            } catch (_) {}
          }
          await _saveHistoryIndex();
        } catch (_) {
          file = null;
        }
      }
      if (mounted) {
        setState(() {
          _result = bytes;
          _resultFile = file;
        });
      }
    } on AgentError catch (e) {
      if (mounted) setState(() => _error = _readable(e.message));
    } catch (e) {
      if (mounted) setState(() => _error = _readable(e.toString()));
    } finally {
      _timer?.cancel();
      if (mounted) setState(() => _busy = false);
    }
  }

  String _readable(String message) {
    if (message.contains('401')) return tr('The API key was rejected. Check the key in GripHub settings.');
    if (message.contains('404')) return tr('The image endpoint is not available for this provider.');
    if (message.toLowerCase().contains('timeout') || message.toLowerCase().contains('timed out')) {
      return tr('Taking longer than 3 minutes. The image may still have been created; try again in a moment.');
    }
    return message;
  }

  Future<String?> _writeTemp(Uint8List bytes, String name) async {
    final dir = _imagesDir;
    final target = dir ?? Directory.systemTemp;
    try {
      await target.create(recursive: true);
      final path = '${target.path}/$name';
      await File(path).writeAsBytes(bytes);
      return path;
    } catch (_) {
      return null;
    }
  }

  Future<void> _saveToDownloads(String path) async {
    try {
      final landed = await agent.client.saveToDownloads(path);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${tr('Saved to')} $landed')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr('Could not save the image.'))));
    }
  }

  Future<void> _share(String path) async {
    try {
      await agent.client.shareFile(path);
    } catch (_) {}
  }

  Future<void> _openHistory(_HistoryItem item) async {
    final dir = _imagesDir;
    if (dir == null) return;
    final file = File('${dir.path}/${item.file}');
    Uint8List? bytes;
    try {
      bytes = await file.readAsBytes();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        contentPadding: const EdgeInsets.all(12),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(borderRadius: BorderRadius.circular(Radii.lg), child: Image.memory(bytes!)),
              const SizedBox(height: 12),
              Text(item.prompt, style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 4),
              Text('${item.model} · ${item.size}', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: context.palette.muted)),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await _saveToDownloads(file.path);
            },
            child: Text(tr('Save')),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await _share(file.path);
            },
            child: Text(tr('Share')),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop();
              try {
                await file.delete();
              } catch (_) {}
              setState(() => _history.removeWhere((h) => h.file == item.file));
              await _saveHistoryIndex();
            },
            child: Text(tr('Delete'), style: TextStyle(color: context.palette.danger)),
          ),
          TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(tr('Close'))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      appBar: AppBar(
        title: Text(tr('Generate image')),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
              children: [
                if (!_hasKey) ...[
                  SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(tr('Connect GripHub first'), style: text.titleMedium),
                        const SizedBox(height: 6),
                        Text(
                          tr('Image generation uses the same GripHub API key as chat. Add it once, then come back here.'),
                          style: text.bodyMedium?.copyWith(color: p.muted),
                        ),
                        const SizedBox(height: 14),
                        PrimaryButton(
                          label: tr('Add API key'),
                          icon: LucideIcons.keyRound,
                          onPressed: () async {
                            final ok = await Navigator.of(context).push<bool>(
                              MaterialPageRoute(builder: (_) => GripHubScreen(agent: agent)),
                            );
                            if (ok == true) _load();
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 22),
                ],
                Text(tr('Prompt'), style: text.titleSmall),
                const SizedBox(height: 8),
                TextField(
                  controller: _prompt,
                  minLines: 3,
                  maxLines: 6,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: InputDecoration(
                    hintText: tr('A blue paper plane, flat icon'),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.lg)),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  tr('Generation takes 20–120 seconds. You are billed per image, only when it succeeds.'),
                  style: text.bodySmall?.copyWith(color: p.muted),
                ),
                const SizedBox(height: 20),
                Text(tr('Model'), style: text.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final m in _models)
                      _OptionChip(
                        label: m,
                        selected: !_custom && _model == m,
                        onTap: _busy
                            ? null
                            : () => setState(() {
                                  _model = m;
                                  _custom = false;
                                }),
                      ),
                    _OptionChip(
                      label: tr('Custom'),
                      selected: _custom,
                      onTap: _busy ? null : () => setState(() => _custom = true),
                    ),
                  ],
                ),
                if (_custom) ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: _customModel,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: const TextStyle(fontFamily: mono, fontSize: 13),
                    decoration: InputDecoration(
                      labelText: tr('Model id'),
                      hintText: 'gpt-image',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(Radii.lg)),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                Text(tr('Size'), style: text.titleSmall),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final s in _sizes)
                      _OptionChip(
                        label: s.$2,
                        selected: _size == s.$1,
                        onTap: _busy ? null : () => setState(() => _size = s.$1),
                      ),
                  ],
                ),
                const SizedBox(height: 22),
                PrimaryButton(
                  label: tr('Generate image'),
                  icon: LucideIcons.image,
                  busy: _busy,
                  onPressed: (_busy || !_hasKey) ? null : () => _generate(),
                ),
                if (_busy) ...[
                  const SizedBox(height: 14),
                  const LinearProgressIndicator(),
                  const SizedBox(height: 8),
                  Text(
                    '${_elapsedLabel()} · ${tr('Generating… this usually takes 20–120 seconds.')}',
                    style: text.bodySmall?.copyWith(color: p.muted),
                  ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: text.bodySmall?.copyWith(color: p.danger)),
                ],
                if (_result != null) ...[
                  const SizedBox(height: 22),
                  SurfaceCard(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        AspectRatio(
                          aspectRatio: _aspect,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(Radii.lg),
                            child: Image.memory(_result!, fit: BoxFit.cover),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () async {
                                  final path = _resultFile != null && _imagesDir != null
                                      ? '${_imagesDir!.path}/$_resultFile'
                                      : await _writeTemp(_result!, 'griphub-image.png');
                                  if (path != null) await _saveToDownloads(path);
                                },
                                icon: const Icon(LucideIcons.download, size: 16),
                                label: Text(tr('Save')),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton.icon(
                                onPressed: () async {
                                  final path = _resultFile != null && _imagesDir != null
                                      ? '${_imagesDir!.path}/$_resultFile'
                                      : await _writeTemp(_result!, 'griphub-image.png');
                                  if (path != null) await _share(path);
                                },
                                icon: const Icon(LucideIcons.share2, size: 16),
                                label: Text(tr('Share')),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
                if (_history.isNotEmpty) ...[
                  SectionLabel(tr('History')),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 3,
                      crossAxisSpacing: 8,
                      mainAxisSpacing: 8,
                    ),
                    itemCount: _history.length,
                    itemBuilder: (context, i) {
                      final item = _history[i];
                      final dir = _imagesDir;
                      if (dir == null) return const SizedBox.shrink();
                      return GestureDetector(
                        onTap: () => _openHistory(item),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(Radii.md),
                          child: Image.file(
                            File('${dir.path}/${item.file}'),
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Container(color: p.surface),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ],
            ),
    );
  }
}

class _OptionChip extends StatelessWidget {
  const _OptionChip({required this.label, required this.selected, required this.onTap});
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Material(
      color: selected ? p.accent : p.surface,
      borderRadius: BorderRadius.circular(Radii.pill),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.pill),
        // Hugs its label: with alignment set, the Container grew to the Wrap's full width and every
        // option filled a row of its own.
        child: Container(
          height: 44,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontFamily: mono,
                  fontSize: 13,
                  color: selected ? p.onAccent : p.text,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
