// The chat's turn footer (copy + model) and markdown tables.
import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/ui/code_view.dart';
import 'package:griphub_agent/ui/message_views.dart';

import 'harness.dart';

AssistantEntry assistant(String? text, {bool tool = false, String model = 'claude-opus-5.5', bool streaming = false}) {
  final e = AssistantEntry()..streaming = streaming;
  e.model = model;
  var i = 0;
  if (text != null) e.block(i++, BlockKind.text).text = text;
  if (tool) {
    final b = e.block(i++, BlockKind.toolCall);
    b.toolCallId = 'call-$i-${text.hashCode}';
    b.toolName = 'bash';
    b.args = {'command': 'ls -la'};
  }
  return e;
}

const table = '''
## Prioritas tinggi

| # | Masalah | Lokasi | Effort |
|---|---|---|---|
| 1 | **Folder picker tidak memuat isi folder yang diketuk.** Path di atas berubah, tapi daftar masih menampilkan isi folder sebelumnya. | `folder_picker.dart:285` (`setState(() => _dir = d)`) | S, cukup ganti jadi `_open(d)` |
| 2 | Tombol kirim antrean tidak terlihat | `subagent_card.dart` | XS |
''';

Future<void> frames(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() => layoutErrors.clear());

  group('turn footer', () {
    final turn = <ChatEntry>[
      UserEntry('pahami codebase'),
      assistant('Direktori saat ini adalah home.', tool: true),
      assistant('Proyek utamanya adalah griphub. Mari saya telusuri.', tool: true),
      assistant(null, tool: true),
      assistant('Ini ringkasannya: aplikasi Flutter dengan host Node.', model: 'claude-sonnet-5'),
      UserEntry('lanjut'),
      assistant('Oke, lanjut.', tool: true),
    ];

    test('only under the last message of a finished turn, copying its final answer', () {
      final f = turnFooters(turn, busy: true);
      expect(f.keys, [4], reason: 'the second turn is still running');
      expect(f[4]!.text, 'Ini ringkasannya: aplikasi Flutter dengan host Node.');
      expect(f[4]!.model, 'claude-sonnet-5');
      final done = turnFooters(turn, busy: false);
      expect(done.keys, [4, 6]);
    });

    test('a turn whose last step has no text copies the last text and sits under the last step', () {
      final t = <ChatEntry>[UserEntry('a'), assistant('Jawaban.'), assistant(null, tool: true, model: 'gpt-6-sol')];
      final f = turnFooters(t, busy: false);
      expect(f.keys, [2]);
      expect(f[2], (text: 'Jawaban.', model: 'gpt-6-sol', cost: null));
    });

    test('nothing while a message still streams, nothing for a turn without text', () {
      expect(turnFooters([UserEntry('a'), assistant('x', streaming: true)], busy: false), isEmpty);
      expect(turnFooters([UserEntry('a'), assistant(null, tool: true)], busy: false), isEmpty);
    });

    testWidgets('golden: a multi-step turn shows one footer at the end', (tester) async {
      FakeHost();
      final footers = turnFooters(turn.take(5).toList(), busy: false);
      await pumpLook(
        tester,
        const Look(dark: true),
        Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (var i = 0; i < 5; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: switch (turn[i]) {
                    final UserEntry u => UserMessageView(u),
                    final AssistantEntry a => AssistantMessageView(a, tools: const {}, footer: footers[i]),
                    _ => const SizedBox.shrink(),
                  },
                ),
            ],
          ),
        ),
        height: 900,
      );
      expect(find.byType(CopyButton), findsOneWidget);
      expect(layoutErrors, isEmpty);
      await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('chat_turn_footer')));
    });
  });

  testWidgets('message text is still selectable (one selection area)', (tester) async {
    FakeHost();
    await pumpLook(tester, const Look(), const Scaffold(body: Padding(padding: EdgeInsets.all(16), child: MarkdownText('Halo **dunia**.\n\nParagraf kedua.'))), height: 400);
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(find.byType(SelectableText), findsNothing);
  });

  group('markdown tables', () {
    for (final look in const [Look(dark: true), Look(language: 'id', textScale: 1.3, width: 320)]) {
      testWidgets('wide table scrolls sideways instead of squeezing ${look.name}', (tester) async {
        FakeHost();
        await pumpLook(
          tester,
          look,
          const Scaffold(body: SingleChildScrollView(padding: EdgeInsets.all(16), child: MarkdownText(table))),
          height: 900,
        );
        await frames(tester);
        expect(layoutErrors, isEmpty);
        // A horizontal scroller wraps the table, and the table is wider than the screen.
        final scroller = find.ancestor(of: find.byType(Table), matching: find.byType(SingleChildScrollView)).first;
        expect(tester.widget<SingleChildScrollView>(scroller).scrollDirection, Axis.horizontal);
        expect(tester.getSize(find.byType(Table)).width, greaterThan(look.width - 32));
        // The prose column wraps at a readable width, not one word per line.
        final masalah = tester.getSize(
          find.ancestor(of: find.textContaining('Folder picker', findRichText: true), matching: find.byType(TableCell)).first,
        );
        expect(masalah.width, greaterThan(200));
        await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('markdown_table_${look.name}')));
        // A sideways swipe scrolls it, even though the text is selectable.
        final scrollable = tester.state<ScrollableState>(
          find.descendant(of: scroller, matching: find.byType(Scrollable)).first,
        );
        expect(scrollable.position.maxScrollExtent, greaterThan(0));
        // Touch a cell's text inside the screen (the table's centre is off to the
        // right): text used to claim the drag for selection, so nothing scrolled.
        final start = tester.getCenter(find.textContaining('Masalah', findRichText: true).first);
        final g = await tester.startGesture(start, kind: PointerDeviceKind.touch);
        for (var i = 0; i < 10; i++) {
          await g.moveBy(const Offset(-25, 0));
          await tester.pump(const Duration(milliseconds: 16));
        }
        await g.up();
        await frames(tester);
        // ignore: avoid_print
        print('SCROLL ${look.name} pixels=${scrollable.position.pixels} max=${scrollable.position.maxScrollExtent}');
        expect(scrollable.position.pixels, greaterThan(0));
      });
    }

    testWidgets('a small table stays put, no scrolling needed', (tester) async {
      FakeHost();
      await pumpLook(
        tester,
        const Look(),
        const Scaffold(body: Padding(padding: EdgeInsets.all(16), child: MarkdownText('| A | B |\n|---|---|\n| 1 | 2 |'))),
        height: 300,
      );
      expect(tester.getSize(find.byType(Table)).width, lessThan(200));
      final scrollable = tester.state<ScrollableState>(
        find.descendant(of: find.byType(SingleChildScrollView), matching: find.byType(Scrollable)).first,
      );
      expect(scrollable.position.maxScrollExtent, 0);
    });
  });
}
