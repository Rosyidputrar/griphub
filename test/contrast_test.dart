// Colour contrast (UI audit): text must read at 4.5:1 or better (WCAG AA for normal text).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/ui/code_view.dart';
import 'package:griphub_agent/ui/theme.dart';

double contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('UI-21: small contrast shortfalls', smallContrastTests);
  group('accent as text', accentTextTests);
  test('UI-08: text on a danger fill reads in both themes (white on the dark red was 2.9:1)', () {
    for (final (name, p) in [('light', Palette.light), ('dark', Palette.dark)]) {
      expect(contrast(p.onDanger, p.danger), greaterThanOrEqualTo(4.5), reason: '$name: ${contrast(p.onDanger, p.danger)}');
    }
    expect(contrast(Colors.white, Palette.dark.danger), lessThan(4.5), reason: 'the old white really did fail (so the check means something)');
  });

  test('UI-08: no danger-filled button picks white by hand any more', () {
    final offenders = <String>[];
    for (final f in Directory('lib/ui').listSync().whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final text = f.readAsStringSync();
      if (RegExp(r'backgroundColor: (?:p|context\.palette)\.danger,\s*foregroundColor: Colors\.white').hasMatch(text)) offenders.add(f.path);
    }
    expect(offenders, isEmpty);
  });
}

void accentTextTests() {
  test('UI-09: every accent choice reads as text on the page and on a card, in both themes', () {
    for (var i = 0; i < accentChoices.length; i++) {
      for (final (name, base, fill) in [('light', Palette.light, accentChoices[i].$1), ('dark', Palette.dark, accentChoices[i].$2)]) {
        final p = base.copyWith(accent: fill);
        for (final (where, bg) in [('page', p.bg), ('card', p.surface)]) {
          expect(contrast(p.accentText, bg), greaterThanOrEqualTo(4.5), reason: '${accentNames[i]} $name on the $where: ${contrast(p.accentText, bg).toStringAsFixed(2)}');
        }
      }
    }
  });

  test('UI-09: text buttons and links in the accent use the text accent', () {
    final offenders = <String>[];
    for (final f in Directory('lib/ui').listSync().whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final lines = f.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        // A text button's foreground, or a text style's colour, set to the fill accent.
        if (RegExp(r'foregroundColor: (?:p|context\.palette)\.accent\b(?!Text|Alt)|TextStyle\([^)]*color: (?:p|context\.palette)\.accent\b(?!Text|Alt)|copyWith\(color: (?:p|context\.palette)\.accent\b(?!Text|Alt)').hasMatch(lines[i])) {
          offenders.add('${f.path}:${i + 1}');
        }
      }
    }
    expect(offenders, isEmpty);
  });

  test('UI-09: an accent that already reads is used as it is, and only the text colour changes', () {
    final violet = Palette.light.copyWith(accent: accentChoices[0].$1);
    expect(violet.accentText, violet.accent, reason: 'violet passes as it is');
    final green = Palette.light.copyWith(accent: accentChoices[2].$1);
    expect(contrast(green.accent, Palette.light.bg), lessThan(4.5), reason: 'green really did fail as text');
    expect(green.accentText, isNot(green.accent));
    expect(HSLColor.fromColor(green.accentText).hue, closeTo(HSLColor.fromColor(green.accent).hue, 1), reason: 'still green, only darker');
  });
}


void smallContrastTests() {
  test('UI-21: a pill\'s text reads on its tint over a card, in both themes, whatever its colour', () {
    for (final (name, p) in [('light', Palette.light), ('dark', Palette.dark)]) {
      for (final c in [p.danger, p.warning, p.success, p.accent, p.accentAlt, p.muted]) {
        final bg = Color.alphaBlend(c.withValues(alpha: 0.12), p.surface);
        expect(contrast(readableOn(c, bg), bg), greaterThanOrEqualTo(4.5), reason: '$name $c');
      }
    }
    final p = Palette.light;
    final dangerBg = Color.alphaBlend(p.danger.withValues(alpha: 0.12), p.surface);
    expect(contrast(p.danger, dangerBg), lessThan(4.5), reason: 'the plain colour really fell short');
  });

  test('UI-21: white or ink on a solid tile, whichever reads (white on amber was 2.2:1)', () {
    for (final fill in const [Color(0xFFF59E0B), Color(0xFF14B8A6), Color(0xFFFF7A1A), Color(0xFF0EA5E9), Color(0xFF6E56CF), Color(0xFF111113)]) {
      expect(contrast(onFill(fill), fill), greaterThanOrEqualTo(4.5), reason: '$fill');
    }
    expect(onFill(const Color(0xFF6E56CF)), Colors.white, reason: 'a dark fill keeps white');
  });

  test('UI-21: the light theme\'s code comments read on a card', () {
    final comment = syntaxColors(Brightness.light)['comment']!;
    expect(contrast(comment, Palette.light.surface), greaterThanOrEqualTo(4.5));
  });
}
