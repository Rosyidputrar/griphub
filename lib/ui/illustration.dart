import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'kit.dart';
import 'theme.dart';

/// Storyset illustrations (https://storyset.com, free with attribution),
/// recoloured from their default blue to the app accent.
class Illustration extends StatelessWidget {
  const Illustration(this.name, {super.key, this.height = 220});
  final String name;
  final double height;

  static const _storysetBlue = '#407bff';
  /// Recoloured SVGs already read, by name and accent. The text is kept, not the read in progress: a read that never
  /// finished (the screen went away, or in tests the zone it was started in ended) would otherwise be waited on forever
  /// by every later picture of the same name.
  static final _cache = <String, String>{};

  static String _hex(Color c) => '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

  String _key(Color accent) => '$name/${accent.toARGB32()}';

  Future<String> _load(Color accent) => rootBundle
      .loadString('assets/illustrations/$name.svg')
      .then((svg) => _cache[_key(accent)] = svg.replaceAll(RegExp(_storysetBlue, caseSensitive: false), _hex(accent)));

  @override
  Widget build(BuildContext context) {
    final accent = context.palette.accent;
    final known = _cache[_key(accent)];
    return SizedBox(
      height: height,
      child: known != null
          ? SvgPicture.string(known, height: height, fit: BoxFit.contain)
          : FutureBuilder<String>(
              future: _load(accent),
              builder: (context, snap) =>
                  snap.hasData ? SvgPicture.string(snap.data!, height: height, fit: BoxFit.contain) : const SizedBox.shrink(),
            ),
    );
  }
}

/// The credit Storyset's licence asks for.
class StorysetCredit extends StatelessWidget {
  const StorysetCredit({super.key, required this.openUrl});
  final Future<void> Function(String url) openUrl;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    // An 11 px line to read, a 48 dp target to tap, and a link to a screen reader.
    return Semantics(
      link: true,
      label: 'Illustrations by Storyset',
      onTap: () => openUrl('https://storyset.com'),
      excludeSemantics: true,
      child: TapTarget(
      onTap: () => openUrl('https://storyset.com'),
      child: Text.rich(
        TextSpan(
          style: TextStyle(fontSize: 11, color: p.faint),
          children: [
            const TextSpan(text: 'Illustrations by '),
            TextSpan(
              text: 'Storyset',
              style: TextStyle(color: p.muted, decoration: TextDecoration.underline, decorationColor: p.faint),
            ),
          ],
        ),
      ),
    ),
    );
  }
}
