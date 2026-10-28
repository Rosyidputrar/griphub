// Chat features: thinking preview, tappable links with the leave-the-app
// confirmation and trusted domains, and follow-ups waiting for their turn.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/agent/sent_attachments.dart';
import 'package:griphub_agent/ui/links.dart';
import 'package:griphub_agent/ui/message_views.dart';
import 'package:griphub_agent/ui/theme.dart';

import 'harness.dart';

Future<void> frames(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

final opened = <String>[];

String thought(int n) => [for (var i = 1; i <= n; i++) 'Langkah $i: memeriksa bagian ke-$i dari kode.'].join('\n');

void main() {
  setUpAll(loadAppFonts);
  setUp(() {
    layoutErrors.clear();
    opened.clear();
    externalUrlOpener = (u) async => opened.add(u);
    Appearance.instance.trustedDomains = [];
  });

  group('linkify', () {
    test('finds links, trims sentence punctuation and unopened brackets', () {
      expect(linkify('lihat https://github.com/a/b.'), [('lihat ', null), ('https://github.com/a/b', 'https://github.com/a/b'), ('.', null)]);
      expect(linkify('(docs: https://x.dev/a_(b))')[1].$2, 'https://x.dev/a_(b)');
      expect(linkify('(https://x.dev/a)').map((e) => e.$1).toList(), ['(', 'https://x.dev/a', ')']);
      expect(linkify('buka www.example.com, ya')[1], ('www.example.com', 'https://www.example.com'));
      expect(linkify('tanpa link'), [('tanpa link', null)]);
    });

    test('only http(s), mailto and tel can be opened', () {
      expect(openableUri('https://a.b/c'), isNotNull);
      expect(openableUri('mailto:x@y.z'), isNotNull);
      expect(openableUri('javascript:alert(1)'), isNull);
      expect(openableUri('file:///etc/passwd'), isNull);
      expect(openableUri('intent://scan#Intent;end'), isNull);
      expect(openableUri('https://'), isNull);
    });
  });

  group('opening links', () {
    Future<void> pumpText(WidgetTester tester, Widget child, {Look look = const Look()}) async {
      FakeHost();
      await pumpLook(tester, look, Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: child)), height: 700);
      await frames(tester);
    }

    testWidgets('a link in the user bubble asks first; Always trust skips the question next time', (tester) async {
      await pumpText(tester, const UserBubble('cek https://github.com/Rosyidputrar/griphub ya'));
      await tester.tapAt(tester.getTopLeft(find.byType(UserBubble)) + const Offset(80, 22));
      await frames(tester);
      expect(find.byType(LinkConfirmDialog), findsOneWidget);
      expect(find.text('github.\u200Bcom'), findsOneWidget);
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      await tester.tap(find.text('Open'));
      await frames(tester);
      expect(opened, ['https://github.com/Rosyidputrar/griphub']);
      expect(Appearance.instance.trustedDomains, ['github.com']);
      await tester.tapAt(tester.getTopLeft(find.byType(UserBubble)) + const Offset(80, 22));
      await frames(tester);
      expect(find.byType(LinkConfirmDialog), findsNothing, reason: 'trusted: opens directly');
      expect(opened, hasLength(2));
    });

    testWidgets('AI reply: markdown links and bare URLs are tappable; Cancel opens nothing', (tester) async {
      await pumpText(tester, const MarkdownText('Dokumentasi: https://docs.flutter.dev/ui dan [repo](https://github.com/x).'));
      await tester.tap(find.textContaining('docs.flutter.dev', findRichText: true).first);
      await frames(tester);
      expect(find.byType(LinkConfirmDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await frames(tester);
      expect(opened, isEmpty);
      expect(Appearance.instance.trustedDomains, isEmpty);
    });

    testWidgets('link text naming another domain is called out', (tester) async {
      FakeHost();
      await pumpLook(
        tester,
        const Look(),
        const Scaffold(body: Center(child: LinkConfirmDialog(url: 'https://evil.example/login', host: 'evil.example', mismatchHost: 'bca.co.id'))),
      );
      expect(find.textContaining('bca.co.id'), findsOneWidget);
      expect(layoutErrors, isEmpty);
      await expectLater(find.byType(LinkConfirmDialog), matchesGoldenFile(golden('dialog_link_mismatch')));
    });

    for (final look in const [Look(), Look(dark: true, language: 'id', textScale: 1.3, width: 320)]) {
      testWidgets('golden: leave-the-app dialog ${look.name}', (tester) async {
        FakeHost();
        await pumpLook(
          tester,
          look,
          const Scaffold(body: Center(child: LinkConfirmDialog(url: 'https://griphubrouter.web.id/portal?ref=app', host: 'griphubrouter.web.id'))),
        );
        await frames(tester);
        expect(layoutErrors, isEmpty);
        // A long domain wraps at its dots, never mid-word.
        final para = tester.renderObject<RenderParagraph>(find.text('griphubrouter.\u200Bweb.\u200Bid'));
        final t = para.text.toPlainText();
        final lines = para.getBoxesForSelection(TextSelection(baseOffset: 0, extentOffset: t.length));
        // Each new line starts right after a break opportunity.
        var lastTop = lines.first.top;
        for (var i = 1; i < t.length; i++) {
          final box = para.getBoxesForSelection(TextSelection(baseOffset: i, extentOffset: i + 1));
          if (box.isEmpty) continue;
          if (box.first.top > lastTop + 1) {
            expect(t[i - 1], '\u200B', reason: 'line broke inside a label at $i');
            lastTop = box.first.top;
          }
        }
        await expectLater(find.byType(LinkConfirmDialog), matchesGoldenFile(golden('dialog_link_${look.name}')));
      });
    }

    testWidgets('golden: trusted domains in Settings, removable with undo', (tester) async {
      FakeHost();
      Appearance.instance.trustedDomains = ['docs.flutter.dev', 'github.com'];
      await pumpLook(tester, const Look(), const TrustedDomainsScreen(), height: 600);
      await frames(tester);
      await expectLater(find.byType(TrustedDomainsScreen), matchesGoldenFile(golden('trusted_domains')));
      await tester.tap(find.byTooltip('Remove').first);
      await frames(tester);
      expect(Appearance.instance.trustedDomains, ['github.com']);
      await tester.tap(find.text('Undo'));
      await frames(tester);
      expect(Appearance.instance.trustedDomains, ['docs.flutter.dev', 'github.com']);
    });
  });

  group('thinking', () {
    Future<void> pumpThinking(WidgetTester tester, String text, {bool live = false, Look look = const Look()}) async {
      FakeHost();
      await pumpLook(
        tester,
        look,
        Scaffold(body: Padding(padding: const EdgeInsets.all(16), child: ThinkingView(text: text, live: live))),
        height: 700,
      );
      await frames(tester);
    }

    testWidgets('collapsed: a 3-line preview, never the whole thing', (tester) async {
      await pumpThinking(tester, thought(40));
      final h = tester.getSize(find.byType(ThinkingView)).height;
      expect(h, lessThan(120), reason: 'header + 3 lines');
      expect(find.text('40 lines'), findsOneWidget);
      await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('thinking_preview')));
    });

    testWidgets('expanded: bounded to 12 lines and scrolls to the end', (tester) async {
      await pumpThinking(tester, thought(40));
      await tester.tap(find.text('Thought process'));
      await frames(tester);
      final h = tester.getSize(find.byType(ThinkingView)).height;
      expect(h, lessThan(360), reason: 'bounded, not 40 lines tall');
      final sc = tester.state<ScrollableState>(find.descendant(of: find.byType(ThinkingView), matching: find.byType(Scrollable)).first);
      expect(sc.position.maxScrollExtent, greaterThan(0));
      final panel = find.descendant(of: find.byType(ThinkingView), matching: find.byType(Scrollable)).first;
      await tester.dragFrom(tester.getTopLeft(panel) + const Offset(60, 30), const Offset(0, -2000));
      await frames(tester);
      expect(sc.position.pixels, sc.position.maxScrollExtent, reason: 'reaches the last line');
      expect(layoutErrors, isEmpty);
      await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('thinking_expanded')));
    });

    testWidgets('live: the preview shows the newest lines; a short thought shows whole', (tester) async {
      await pumpThinking(tester, thought(20), live: true);
      expect(find.text('Thinking'), findsOneWidget);
      await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('thinking_live')));
      await pumpThinking(tester, 'Singkat saja.');
      expect(find.textContaining('lines'), findsNothing);
    });
  });

  group('queued follow-ups', () {
    testWidgets('sent while busy: shown waiting, cancel removes it and its attachments', (tester) async {
      final host = FakeHost();
      host.answers['prompt'] = (_) => {'queued': 'q1'};
      host.answers['prompt_queue_remove'] = (_) => {'items': <String>[]};
      final agent = newAgent();
      await tester.pump();
      final files = <SentAttachment>[(path: '/tmp/a.png', name: 'a.png', mime: 'image/png', size: 10)];
      expect(await agent.sendWith('dan cek juga tabelnya', attachments: files), isTrue);
      host.emit({
        'type': 'prompt_queue',
        'items': [
          {'id': 'q1', 'text': 'dan cek juga tabelnya', 'images': 1},
        ],
      });
      await frames(tester);
      expect(agent.queuedPrompts.single.text, 'dan cek juga tabelnya');
      expect(await agent.cancelQueued('q1'), 'dan cek juga tabelnya');
      await frames(tester);
      expect(host.sent('prompt_queue_remove').single['queueId'], 'q1');
      expect(agent.queuedPrompts, isEmpty);
      // The cancelled message's files no longer wait for an echo.
      agent.addHistoryMessage({'role': 'user', 'content': 'lain'});
      expect((agent.entries.last as UserEntry).attachments, isEmpty);
    });

    testWidgets('a queue for another chat is ignored', (tester) async {
      final host = FakeHost();
      final agent = newAgent();
      await tester.pump();
      agent.sessionId = 'mine';
      host.emit({
        'type': 'prompt_queue',
        'sessionId': 'other',
        'items': [
          {'id': 'q9', 'text': 'x'},
        ],
      });
      await frames(tester);
      expect(agent.queuedPrompts, isEmpty);
    });

    for (final look in const [Look(), Look(dark: true, language: 'id')]) {
      testWidgets('golden: waiting bubble ${look.name}', (tester) async {
        FakeHost();
        var cancelled = 0;
        await pumpLook(
          tester,
          look,
          Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const UserBubble('Pahami codebase ini'),
                const SizedBox(height: 28),
                QueuedMessageView(
                  prompt: QueuedPrompt({'id': 'q1', 'text': 'Setelah itu, buat ringkasan di README juga ya', 'images': 0}),
                  onCancel: () => cancelled++,
                ),
                const SizedBox(height: 10),
                QueuedMessageView(
                  prompt: QueuedPrompt({'id': 'q2', 'text': 'Dan cek tabel ini', 'images': 2}),
                  onCancel: () {},
                ),
              ],
            ),
          ),
          height: 520,
        );
        await frames(tester);
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('queued_${look.name}')));
        await tester.tap(find.text(look.language == 'id' ? 'Batal' : 'Cancel').first);
        expect(cancelled, 1);
      });
    }
  });
}
