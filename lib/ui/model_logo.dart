import 'package:flutter/material.dart';

import 'theme.dart';

/// The mark of the company behind a model, as GripHub Router shows it (assets/providers/, cut to 128 px).
/// [file] is the asset's base name; [ink] marks the ones drawn in white, which have a `_light` twin (the same
/// mark with its white turned to ink) for the light theme.
class ModelLogo {
  const ModelLogo(this.file, {this.ink = false});
  final String file;
  final bool ink;

  /// The asset to draw on a [dark] or light surface.
  String asset({required bool dark}) => 'assets/providers/$file${ink && !dark ? '_light' : ''}.png';
}

/// Every mark there is, by the family it stands for. The order is the order the keys are tried in.
const _marks = <String, ModelLogo>{
  'claude': ModelLogo('claude'),
  'openai': ModelLogo('openai', ink: true),
  'gemini': ModelLogo('gemini'),
  'deepseek': ModelLogo('deepseek'),
  'glm': ModelLogo('glm', ink: true),
  'kimi': ModelLogo('kimi', ink: true),
  'minimax': ModelLogo('minimax'),
  'qwen': ModelLogo('qwen'),
  'meta': ModelLogo('meta'),
  'xai': ModelLogo('xai', ink: true),
  'tencent': ModelLogo('tencent'),
  // Xiaomi MiMo has no entry: the router's mark for it is a two-line wordmark, unreadable in a 20 to 36 px tile.
  // It keeps the Xiaomi mark from Simple Icons (kit.dart providerBrand), which is why [modelFamily] still names it.
};

/// Which family a model id or a provider id belongs to, or null for none that has a mark here.
///
/// The router names its models after their family ("claude-opus-5.5", "gpt-6-luna", "muse-spark-1.3"), and some
/// families are somebody else's: Muse is Meta's, Hy is Tencent's, GPT is OpenAI's, Grok is xAI's. Provider ids
/// ("anthropic", "openai-codex") go through the same rules; an id with no match gets no mark, never a wrong one.
String? modelFamily(String id) {
  var k = id.toLowerCase().trim();
  // "griphub/claude-opus-5.5" and the like: the model is after the last slash.
  final slash = k.lastIndexOf('/');
  if (slash >= 0) k = k.substring(slash + 1);
  bool starts(String p) => k == p || k.startsWith('$p-') || k.startsWith('$p.') || k.startsWith('$p:') || k.startsWith('${p}_');
  if (starts('claude') || starts('anthropic')) return 'claude';
  if (starts('gpt') || starts('openai') || starts('codex') || starts('azure') || RegExp(r'^o\d(-|$)').hasMatch(k) || starts('chatgpt')) {
    return 'openai';
  }
  if (starts('gemini') || starts('google') || starts('vertex') || starts('gemma')) return 'gemini';
  if (starts('deepseek')) return 'deepseek';
  if (starts('glm') || starts('zai') || starts('zhipu')) return 'glm';
  if (starts('kimi') || starts('moonshot')) return 'kimi';
  if (starts('minimax')) return 'minimax';
  if (starts('qwen') || starts('alibaba') || starts('dashscope')) return 'qwen';
  // A local llama.cpp server is a runtime, not Meta's.
  if (k.startsWith('llama.cpp') || k.startsWith('llama-cpp')) return null;
  if (starts('muse') || starts('meta') || starts('llama')) return 'meta';
  if (starts('grok') || starts('xai')) return 'xai';
  if (starts('hy') || RegExp(r'^hy\d').hasMatch(k) || starts('hunyuan') || starts('tencent')) return 'tencent';
  if (starts('mimo') || starts('xiaomi')) return 'mimo';
  return null;
}

/// The mark for [id] (a model id or a provider id), or null (the caller then falls back to the provider's own mark).
ModelLogo? logoFor(String id) => _marks[modelFamily(id)];

/// A model's mark on a soft tile, the size of an [IconTile].
class ModelLogoTile extends StatelessWidget {
  const ModelLogoTile({super.key, required this.logo, this.size = 36});
  final ModelLogo logo;
  final double size;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final pad = size * 0.2;
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(pad),
      decoration: BoxDecoration(
        color: p.raised,
        borderRadius: BorderRadius.circular(size * 0.3),
        border: Border.all(color: p.border),
      ),
      child: Image.asset(
        logo.asset(dark: dark),
        fit: BoxFit.contain,
        filterQuality: FilterQuality.medium,
        // The mark is decoration beside the model's name; a screen reader gets the name.
        excludeFromSemantics: true,
        // A missing or broken asset must never take the row down with it.
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      ),
    );
  }
}
