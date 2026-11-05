// The model status screen (lib/ui/model_board_screen.dart): which models work now (the router's status, with the
// user's own key) and which are used most (its public ranking). The data is what the host sends: the agent's own
// parsers run over the router's real responses (test/fixtures), so a golden here shows real model names and numbers.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/ui/energy.dart';
import 'package:griphub_agent/ui/model_board_screen.dart';
import 'package:griphub_agent/ui/model_logo.dart';
import 'package:griphub_agent/ui/model_sheet.dart';

import 'harness.dart';

const _looks = [Look(), Look(dark: true, language: 'id'), Look(language: 'id', textScale: 1.3, width: 320)];

Future<void> frames(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Map<String, dynamic> _fixture(String name) => (jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map).cast<String, dynamic>();

/// A FakeHost answering the two commands the way the host does, and remembering what was asked.
class _Board {
  _Board() {
    host = FakeHost();
    host.answers['model_status'] = (c) {
      statusAsked.add('${c['window']}${c['force'] == true ? '!' : ''}');
      if (statusFails != null) return HostError(statusFails!);
      return {..._fixture('served-status.json'), 'board': {..._fixture('served-status.json')['board'] as Map, 'window': c['window']}};
    };
    host.answers['model_rank'] = (c) {
      rankAsked.add('${c['period']}${c['force'] == true ? '!' : ''}');
      if (rankFails != null) return HostError(rankFails!);
      return {..._fixture('served-rank.json'), 'board': {..._fixture('served-rank.json')['board'] as Map, 'period': c['period']}};
    };
  }
  late final FakeHost host;
  final statusAsked = <String>[];
  final rankAsked = <String>[];
  String? statusFails;
  String? rankFails;
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() {
    applyLook(const Look());
    layoutErrors.clear();
  });

  Future<_Board> open(WidgetTester tester, Look look, {BoardTab tab = BoardTab.status, void Function(_Board)? before, double height = 1500}) async {
    final b = _Board();
    before?.call(b);
    await pumpLook(tester, look, ModelBoardScreen(agent: newAgent(), tab: tab), height: height);
    await frames(tester, 10);
    // The marks are pictures from the bundle: wait for them, or a golden shows empty tiles on some runs.
    await loadImages(tester);
    await tester.pump(const Duration(milliseconds: 100));
    return b;
  }

  for (final look in _looks) {
    testWidgets('golden: status, with the failing models first (${look.name})', (tester) async {
      await open(tester, look);
      expect(layoutErrors, isEmpty);
      await expectLater(find.byType(ModelBoardScreen), matchesGoldenFile(golden('model_status_${look.name}')));
    });

    testWidgets('golden: ranking (${look.name})', (tester) async {
      await open(tester, look, tab: BoardTab.rank);
      expect(layoutErrors, isEmpty);
      await expectLater(find.byType(ModelBoardScreen), matchesGoldenFile(golden('model_rank_${look.name}')));
    });
  }

  // The model sheet: the same ids the router lists, each with its maker's mark (GripHub serves every family under one
  // provider, so the model id says whose it is).
  // Some with what the router sends (window, output, price, a promo) and some bare, as a custom provider's are: both
  // must line the name up with the mark, the star and the check.
  ModelInfo model(String id, String name, {bool details = false}) => ModelInfo({
    'provider': 'griphub',
    'id': id,
    'name': name,
    'input': const ['text'],
    if (details) ...{
      'contextWindow': 200000,
      'maxTokens': 64000,
      'reasoning': true,
      'pricing': {'credits': 5, 'floor': 0.1, 'available': true},
    },
  });
  final sheetModels = [
    model('claude-opus-5.5', 'Claude Opus 5.5', details: true),
    model('gpt-6-luna', 'GPT 6 Luna', details: true),
    model('gemini-4-argon', 'Gemini 4 Argon', details: true),
    model('deepseek-v4.1-flash', 'DeepSeek V4.1 Flash'),
    model('glm-5.3', 'GLM 5.3'),
    model('kimi-k3', 'Kimi K3'),
    model('muse-spark-1.3', 'Muse Spark 1.3'),
    model('hy4', 'Hy4'),
    model('minimax-m3', 'MiniMax M3'),
    model('qwen-3.8-flash', 'Qwen 3.8 Flash'),
    model('grok-4.7', 'Grok 4.7'),
    model('mimo-v2.6-flash', 'MiMo V2.6'),
    model('some-new-model', 'Some new model'),
  ];

  for (final look in _looks) {
    testWidgets('golden: the model sheet shows each model\'s mark (${look.name})', (tester) async {
      final host = FakeHost();
      host.answers['providers'] = (_) => const [];
      host.answers['models'] = (_) => [for (final m in sheetModels) m.json];
      final agent = newAgent()
        ..model = sheetModels.first
        ..models = sheetModels;
      await pumpLook(
        tester,
        look,
        Scaffold(body: Builder(builder: (c) => Center(child: TextButton(onPressed: () => showModelSheet(c, agent), child: const Text('open'))))),
        height: 1500,
      );
      await tester.tap(find.text('open'));
      await frames(tester, 14);
      await loadImages(tester);
      await sheetSettles(tester);
      await tester.pump(const Duration(milliseconds: 100));
      expect(layoutErrors, isEmpty);
      await expectLater(find.byType(BottomSheet), matchesGoldenFile(golden('model_sheet_marks_${look.name}')));
    });
  }

  testWidgets('the model sheet: a row with nothing under its name is one line, the name level with the mark', (tester) async {
    final host = FakeHost();
    host.answers['providers'] = (_) => const [];
    host.answers['models'] = (_) => [for (final m in sheetModels) m.json];
    final agent = newAgent()
      ..model = sheetModels.first
      ..models = sheetModels;
    await pumpLook(
      tester,
      const Look(),
      Scaffold(body: Builder(builder: (c) => Center(child: TextButton(onPressed: () => showModelSheet(c, agent), child: const Text('open'))))),
      height: 1500,
    );
    await tester.tap(find.text('open'));
    await frames(tester, 14);
    await sheetSettles(tester);
    double offset(String name) {
      final tile = find.ancestor(of: find.text(name), matching: find.byType(ListTile));
      final mark = find.descendant(of: tile, matching: find.byType(ModelLogoTile));
      final row = find.descendant(of: tile, matching: find.byType(IconButton));
      final centre = tester.getCenter(mark).dy;
      expect((tester.getCenter(row.first).dy - centre).abs(), lessThan(1), reason: '$name: the star is level with the mark');
      return tester.getCenter(find.text(name)).dy - centre;
    }
    // Bare: the name's centre is the mark's. (It sat about 12 dp above before.)
    expect(offset('Kimi K3').abs(), lessThan(1));
    expect(offset('Hy4').abs(), lessThan(1));
    // With details under it the name is above the middle, the usual two-line row, and the mark is centred on both lines.
    expect(offset('Claude Opus 5.5'), lessThan(-6));
  });

  testWidgets('the model sheet: a known family gets its mark, MiMo and an unknown model a neutral tile, never a wrong mark', (tester) async {
    final host = FakeHost();
    host.answers['providers'] = (_) => const [];
    host.answers['models'] = (_) => [for (final m in sheetModels) m.json];
    final agent = newAgent()
      ..model = sheetModels.first
      ..models = sheetModels;
    await pumpLook(
      tester,
      const Look(),
      Scaffold(body: Builder(builder: (c) => Center(child: TextButton(onPressed: () => showModelSheet(c, agent), child: const Text('open'))))),
      height: 1500,
    );
    await tester.tap(find.text('open'));
    await frames(tester, 14);
    await sheetSettles(tester);
    String? markOf(String name) {
      final tile = find.ancestor(of: find.text(name), matching: find.byType(ListTile));
      final image = find.descendant(of: tile, matching: find.byType(Image));
      if (image.evaluate().isEmpty) return null;
      return ((image.evaluate().single.widget as Image).image as AssetImage).assetName;
    }
    expect(markOf('Claude Opus 5.5'), 'assets/providers/claude.png');
    expect(markOf('GPT 6 Luna'), 'assets/providers/openai_light.png', reason: 'drawn in white: its ink twin on the light theme');
    expect(markOf('Muse Spark 1.3'), 'assets/providers/meta.png', reason: 'Muse is Meta\'s');
    expect(markOf('Hy4'), 'assets/providers/tencent.png');
    expect(markOf('Grok 4.7'), 'assets/providers/xai_light.png');
    expect(markOf('MiMo V2.6'), isNull, reason: 'its mark is a wordmark; Xiaomi\'s own glyph stands in');
    expect(markOf('Some new model'), isNull, reason: 'a model nobody has a mark for gets a neutral tile, not another maker\'s');
    expect(find.byType(ModelLogoTile), findsAtLeastNWidgets(10));
  });

  testWidgets('status: the summary, the models that matter first, the quiet ones behind a button', (tester) async {
    final b = await open(tester, const Look());
    expect(b.statusAsked, ['24h']);
    expect(find.text('Model status'), findsOneWidget);
    expect(find.textContaining('requests · 98%'), findsOneWidget);
    // Down and degraded come before healthy ones.
    final luna = tester.getTopLeft(find.text('GPT 5.6 Luna')).dy;
    final opus = tester.getTopLeft(find.text('Claude Opus 5.5')).dy;
    final grok = tester.getTopLeft(find.text('Grok 4.7')).dy;
    expect(luna, lessThan(opus));
    expect(grok, lessThan(opus), reason: 'down, though the router says it is not active');
    expect(find.text('Slow or failing'), findsWidgets);
    expect(find.text('Down'), findsWidgets);
    // A quiet, idle model is behind the button until asked for.
    expect(find.text('Grok 4.6'), findsNothing);
    // 13 of the 15 models are worth a line; the 2 quiet and idle ones are behind a button at the end of the list.
    final more = find.text('Show 2 more');
    await tester.scrollUntilVisible(more, 300, scrollable: find.byType(Scrollable).last);
    await tester.tap(more);
    await frames(tester);
    await tester.scrollUntilVisible(find.text('Grok 4.6'), 300, scrollable: find.byType(Scrollable).last);
    expect(find.text('Grok 4.6'), findsOneWidget);
    final fewer = find.text('Show only models in use');
    await tester.scrollUntilVisible(fewer, 300, scrollable: find.byType(Scrollable).last);
    await tester.tap(fewer);
    await frames(tester);
    expect(find.text('Grok 4.6'), findsNothing);
  });

  testWidgets('status: a model opens its numbers, and a missing one reads as a dash, not 0', (tester) async {
    await open(tester, const Look());
    await tester.tap(find.text('GPT 5.6 Luna'));
    await frames(tester, 12);
    expect(find.text('Typical wait'), findsOneWidget);
    expect(find.text('Empty answer'), findsOneWidget);
    // Down + unused: its figures say "—" where the router sent null.
    await tester.tap(find.text('Grok 4.7'));
    await frames(tester, 12);
    expect(find.text('Typical wait'), findsNWidgets(2));
    // Collapsing again hides it.
    await tester.tap(find.text('GPT 5.6 Luna'));
    await frames(tester, 12);
    expect(find.text('Typical wait'), findsOneWidget);
    expect(layoutErrors, isEmpty);
  });

  testWidgets('status: another window asks for that window, and its numbers never sit under the old tab', (tester) async {
    final b = await open(tester, const Look());
    await tester.tap(find.text('7d'));
    await frames(tester, 12);
    expect(b.statusAsked, ['24h', '7d']);
    await tester.tap(find.text('6h'));
    await frames(tester, 12);
    expect(b.statusAsked, ['24h', '7d', '6h']);
    // Same window again: nothing new is asked.
    await tester.tap(find.text('6h'));
    await frames(tester);
    expect(b.statusAsked, hasLength(3));
  });

  testWidgets('status: a slow answer for the window left behind cannot replace the window now shown', (tester) async {
    final late = Completer<Object?>();
    final b = await open(tester, const Look(), before: (b) {
      final fast = b.host.answers['model_status']!;
      b.host.answers['model_status'] = (c) {
        if (c['window'] != '24h') return fast(c);
        b.statusAsked.add('24h');
        return late.future;
      };
    });
    // 24h is still on its way: the spinner is up. The user moves on to 7d, which answers at once.
    expect(find.text('GPT 5.6 Luna'), findsNothing);
    await tester.tap(find.text('7d'));
    await frames(tester, 12);
    expect(find.text('GPT 5.6 Luna'), findsOneWidget);
    // Then 24h comes in, late, with numbers that are plainly not 7d's.
    final old = _fixture('served-status.json');
    (old['board'] as Map)['window'] = '24h';
    ((old['board'] as Map)['summary'] as Map)['up'] = 777;
    late.complete(old);
    await frames(tester, 12);
    expect(find.text('777'), findsNothing, reason: "24h's answer arrived after 7d was chosen");
    expect(find.text('34'), findsOneWidget);
    expect(b.statusAsked, ['24h', '7d']);
  });

  testWidgets('ranking: the same, for a period left behind', (tester) async {
    final late = Completer<Object?>();
    await open(tester, const Look(), tab: BoardTab.rank, before: (b) {
      final fast = b.host.answers['model_rank']!;
      b.host.answers['model_rank'] = (c) => c['period'] == '7d' ? late.future : fast(c);
    });
    await tester.tap(find.text('30d'));
    await frames(tester, 12);
    expect(find.text('Deepseek V4.1 Flash'), findsOneWidget);
    final old = _fixture('served-rank.json');
    ((old['board'] as Map)['rows'] as List).first['name'] = 'FROM THE OLD PERIOD';
    late.complete(old);
    await frames(tester, 12);
    expect(find.text('FROM THE OLD PERIOD'), findsNothing);
    expect(find.text('Deepseek V4.1 Flash'), findsOneWidget);
  });

  testWidgets('status: while another window loads, the old window\'s numbers are not left under the new tab', (tester) async {
    final late = Completer<Object?>();
    await open(tester, const Look(), before: (b) {
      final fast = b.host.answers['model_status']!;
      b.host.answers['model_status'] = (c) => c['window'] == '7d' ? late.future : fast(c);
    });
    expect(find.text('GPT 5.6 Luna'), findsOneWidget);
    await tester.tap(find.text('7d'));
    await frames(tester, 6);
    expect(find.text('GPT 5.6 Luna'), findsNothing, reason: "24h's list under the 7d tab would be 24h's numbers with 7d's label");
    expect(find.text('34'), findsNothing);
    expect(find.byType(EnergySpinner), findsWidgets);
    final fresh = _fixture('served-status.json');
    (fresh['board'] as Map)['window'] = '7d';
    late.complete(fresh);
    await frames(tester, 12);
    expect(find.text('GPT 5.6 Luna'), findsOneWidget);
  });

  testWidgets('ranking: the same while another period loads', (tester) async {
    final late = Completer<Object?>();
    await open(tester, const Look(), tab: BoardTab.rank, before: (b) {
      final fast = b.host.answers['model_rank']!;
      b.host.answers['model_rank'] = (c) => c['period'] == '30d' ? late.future : fast(c);
    });
    expect(find.text('Deepseek V4.1 Flash'), findsOneWidget);
    await tester.tap(find.text('30d'));
    await frames(tester, 6);
    expect(find.text('Deepseek V4.1 Flash'), findsNothing);
    late.complete({..._fixture('served-rank.json'), 'board': {..._fixture('served-rank.json')['board'] as Map, 'period': '30d'}});
    await frames(tester, 12);
    expect(find.text('Deepseek V4.1 Flash'), findsOneWidget);
  });

  testWidgets('status: pulling down asks again with force', (tester) async {
    final b = await open(tester, const Look());
    await tester.fling(find.byType(Scrollable).last, const Offset(0, 400), 1000);
    await frames(tester, 30);
    expect(b.statusAsked, ['24h', '24h!']);
  });

  testWidgets('status: with no key the host\'s sentence is shown, with a way to try again', (tester) async {
    final b = await open(tester, const Look(), before: (b) => b.statusFails = 'No GripHub key saved');
    expect(find.text('No GripHub key saved'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('GPT 5.6 Luna'), findsNothing, reason: 'no board, so no models');
    b.statusFails = null;
    await tester.tap(find.text('Try again'));
    await frames(tester, 12);
    expect(find.text('GPT 5.6 Luna'), findsOneWidget);
  });

  testWidgets('status: a stale copy says so, with when it is from, and keeps showing the models', (tester) async {
    await open(tester, const Look(), before: (b) {
      b.host.answers['model_status'] = (c) => {..._fixture('served-status.json'), 'stale': true, 'error': 'GripHub Router: boom (500)'};
    });
    expect(find.textContaining('Showing the copy from'), findsOneWidget);
    expect(find.textContaining('boom (500)'), findsOneWidget);
    expect(find.text('GPT 5.6 Luna'), findsOneWidget);
  });

  testWidgets('status: the bars carry a text for a screen reader, and the model a state it can say', (tester) async {
    final handle = tester.ensureSemantics();
    await open(tester, const Look());
    // One sentence per model, with its bars in words, read as a button that says whether it is open.
    final luna = tester.getSemantics(find.bySemanticsLabel(RegExp(r'^GPT 5\.6 Luna, Slow or failing, 99\.4% succeeded, 48 bars: 2 failed, 4 partly$')));
    expect(luna, isSemantics(isButton: true, hasTapAction: true, hasExpandedState: true, isExpanded: false));
    expect(find.bySemanticsLabel(RegExp(r'^Grok 4\.7, Down, 10\.1% succeeded, not in use, 48 bars: 0 failed, 47 partly$|^Grok 4\.7, Down, 10\.1% succeeded, not in use, 48 bars: 47 failed, 0 partly$')), findsOneWidget);
    await tester.tap(find.text('GPT 5.6 Luna'));
    await frames(tester, 12);
    expect(tester.getSemantics(find.bySemanticsLabel(RegExp(r'^GPT 5\.6 Luna, Slow or failing'))), isSemantics(isExpanded: true, isButton: true, hasTapAction: true, hasExpandedState: true));
    // The ranking's rows are one sentence too, with their place.
    await tester.tap(find.text('Ranking'));
    await frames(tester, 12);
    expect(find.bySemanticsLabel(RegExp(r'^1\. Deepseek V4\.1 Flash, 29\.5B tokens, 268k requests$')), findsOneWidget);
    handle.dispose();
  });

  testWidgets('ranking: models by tokens with their share, the image model apart and counted in pictures', (tester) async {
    final b = await open(tester, const Look(), tab: BoardTab.rank);
    expect(b.rankAsked, ['7d']);
    final top = tester.getTopLeft(find.text('Deepseek V4.1 Flash')).dy;
    final second = tester.getTopLeft(find.text('claude-opus-5.5').evaluate().isEmpty ? find.text('Claude Opus 5.5') : find.text('claude-opus-5.5')).dy;
    expect(top, lessThan(second));
    expect(find.text('IMAGE MODELS'), findsOneWidget);
    expect(find.textContaining('215 images'), findsOneWidget);
    expect(find.textContaining('not how good it is'), findsOneWidget, reason: 'popularity, said plainly, is not quality');
    // A model the router never named shows its id instead of a blank.
    expect(find.text('minimax-m2.7'), findsOneWidget);
    expect(layoutErrors, isEmpty);
  });

  testWidgets('ranking: a period asks for that period', (tester) async {
    final b = await open(tester, const Look(), tab: BoardTab.rank);
    for (final label in ['14d', '30d', 'All', '24h']) {
      await tester.tap(find.text(label));
      await frames(tester, 12);
    }
    expect(b.rankAsked, ['7d', '14d', '30d', 'all', '24h']);
  });

  testWidgets('the tabs switch without asking again, and both boards are asked for once at the start', (tester) async {
    final b = await open(tester, const Look());
    expect(b.rankAsked, ['7d'], reason: 'the other tab is ready when it is opened');
    await tester.tap(find.text('Ranking'));
    await frames(tester, 12);
    await tester.tap(find.text('Status'));
    await frames(tester, 12);
    expect([b.statusAsked.length, b.rankAsked.length], [1, 1]);
  });

  testWidgets('a rank failure leaves the status tab alone', (tester) async {
    await open(tester, const Look(), before: (b) => b.rankFails = 'GripHub Router: down (503)');
    expect(find.text('GPT 5.6 Luna'), findsOneWidget);
    await tester.tap(find.text('Ranking'));
    await frames(tester, 12);
    expect(find.textContaining('down (503)'), findsOneWidget);
  });

  testWidgets('the numbers read in Indonesian: decimal comma, translated labels', (tester) async {
    await open(tester, const Look(language: 'id'));
    expect(find.text('Status model'), findsOneWidget);
    expect(find.text('Lambat atau gagal'), findsWidgets);
    expect(find.text('Mati'), findsWidgets);
    expect(find.textContaining('permintaan · 98%'), findsOneWidget);
    await tester.tap(find.text('GPT 5.6 Luna'));
    await frames(tester, 12);
    expect(find.text('Waktu tunggu umum'), findsOneWidget);
    expect(find.textContaining(' dtk'), findsWidgets, reason: 'seconds in Indonesian');
  });

  test('every text on the screen has an Indonesian line', () {
    final src = File('lib/ui/model_board_screen.dart').readAsStringSync();
    final i18n = File('lib/ui/i18n.dart').readAsStringSync();
    final keys = {
      for (final m in RegExp(r"tr\(\s*'((?:[^'\\]|\\.)*)'\s*\)").allMatches(src)) m.group(1)!.replaceAll(r"\'", "'"),
      for (final m in RegExp(r"=> tr\('((?:[^'\\]|\\.)*)'\)").allMatches(src)) m.group(1)!.replaceAll(r"\'", "'"),
    };
    final missing = [
      for (final k in keys)
        if (!i18n.contains("'${k.replaceAll("'", r"\'")}':") && !i18n.contains('"$k":')) k,
    ];
    expect(missing, isEmpty);
    expect(keys.length, greaterThan(30));
  });
}
