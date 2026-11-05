// Which mark a model gets (lib/ui/model_logo.dart): every model GripHub Router lists today has the right family, an id
// that is nobody's gets none rather than a wrong one, and every mark the map names is a real asset that decodes.
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/ui/model_logo.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The ids the router's model-status listed on 2026-11-05 (agent/test/fixtures/model-status.json has a cut of them),
  // with the family a person would say each belongs to.
  const expected = <String, String?>{
    'claude-fable-5': 'claude', 'claude-fable-5.1': 'claude', 'claude-haiku-4.5': 'claude', 'claude-haiku-5.5': 'claude',
    'claude-opus-4.5': 'claude', 'claude-opus-4.8': 'claude', 'claude-opus-5': 'claude', 'claude-opus-5.5': 'claude',
    'claude-sonnet-4.6': 'claude', 'claude-sonnet-5.5': 'claude',
    'deepseek-v4-flash': 'deepseek', 'deepseek-v4-pro': 'deepseek', 'deepseek-v4.1-flash': 'deepseek',
    'gemini-3.8-flash': 'gemini', 'gemini-4-argon': 'gemini', 'gemini-3.1-flash-image': 'gemini',
    'glm-5.2': 'glm', 'glm-5.3': 'glm', 'glm-5.3-flash': 'glm', 'glm-5.3-flashx': 'glm',
    'gpt-5.6-luna': 'openai', 'gpt-5.6-sol': 'openai', 'gpt-6-astra-ultrafast': 'openai', 'gpt-6.1-terra': 'openai',
    'gpt-image': 'openai',
    'grok-4.6': 'xai', 'grok-4.7': 'xai',
    'hy3': 'tencent', 'hy4': 'tencent',
    'kimi-k2.6': 'kimi', 'kimi-k2.7': 'kimi', 'kimi-k3': 'kimi', 'kimi-k3.1-pro': 'kimi',
    'mimo-v2.6-flash': 'mimo', 'mimo-v2.6-pro': 'mimo',
    'minimax-m3': 'minimax', 'minimax-m3.1-flash': 'minimax', 'minimax-m2.7': 'minimax',
    'muse-spark-1.2': 'meta', 'muse-spark-1.3': 'meta', 'muse-wonder-1.0': 'meta',
    'qwen-3.8-flash': 'qwen', 'qwen-3.8-max': 'qwen',
  };

  test('every model the router lists belongs to the right family', () {
    final wrong = <String>[];
    expected.forEach((id, family) {
      if (modelFamily(id) != family) wrong.add('$id: ${modelFamily(id)} (want $family)');
    });
    expect(wrong, isEmpty);
  });

  test('the catalog on file lists no model this map has never heard of', () {
    final status = jsonDecode(File('agent/test/fixtures/model-status.json').readAsStringSync()) as Map;
    final unknown = [
      for (final m in (status['models'] as List).cast<Map>())
        if (modelFamily(m['model'] as String) == null) m['model'],
    ];
    expect(unknown, isEmpty);
  });

  test('a provider id, a "provider/model" key and the odd casing resolve too', () {
    expect(modelFamily('anthropic'), 'claude');
    expect(modelFamily('openai-codex'), 'openai');
    expect(modelFamily('google-vertex'), 'gemini');
    expect(modelFamily('griphub/claude-opus-5.5'), 'claude');
    expect(modelFamily('GRIPHUB/GPT-6-Luna'), 'openai');
    expect(modelFamily('  Kimi-K3  '), 'kimi');
    expect(modelFamily('o3-mini'), 'openai');
    expect(modelFamily('o4'), 'openai');
    expect(modelFamily('xai'), 'xai');
    expect(modelFamily('meta-llama-3'), 'meta');
  });

  test('nothing is claimed for what is nobody\'s here', () {
    // Prefixes must be whole words: "hybrid" is not Hy, "ogpt" is not GPT, "metadata" is not Meta, "glmx" is not GLM.
    for (final id in ['', 'griphub', 'ollama', 'llama.cpp', 'llama-cpp-local', 'local', 'bedrock', 'mistral', 'hybrid-1', 'ogpt', 'metadata-x', 'glmx', 'xaix', 'unknown-model', 'o', 'o33']) {
      expect(modelFamily(id), isNull, reason: '"$id"');
    }
    expect(logoFor('mistral'), isNull);
  });

  test('a family without a mark of its own (MiMo) is named but has no tile', () {
    expect(modelFamily('mimo-v2.6-flash'), 'mimo');
    expect(logoFor('mimo-v2.6-flash'), isNull, reason: 'the wordmark is unreadable in a small tile; Xiaomi\'s own mark stands in');
  });

  test('the white marks have an ink twin for the light theme, the coloured ones do not', () {
    for (final id in ['gpt-6-luna', 'glm-5.3', 'kimi-k3', 'grok-4.7']) {
      final logo = logoFor(id)!;
      expect(logo.ink, isTrue, reason: id);
      expect(logo.asset(dark: true), isNot(endsWith('_light.png')));
      expect(logo.asset(dark: false), endsWith('_light.png'));
    }
    for (final id in ['claude-opus-5', 'gemini-4-argon', 'deepseek-v4-pro', 'minimax-m3', 'qwen-3.8-max', 'muse-spark-1.3', 'hy4']) {
      final logo = logoFor(id)!;
      expect(logo.ink, isFalse, reason: id);
      expect(logo.asset(dark: false), logo.asset(dark: true), reason: id);
    }
  });

  test('every mark the map can hand out is a PNG in the bundle, small, with the twins that go with it', () async {
    final manifest = await rootBundle.loadStructuredBinaryData('AssetManifest.bin', (d) => const StandardMessageCodec().decodeMessage(d)) as Map;
    final files = Directory('assets/providers').listSync().whereType<File>().map((f) => f.uri.pathSegments.last).toSet();
    final used = <String>{};
    for (final id in expected.keys) {
      final logo = logoFor(id);
      if (logo == null) continue;
      for (final dark in [true, false]) {
        used.add(logo.asset(dark: dark));
      }
    }
    for (final asset in used) {
      expect(manifest.containsKey(asset), isTrue, reason: '$asset is not declared in pubspec.yaml');
      final bytes = File(asset).readAsBytesSync();
      expect(bytes.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], reason: '$asset is a PNG');
      expect(bytes.length, lessThan(16 * 1024), reason: '$asset is cut down for a 20 to 36 px tile');
      final codec = await instantiateImageCodec(bytes);
      final frame = (await codec.getNextFrame()).image;
      expect([frame.width, frame.height], [128, 128], reason: asset);
    }
    // Nothing in the folder that no mark uses (a leftover would ship in every APK).
    expect(files.difference(used.map((a) => a.split('/').last).toSet()), isEmpty);
  });
}
