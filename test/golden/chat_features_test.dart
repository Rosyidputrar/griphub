// Chat features: thinking preview, tappable links with the leave-the-app
// confirmation and trusted domains, and follow-ups waiting for their turn.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/agent/drafts.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/ui/chat_screen.dart';
import 'package:griphub_agent/ui/chat_extras.dart' show ApprovalCards, editProjectCheck;
import 'package:griphub_agent/ui/memory_screen.dart';
import 'package:griphub_agent/ui/model_sheet.dart';
import 'package:griphub_agent/ui/read_only_chat.dart';
import 'package:griphub_agent/ui/verify_settings_screen.dart';
import 'package:griphub_agent/ui/verify_view.dart';
import 'package:griphub_agent/ui/smart_router_screen.dart';
import 'package:griphub_agent/ui/vision_translator_screen.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
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

    test('an invisible character in an address is dropped, so the link opens what it shows', () {
      // As a chat reply once carried it: "griphub" with a zero-width space after the g, which opened another repo.
      const shown = 'https://github.com/Rosyidputrar/g\u200Briphub/pull/27';
      expect(linkify('PR: $shown')[1].$2, 'https://github.com/Rosyidputrar/griphub/pull/27');
      expect(openableUri(shown).toString(), 'https://github.com/Rosyidputrar/griphub/pull/27');
      // Markdown hands the address over percent-encoded.
      expect(
        openableUri('https://github.com/Rosyidputrar/g%E2%80%8Briphub/pull/27').toString(),
        'https://github.com/Rosyidputrar/griphub/pull/27',
      );
      for (final c in ['\u00AD', '\u200C', '\u200D', '\u200E', '\u202E', '\u2060', '\u2066', '\uFEFF']) {
        expect(openableUri('https://exa${c}mple.com/a').toString(), 'https://example.com/a', reason: c.codeUnitAt(0).toRadixString(16));
      }
      expect(openableUri('https://ex%EF%BB%BFample.com/%e2%80%8ba').toString(), 'https://example.com/a');
      // Ordinary encoded text stays as it is.
      expect(openableUri('https://example.com/caf%C3%A9?q=a%20b').toString(), 'https://example.com/caf%C3%A9?q=a%20b');
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

  group('smart router', () {
    const glm = {'provider': 'griphub', 'id': 'glm-5.3-flash', 'name': 'GLM 5.3 Flash', 'input': ['text']};
    const kimi = {'provider': 'griphub', 'id': 'kimi-k3', 'name': 'Kimi K3', 'input': ['text']};
    Map<String, dynamic> routed(int turn, String model, String name) => {
      'at': 0,
      'turn': turn,
      'kind': 'route',
      'model': model,
      'modelName': name,
      'band': 0,
      'difficulty': 0,
      'reason': 'light (plain chat); cheapest that fits',
      'why': ['plain-chat', 'cheapest'],
      'estimate': 0.01,
    };

    /// A plain chat set to automatic: the router picked GLM for the first message, the user picked Kimi for the second.
    AgentController automaticChat({bool auto = true}) {
      final agent = newAgent()
        ..sessionId = 's1'
        ..isChat = true
        ..model = ModelInfo(Map.of(glm))
        ..models = [ModelInfo(Map.of(glm)), ModelInfo(Map.of(kimi))]
        ..smartRouter = SmartRouterState(enabled: true, auto: auto)
        ..routingLog = [RoutingDecision(routed(0, 'glm-5.3-flash', 'GLM 5.3 Flash'))];
      agent.addHistoryMessage({'role': 'user', 'content': 'Ibu kota Jepang apa?'});
      agent.addHistoryMessage({
        'role': 'assistant',
        'model': 'glm-5.3-flash',
        'stopReason': 'stop',
        'content': [
          {'type': 'text', 'text': 'Tokyo.'},
        ],
        'usage': {'input': 900, 'output': 12, 'cacheRead': 0, 'cacheWrite': 0, 'totalTokens': 912},
        'griphubCost': {'credits': 0.01, 'floored': true},
      });
      agent.addHistoryMessage({'role': 'user', 'content': 'Dan Prancis?'});
      agent.addHistoryMessage({
        'role': 'assistant',
        'model': 'kimi-k3',
        'stopReason': 'stop',
        'content': [
          {'type': 'text', 'text': 'Paris.'},
        ],
        'usage': {'input': 950, 'output': 10, 'cacheRead': 0, 'cacheWrite': 0, 'totalTokens': 960},
        'griphubCost': {'credits': 0.01, 'floored': true},
      });
      return agent;
    }

    Finder sparkles() => find.byType(SmartRouterMark);

    testWidgets('an automatic chat names the real model, with one small mark in the composer and under the routed turn', (tester) async {
      FakeHost();
      Drafts.root = Directory.systemTemp.createTempSync('drafts-').path;
      final agent = automaticChat();
      await pumpLook(tester, const Look(), ChatScreen(agent: agent));
      await frames(tester);
      // The composer shows the model really in use, never "Automatic".
      expect(find.text('GLM 5.3 Flash'), findsWidgets);
      expect(find.text('Automatic (Smart)'), findsNothing);
      // One mark in the composer, one under the first turn; the hand-picked second turn has none.
      expect(sparkles(), findsNWidgets(2));
      // Said to a screen reader too, inside the chip's and the footer's own labels.
      final semantics = tester.ensureSemantics();
      await tester.pump();
      expect(find.bySemanticsLabel(RegExp('chosen automatically')), findsNWidgets(2));
      semantics.dispose();
    });

    testWidgets('a chat that is not automatic shows no mark at all', (tester) async {
      FakeHost();
      Drafts.root = Directory.systemTemp.createTempSync('drafts-').path;
      final agent = automaticChat(auto: false)..routingLog = const [];
      await pumpLook(tester, const Look(), ChatScreen(agent: agent));
      await frames(tester);
      expect(sparkles(), findsNothing);
    });

    for (final look in const [Look(), Look(dark: true, language: 'id'), Look(language: 'id', textScale: 1.3, width: 320)]) {
      testWidgets('golden: automatic chat ${look.name}', (tester) async {
        FakeHost();
        Drafts.root = Directory.systemTemp.createTempSync('drafts-').path;
        await pumpLook(tester, look, ChatScreen(agent: automaticChat()));
        await frames(tester);
        expect(layoutErrors, isEmpty);
        await loadImages(tester);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('smart_router_chat_${look.name}')));
      });
    }

    /// The fake host first, then the agent: a client made before the host never hears its replies.
    FakeHost sheetHost() {
      final host = FakeHost();
      host.answers['providers'] = (_) => [
        {'id': 'griphub', 'name': 'GripHub Router', 'configured': true},
      ];
      host.answers['models'] = (_) => [glm, kimi];
      host.answers['smart_router_set'] = (cmd) => {'model': glm, 'sessionId': 's1', 'smartRouter': {'enabled': true, 'auto': cmd['on'] == true, 'floor': 0}};
      host.answers['set_model'] = (cmd) => {'model': cmd['model'] == 'kimi-k3' ? kimi : glm, 'sessionId': 's1', 'smartRouter': {'enabled': true, 'auto': false, 'floor': 0}};
      return host;
    }

    Future<void> pumpSheet(WidgetTester tester, AgentController agent, {Look look = const Look()}) async {
      await pumpLook(
        tester,
        look,
        Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(onPressed: () => showModelSheet(context, agent), child: const Text('open')),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await frames(tester, 12);
    }

    testWidgets('the picker offers "Automatic (Smart)" first; choosing it turns the chat automatic', (tester) async {
      final host = sheetHost();
      final agent = automaticChat(auto: false);
      await pumpSheet(tester, agent);
      expect(find.text('Automatic (Smart)'), findsOneWidget);
      expect(find.text('The cheapest model that can do each message'), findsOneWidget);
      await tester.tap(find.text('Automatic (Smart)'));
      await frames(tester, 12);
      expect(host.sent('smart_router_set').single['on'], true);
      expect(agent.smartRouter.auto, isTrue);
    });

    testWidgets('picking a model by hand in an automatic chat ends the automatic choice', (tester) async {
      final host = sheetHost();
      final agent = automaticChat();
      await pumpSheet(tester, agent);
      // The check sits on Automatic, not on the model it picked last.
      final autoRow = find.ancestor(of: find.text('Automatic (Smart)'), matching: find.byType(ListTile));
      expect(find.descendant(of: autoRow, matching: find.byIcon(LucideIcons.check)), findsOneWidget);
      await tester.tap(find.text('Kimi K3'));
      await frames(tester, 12);
      expect(host.sent('set_model').single['model'], 'kimi-k3');
      expect(agent.smartRouter.auto, isFalse);
    });

    testWidgets('with the smart router off in Settings, the picker has no automatic entry', (tester) async {
      sheetHost();
      final agent = automaticChat(auto: false)..smartRouter = const SmartRouterState(enabled: false);
      await pumpSheet(tester, agent);
      expect(find.text('Automatic (Smart)'), findsNothing);
      expect(find.text('Kimi K3'), findsOneWidget);
    });

    for (final look in const [Look(), Look(dark: true, language: 'id')]) {
      testWidgets('golden: picker with the automatic entry ${look.name}', (tester) async {
        sheetHost();
        await pumpSheet(tester, automaticChat(), look: look);
        expect(layoutErrors, isEmpty);
        await loadImages(tester);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('smart_router_picker_${look.name}')));
      });
    }

    for (final look in const [Look(), Look(dark: true, language: 'id')]) {
      testWidgets('golden: smart router settings ${look.name}', (tester) async {
        final host = FakeHost();
        host.stored['smartRouterBlocked'] = ['kimi-k3'];
        final agent = newAgent()..models = [ModelInfo(Map.of(glm)), ModelInfo(Map.of(kimi))];
        await pumpLook(tester, look, SmartRouterSettingsScreen(agent: agent));
        await frames(tester, 12);
        expect(layoutErrors, isEmpty);
        await loadImages(tester);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('smart_router_settings_${look.name}')));
      });
    }

    testWidgets('routing decisions of another chat are not added to this one', (tester) async {
      final host = FakeHost();
      final agent = newAgent()..sessionId = 'mine';
      await tester.pump();
      host.emit({'type': 'routing', 'sessionId': 'other', 'decision': routed(0, 'glm-5.3-flash', 'GLM'), 'smartRouter': {'enabled': true, 'auto': true}});
      await frames(tester);
      expect(agent.routingLog, isEmpty);
      host.emit({'type': 'routing', 'sessionId': 'mine', 'decision': routed(0, 'glm-5.3-flash', 'GLM'), 'smartRouter': {'enabled': true, 'auto': true}});
      await frames(tester);
      expect(agent.routingLog.single.model, 'glm-5.3-flash');
      expect(agent.smartRouter.auto, isTrue);
      expect(agent.autoRoutedTurns, {0});
    });
  });

  group('vision translator', () {
    const kimi = {'provider': 'griphub', 'id': 'kimi-k3', 'name': 'Kimi K3', 'input': ['text']};
    const reading =
        '<griphub-vision model="gemini-3.8-flash" name="Gemini 3.8 Flash" kind="full" credits="0.004200">\n'
        '[Isi gambar menurut model vision Gemini 3.8 Flash:\nStruk INDOMARET\nTOTAL 22.800\n]\n'
        '[Catatan: model utama tidak melihat gambar asli. Jawab berdasarkan uraian di atas.]\n</griphub-vision>';

    test('the reading is taken out of the text and kept as who read it', () {
      final (text, reads) = splitVisionReads('Berapa totalnya?\n\n$reading');
      expect(text, 'Berapa totalnya?');
      expect(reads.single.name, 'Gemini 3.8 Flash');
      expect(reads.single.kind, 'full');
      expect(reads.single.credits, closeTo(0.0042, 1e-9));
      expect(splitVisionReads('biasa saja').$2, isEmpty);
      final escaped = splitVisionReads('x\n\n<griphub-vision model="m" name="A &quot;B&quot;" kind="targeted" credits="">\n]\n</griphub-vision>');
      expect(escaped.$1, 'x');
      expect(escaped.$2.single.name, 'A "B"');
      expect(escaped.$2.single.credits, isNull);
    });

    AgentController readChat() {
      final agent = newAgent()
        ..sessionId = 's1'
        ..isChat = true
        ..model = ModelInfo(Map.of(kimi))
        ..models = [ModelInfo(Map.of(kimi))];
      agent.addHistoryMessage({
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'Berapa total belanja di struk ini?\n\n$reading'},
          {'type': 'image', 'data': 'iVBORw0KGgo=', 'mimeType': 'image/png'},
        ],
      });
      agent.addHistoryMessage({
        'role': 'assistant',
        'model': 'kimi-k3',
        'stopReason': 'stop',
        'content': [
          {'type': 'text', 'text': 'Total belanjanya Rp22.800.'},
        ],
        'usage': {'input': 1400, 'output': 20, 'cacheRead': 0, 'cacheWrite': 0, 'totalTokens': 1420},
        'griphubCost': {'credits': 0.0213, 'floored': false},
      });
      return agent;
    }

    testWidgets('the bubble shows what the user wrote; the answer says which model read the picture', (tester) async {
      FakeHost();
      Drafts.root = Directory.systemTemp.createTempSync('drafts-').path;
      await pumpLook(tester, const Look(), ChatScreen(agent: readChat()));
      await frames(tester);
      expect(find.textContaining('Isi gambar menurut'), findsNothing);
      expect(find.textContaining('griphub-vision'), findsNothing);
      // In the bubble and as the chat's title: both without the reading.
      expect(find.text('Berapa total belanja di struk ini?'), findsNWidgets(2));
      expect(find.textContaining('Picture read by Gemini 3.8 Flash'), findsOneWidget);
      expect(find.byType(VisionReadNote), findsOneWidget);
    });

    for (final look in const [Look(), Look(dark: true, language: 'id'), Look(language: 'id', textScale: 1.3, width: 320)]) {
      testWidgets('golden: answer from a reading ${look.name}', (tester) async {
        FakeHost();
        Drafts.root = Directory.systemTemp.createTempSync('drafts-').path;
        await pumpLook(tester, look, ChatScreen(agent: readChat()));
        await frames(tester);
        expect(layoutErrors, isEmpty);
        await loadImages(tester);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('vision_read_${look.name}')));
      });
    }

    Future<FakeHost> askChat(WidgetTester tester, {Look look = const Look()}) async {
      final host = FakeHost();
      host.answers['prompt'] = (cmd) => cmd['visionConsent'] == true
          ? null
          : {
              'visionConsent': {'model': 'gemini-3.8-flash', 'modelName': 'Gemini 3.8 Flash', 'estimate': 0.0042},
            };
      Drafts.root = Directory.systemTemp.createTempSync('drafts-').path;
      final agent = newAgent()
        ..sessionId = 's1'
        ..isChat = true
        ..model = ModelInfo(Map.of(kimi))
        ..models = [ModelInfo(Map.of(kimi))];
      await pumpLook(tester, look, ChatScreen(agent: agent));
      await frames(tester);
      unawaitedSend(agent);
      await frames(tester);
      return host;
    }

    testWidgets('"ask first": a dialog before the paid reading; yes sends it with consent', (tester) async {
      final host = await askChat(tester);
      expect(find.text('Read the picture with a vision model?'), findsOneWidget);
      expect(find.textContaining('Gemini 3.8 Flash will read it'), findsOneWidget);
      await tester.tap(find.text('Read the picture'));
      await frames(tester);
      final prompts = host.sent('prompt');
      expect(prompts, hasLength(2));
      expect(prompts.first['visionConsent'], isNull);
      expect(prompts.last['visionConsent'], true);
    });

    testWidgets('"ask first": Cancel sends nothing more', (tester) async {
      final host = await askChat(tester);
      await tester.tap(find.text('Cancel'));
      await frames(tester);
      expect(host.sent('prompt'), hasLength(1));
    });

    testWidgets('"ask first": a chat screen that closes leaves the question to the one still open', (tester) async {
      final host = FakeHost();
      host.answers['prompt'] = (cmd) => cmd['visionConsent'] == true
          ? null
          : {
              'visionConsent': {'model': 'gemini-3.8-flash', 'modelName': 'Gemini 3.8 Flash', 'estimate': 0.0042},
            };
      final agent = newAgent()
        ..sessionId = 's1'
        ..isChat = true
        ..model = ModelInfo(Map.of(kimi));
      final asked = <String>[];
      Future<bool> app(VisionAsk _) async => (asked..add('app')).isNotEmpty;
      Future<bool> panel(VisionAsk _) async => (asked..add('panel')).isNotEmpty;
      agent.addVisionConfirmer(app);
      agent.addVisionConfirmer(panel);
      // The panel's chat goes; the app's stays (it was there first).
      agent.removeVisionConfirmer(panel);
      await tester.pump();
      expect(await agent.sendWith('Apa ini?', images: const [{'type': 'image', 'data': 'iVBORw0KGgo=', 'mimeType': 'image/png'}]), isTrue);
      expect(asked, ['app']);
      expect(host.sent('prompt').last['visionConsent'], true);
    });

    testWidgets('"ask first" with no chat on screen: nothing is sent, and the chat says why', (tester) async {
      final host = FakeHost();
      host.answers['prompt'] = (cmd) => {
        'visionConsent': {'model': 'gemini-3.8-flash', 'modelName': 'Gemini 3.8 Flash', 'estimate': 0.0042},
      };
      final agent = newAgent()
        ..sessionId = 's1'
        ..isChat = true
        ..model = ModelInfo(Map.of(kimi));
      await tester.pump();
      expect(await agent.sendWith('Apa ini?', images: const [{'type': 'image', 'data': 'iVBORw0KGgo=', 'mimeType': 'image/png'}]), isFalse);
      expect(host.sent('prompt'), hasLength(1));
      final notice = agent.entries.whereType<NoticeEntry>().single;
      expect(notice.text, contains('The picture was not sent'));
      expect(notice.error, isTrue);
    });

    for (final look in const [Look(), Look(dark: true, language: 'id')]) {
      testWidgets('golden: ask-first dialog ${look.name}', (tester) async {
        await askChat(tester, look: look);
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('vision_ask_${look.name}')));
      });
    }

    for (final look in const [Look(), Look(dark: true, language: 'id')]) {
      testWidgets('golden: vision translator settings ${look.name}', (tester) async {
        final host = FakeHost();
        host.answers['vision_translator_info'] = (_) => {
          'models': [
            {'id': 'gemini-3.8-flash', 'name': 'Gemini 3.8 Flash', 'credits': 1.5, 'available': true},
            {'id': 'gemini-3.1-pro', 'name': 'Gemini 3.1 Pro', 'credits': 2, 'available': true},
            {'id': 'gpt-5.6-luna', 'name': 'GPT 5.6 Luna', 'credits': 1, 'available': true},
          ],
          'defaultAllowed': ['gemini-3.8-flash', 'gemini-3.1-pro'],
          'current': {'id': 'gemini-3.8-flash', 'name': 'Gemini 3.8 Flash', 'manual': false},
        };
        await pumpLook(tester, look, VisionTranslatorScreen(agent: newAgent()), height: 1200);
        await frames(tester, 12);
        expect(layoutErrors, isEmpty);
        expect(find.text(look.language == 'id' ? 'Penerjemah vision' : 'Vision translator'), findsOneWidget);
        await loadImages(tester);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('vision_settings_${look.name}')));
      });
    }
  });

  group('browsing while the agent works', () {
    /// Chat A works (with a draft and a reply streaming); chat B is a finished chat on disk.
    Future<(FakeHost, AgentController)> working(WidgetTester tester, {Look look = const Look(), int approvals = 0}) async {
      final host = FakeHost();
      host.answers['session_read'] = (cmd) => {
        'path': cmd['path'],
        'sessionId': 'b',
        'sessionName': 'Resep rendang',
        'cwd': '/w',
        'chatMode': 'chat',
        'messages': [
          {'role': 'user', 'content': 'Bagaimana cara membuat rendang?'},
          {
            'role': 'assistant',
            'model': 'kimi-k3',
            'stopReason': 'stop',
            'content': [
              {'type': 'text', 'text': 'Tumis bumbu halus sampai harum, masukkan daging dan santan, lalu masak dengan api kecil selama 3 jam.'},
            ],
            'usage': {'input': 300, 'output': 40, 'cacheRead': 0, 'cacheWrite': 0, 'totalTokens': 340},
            'griphubCost': {'credits': 0.01, 'floored': true},
          },
        ],
      };
      host.answers['open_session'] = (cmd) => {'sessionFile': cmd['path'], 'sessionId': 'b', 'sessionName': 'Resep rendang', 'isStreaming': false};
      Drafts.root = Directory.systemTemp.createTempSync('drafts-').path;
      final agent = newAgent()
        ..sessionFile = 'a.jsonl'
        ..sessionId = 'a'
        ..sessionName = 'Refactor modul auth'
        ..isChat = true
        ..model = ModelInfo(const {'provider': 'griphub', 'id': 'kimi-k3', 'name': 'Kimi K3', 'input': ['text']});
      agent.addHistoryMessage({'role': 'user', 'content': 'Refactor modul auth'});
      await pumpLook(tester, look, ChatScreen(agent: agent));
      await frames(tester);
      host.emit({'type': 'state', 'state': {'isStreaming': true, 'sessionFile': 'a.jsonl', 'sessionId': 'a', 'sessionName': 'Refactor modul auth', 'chatMode': 'chat'}});
      for (var i = 0; i < approvals; i++) {
        host.emit({'type': 'approval', 'approvalId': 'ap$i', 'toolName': 'bash', 'summary': 'rm -rf build', 'reason': 'deletes files'});
      }
      await frames(tester);
      return (host, agent);
    }

    Finder composerField() => find.byType(TextField);

    testWidgets('another chat opens read-only: the pill names the chat at work, sending is locked', (tester) async {
      final (host, agent) = await working(tester);
      await tester.enterText(composerField().last, 'draf di A');
      await agent.openSession('b.jsonl');
      await frames(tester);
      expect(find.text('The agent is working in'), findsOneWidget);
      expect(find.descendant(of: find.byType(WorkingPill), matching: find.text('Refactor modul auth')), findsOneWidget);
      expect(find.text('Read-only until the agent is free.'), findsOneWidget, reason: 'the pill names the chat; said once');
      expect(find.text('Bagaimana cara membuat rendang?'), findsOneWidget);
      // No field, no Send: nothing here can send.
      expect(composerField(), findsNothing);
      expect(find.byTooltip('Send'), findsNothing);
      expect(host.sent('abort'), isEmpty);
      expect(host.sent('open_session'), isEmpty);
      // The pill goes back to the chat at work, live, with its draft as typed.
      await tester.tap(find.byType(WorkingPill));
      await frames(tester);
      expect(agent.viewing, isNull);
      expect(tester.widget<TextField>(composerField().last).controller!.text, 'draf di A');
    });

    testWidgets('drafts of both chats stay as typed through the back and forth', (tester) async {
      final (_, agent) = await working(tester);
      Drafts.instance.set('b', 'draf lama di B');
      await tester.enterText(composerField().last, 'draf di A');
      await agent.openSession('b.jsonl');
      await frames(tester);
      expect(find.text('draf lama di B'), findsOneWidget, reason: 'the locked composer keeps B\'s draft on show');
      agent.leaveView();
      await frames(tester);
      expect(tester.widget<TextField>(composerField().last).controller!.text, 'draf di A');
      await agent.openSession('b.jsonl');
      await frames(tester);
      expect(Drafts.instance.get('b'), 'draf lama di B');
      expect(Drafts.instance.get('a'), 'draf di A');
    });

    testWidgets('approvals waiting in the chat at work: a number on the pill, never their cards here', (tester) async {
      final (_, agent) = await working(tester, approvals: 2);
      await agent.openSession('b.jsonl');
      await frames(tester);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('rm -rf build'), findsNothing);
      expect(find.byType(ApprovalCards), findsNothing);
    });

    testWidgets('system Back from the read-only chat returns to the chat at work', (tester) async {
      final (_, agent) = await working(tester);
      await agent.openSession('b.jsonl');
      await frames(tester);
      await tester.binding.handlePopRoute();
      await frames(tester);
      expect(agent.viewing, isNull);
      expect(find.byType(WorkingPill), findsNothing);
    });

    testWidgets('when the chat at work ends, the chat on screen opens and can be written in, without a restart', (tester) async {
      final (host, agent) = await working(tester);
      Drafts.instance.set('b', 'lanjutkan resepnya');
      await agent.openSession('b.jsonl');
      await frames(tester);
      host.emit({'type': 'state', 'state': {'isStreaming': false, 'sessionFile': 'a.jsonl', 'sessionId': 'a'}});
      await frames(tester, 14);
      expect(host.sent('open_session').single['path'], 'b.jsonl');
      expect(agent.viewing, isNull);
      expect(find.byType(WorkingPill), findsNothing);
      expect(find.text('The agent is done in Refactor modul auth'), findsOneWidget);
      // The composer is back, with B's draft.
      expect(tester.widget<TextField>(composerField().last).controller!.text, 'lanjutkan resepnya');
      expect(agent.finishedUnseen, contains('a.jsonl'));
    });

    testWidgets('Try again (from a notification) on a chat shown read-only runs there once the agent is free', (tester) async {
      final (host, agent) = await working(tester);
      await agent.openSession('b.jsonl');
      await agent.retry();
      await frames(tester);
      expect(host.sent('retry'), isEmpty, reason: 'nothing runs while the agent works elsewhere');
      expect(find.text('Try again runs here once the agent is free.'), findsOneWidget);
      host.emit({'type': 'state', 'state': {'isStreaming': false, 'sessionFile': 'a.jsonl', 'sessionId': 'a'}});
      await frames(tester, 14);
      expect(host.sent('open_session').single['path'], 'b.jsonl');
      expect(host.sent('retry'), hasLength(1), reason: 'in chat B, now open for real');
    });

    testWidgets('a new chat given text while the agent works keeps it when it opens for real', (tester) async {
      final (host, agent) = await working(tester);
      host.answers['new_session'] = (_) => {'sessionFile': 'c.jsonl', 'sessionId': 'c', 'chatMode': 'chat', 'isStreaming': false};
      await agent.newSession(chat: true);
      // A share opens the waiting chat with its text, as HomeShell does.
      await pumpLook(tester, const Look(), ChatScreen(key: const ValueKey('shared'), agent: agent, initialPrompt: 'Ringkas artikel ini'));
      await frames(tester);
      expect(Drafts.instance.get(agent.viewing!.key), 'Ringkas artikel ini', reason: 'kept even before anything is typed');
      host.emit({'type': 'state', 'state': {'isStreaming': false, 'sessionFile': 'a.jsonl', 'sessionId': 'a'}});
      await frames(tester, 14);
      expect(host.sent('new_session'), hasLength(1));
      expect(agent.viewing, isNull);
      expect(agent.sessionId, 'c');
      expect(Drafts.instance.get('c'), 'Ringkas artikel ini');
      expect(tester.widget<TextField>(composerField().last).controller!.text, 'Ringkas artikel ini');
    });

    for (final look in const [Look(), Look(dark: true, language: 'id'), Look(language: 'id', textScale: 1.3, width: 320)]) {
      testWidgets('golden: read-only chat while the agent works ${look.name}', (tester) async {
        final (_, agent) = await working(tester, look: look, approvals: 1);
        Drafts.instance.set('b', 'Tambahkan juga takaran bumbunya');
        await agent.openSession('b.jsonl');
        await frames(tester);
        expect(layoutErrors, isEmpty);
        await loadImages(tester);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('read_only_chat_${look.name}')));
      });
    }
  });

  group('self-verification', () {
    Map<String, dynamic> evidence(String status, {String next = 'close', int round = 0, List<String> touched = const [], String? command = 'npm test'}) => {
      'role': 'custom',
      'customType': 'griphub_verify',
      'content': '[Verification evidence]',
      'display': true,
      'details': {
        'next': next,
        'evidence': {
          'status': status,
          'command': command,
          'source': 'package.json',
          'exitCode': status == 'passed' ? 0 : (command == null ? null : 1),
          'durationMs': 12300,
          'summary': status == 'passed' ? '> node test/check.test.js\nok.txt says ok\n1 passing' : 'ok.txt says bad\nFAIL: expected ok',
          'outputId': 'abc-def',
          'round': round,
          'maxRounds': 3,
          'testsTouched': touched,
          'at': 0,
        },
      },
    };
    Map<String, dynamic> reply(String text) => {
      'role': 'assistant',
      'model': 'kimi-k3',
      'stopReason': 'stop',
      'content': [
        {'type': 'text', 'text': text},
      ],
      'usage': {'input': 900, 'output': 40, 'cacheRead': 0, 'cacheWrite': 0, 'totalTokens': 940},
      'griphubCost': {'credits': 0.01, 'floored': true},
    };

    AgentController verifiedChat() {
      final agent = newAgent()
        ..sessionId = 's1'
        ..model = ModelInfo(const {'provider': 'griphub', 'id': 'kimi-k3', 'name': 'Kimi K3', 'input': ['text']});
      for (final m in [
        {'role': 'user', 'content': 'Perbaiki validasi ok.txt'},
        reply('Saya mengubah ok.txt.'),
        evidence('failed', next: 'fix'),
        reply('Memperbaiki isi ok.txt.'),
        evidence('passed', round: 1),
        reply('Selesai: verifikasi `npm test` lulus.'),
      ]) {
        agent.addHistoryMessage(m);
      }
      return agent;
    }

    testWidgets('evidence is its own block; the closing message names the last result', (tester) async {
      FakeHost();
      Drafts.root = Directory.systemTemp.createTempSync('drafts-').path;
      await pumpLook(tester, const Look(), ChatScreen(agent: verifiedChat()), height: 1400);
      await frames(tester);
      expect(find.byType(VerifyEvidenceView), findsNWidgets(2));
      expect(find.text('Tests failed'), findsOneWidget);
      expect(find.text('Tests passed'), findsOneWidget);
      expect(find.text('The agent fixes it now; the check runs again (1 of 3).'), findsOneWidget);
      // The closing message comes right after the evidence block: the status is not said a second time under it.
      expect(find.byType(VerifyStatusNote), findsNothing);
    });

    test('the note under the closing message: only when the evidence is not right above it, and the last one', () {
      final agent = verifiedChat();
      final last = agent.entries.length - 1;
      expect(lastVerifyOfTurn(agent.entries, last), isNull, reason: 'the block is right above');
      agent.addHistoryMessage(reply('Ringkasan perubahan lainnya.'));
      final note = lastVerifyOfTurn(agent.entries, agent.entries.length - 1);
      expect(note?.status, 'passed', reason: 'the last evidence of the turn, not the first');
    });

    testWidgets('the whole output opens from the evidence', (tester) async {
      final host = FakeHost();
      host.answers['verify_output'] = (cmd) => {'output': 'FULL OUTPUT of ${cmd['outputId']}'};
      Drafts.root = Directory.systemTemp.createTempSync('drafts-').path;
      await pumpLook(tester, const Look(), ChatScreen(agent: verifiedChat()), height: 1400);
      await frames(tester);
      await tester.tap(find.text('Full output').first);
      await frames(tester, 12);
      expect(find.text('FULL OUTPUT of abc-def'), findsOneWidget);
    });

    testWidgets('while the check runs, the activity line says so', (tester) async {
      final host = FakeHost();
      Drafts.root = Directory.systemTemp.createTempSync('drafts-').path;
      final agent = newAgent()..sessionId = 's1';
      agent.addHistoryMessage({'role': 'user', 'content': 'Ubah ok.txt'});
      await pumpLook(tester, const Look(), ChatScreen(agent: agent));
      host.emit({'type': 'state', 'state': {'isStreaming': true, 'sessionId': 's1'}});
      host.emit({'type': 'verify', 'sessionId': 's1', 'phase': 'running', 'command': 'npm test'});
      await frames(tester);
      expect(find.text('Checking: npm test'), findsOneWidget);
      host.emit({'type': 'verify', 'sessionId': 's1', 'phase': 'done', 'status': 'passed'});
      await frames(tester);
      expect(find.text('Checking: npm test'), findsNothing);
    });

    for (final look in const [Look(), Look(dark: true, language: 'id'), Look(language: 'id', textScale: 1.3, width: 320)]) {
      testWidgets('golden: evidence blocks ${look.name}', (tester) async {
        FakeHost();
        await pumpLook(
          tester,
          look,
          Scaffold(
            body: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                for (final m in [
                  evidence('failed', next: 'fix'),
                  evidence('tests-changed', touched: const ['test/check.test.js'], round: 3),
                  evidence('passed', round: 1),
                  evidence('none', command: null),
                ]) ...[
                  VerifyEvidenceView(VerifyEntry((m['details'] as Map).cast<String, dynamic>()), agent: newAgent()),
                  const SizedBox(height: 12),
                ],
              ],
            ),
          ),
          height: 1500,
        );
        await frames(tester);
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('verify_evidence_${look.name}')));
      });
    }

    for (final look in const [Look(), Look(dark: true, language: 'id')]) {
      testWidgets('golden: self-verification settings ${look.name}', (tester) async {
        final host = FakeHost();
        host.stored['verifyRounds'] = 3;
        await pumpLook(tester, look, VerifySettingsScreen(agent: newAgent()));
        await frames(tester, 12);
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('verify_settings_${look.name}')));
      });
    }

    testWidgets('settings: the switch, the rounds and "also tasks that change no file" go to the host', (tester) async {
      final host = FakeHost();
      await pumpLook(tester, const Look(), VerifySettingsScreen(agent: newAgent()));
      await frames(tester, 12);
      await tester.tap(find.byTooltip('One more round'));
      await frames(tester);
      expect(host.stored['verifyRounds'], 4);
      await tester.tap(find.byType(Switch).last);
      await frames(tester);
      expect(host.stored['verifyAlways'], true);
      await tester.tap(find.byType(Switch).first);
      await frames(tester);
      expect(host.stored['verify'], false);
    });

    testWidgets("a project's own check command is saved for its folder", (tester) async {
      final host = FakeHost();
      final agent = newAgent()..cwd = '/w/proj';
      await pumpLook(
        tester,
        const Look(),
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(onPressed: () => editProjectCheck(context, agent), child: const Text('open')),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await frames(tester);
      await tester.enterText(find.byType(TextField), 'make check');
      await tester.tap(find.text('Save'));
      await frames(tester);
      expect(host.stored['projectVerify'], {'/w/proj': 'make check'});
    });
  });

  group('agent memory', () {
    Map<String, dynamic> proposal({String status = 'pending', String? replaces}) => {
      'id': 'p-1',
      'toolCallId': 'call_1',
      'text': 'Pengguna lebih suka jawaban singkat',
      'layer': 'global',
      'project': null,
      'replaces': replaces == null ? null : 'm-1',
      'replacesText': replaces,
      'sessionId': 's1',
      'status': status,
      'at': 0,
    };

    AgentController proposingChat({Map<String, dynamic>? details}) {
      final agent = newAgent()..sessionId = 's1'..isChat = true;
      for (final m in <Map<String, dynamic>>[
        {'role': 'user', 'content': 'Jawab singkat saja ya'},
        {
          'role': 'assistant',
          'model': 'kimi-k3',
          'stopReason': 'toolUse',
          'content': [
            {'type': 'toolCall', 'id': 'call_1', 'name': 'remember', 'arguments': {'text': 'Pengguna lebih suka jawaban singkat', 'layer': 'global'}},
          ],
        },
        {'role': 'toolResult', 'toolCallId': 'call_1', 'toolName': 'remember', 'content': [{'type': 'text', 'text': 'Proposed'}], 'details': details ?? {'proposal': proposal(replaces: 'Pengguna suka jawaban panjang')}},
        {
          'role': 'assistant',
          'model': 'kimi-k3',
          'stopReason': 'stop',
          'content': [{'type': 'text', 'text': 'Baik, saya usulkan untuk diingat.'}],
        },
      ]) {
        agent.addHistoryMessage(m);
      }
      return agent;
    }

    Future<FakeHost> pumpProposal(WidgetTester tester, {Look look = const Look(), Map<String, dynamic>? details}) async {
      final host = FakeHost();
      host.answers['memory_decide'] = (cmd) => {...proposal(), 'status': cmd['action'] == 'save' ? 'saved' : 'rejected', if (cmd['text'] != null) 'text': cmd['text']};
      Drafts.root = Directory.systemTemp.createTempSync('drafts-').path;
      await pumpLook(tester, look, ChatScreen(agent: proposingChat(details: details)));
      await frames(tester);
      return host;
    }

    testWidgets('the proposal waits for the user: Save keeps it, and the card says so', (tester) async {
      final host = await pumpProposal(tester);
      expect(find.text('Remember this?'), findsOneWidget);
      expect(find.text('Pengguna lebih suka jawaban singkat'), findsOneWidget);
      expect(find.text('Replaces: Pengguna suka jawaban panjang'), findsOneWidget);
      await tester.tap(find.text('Save'));
      await frames(tester);
      expect(host.sent('memory_decide').single, containsPair('action', 'save'));
      expect(find.text('Saved to memory'), findsOneWidget);
      expect(find.text('Save'), findsNothing);
    });

    testWidgets('in a chat shown read-only, an open proposal offers no Save or Refuse', (tester) async {
      final host = FakeHost();
      final agent = proposingChat();
      await pumpLook(tester, const Look(), Material(child: MemoryProposalCard(agent: agent, run: agent.tools['call_1'], readOnly: true)));
      await frames(tester);
      expect(find.text('Pengguna lebih suka jawaban singkat'), findsOneWidget);
      expect(find.text('Save'), findsNothing);
      expect(find.text('Refuse'), findsNothing);
      expect(find.text('Read-only until the agent is free.'), findsOneWidget);
      expect(host.sent('memory_decide'), isEmpty);
    });

    testWidgets('Refuse keeps nothing; Edit saves the user\'s own words', (tester) async {
      var host = await pumpProposal(tester);
      await tester.tap(find.text('Refuse'));
      await frames(tester);
      expect(host.sent('memory_decide').single['action'], 'reject');
      expect(find.text('Not saved'), findsOneWidget);
    });

    testWidgets('Edit saves the user\'s words', (tester) async {
      final host = await pumpProposal(tester);
      await tester.tap(find.text('Edit'));
      await frames(tester);
      await tester.enterText(find.byType(TextField).last, 'Jawaban singkat, bahasa Indonesia');
      await tester.tap(find.text('Save').last);
      await frames(tester);
      expect(host.sent('memory_decide').single['text'], 'Jawaban singkat, bahasa Indonesia');
    });

    testWidgets('a secret is not proposed: the card says why, with no buttons', (tester) async {
      await pumpProposal(tester, details: {'refused': 'This looks like an API key. Memory never keeps passwords, keys or tokens; keep those in the app\'s accounts or a password manager.'});
      expect(find.text('Not proposed to remember'), findsOneWidget);
      expect(find.textContaining('This looks like an API key'), findsOneWidget);
      expect(find.text('Save'), findsNothing);
    });

    for (final look in const [Look(), Look(dark: true, language: 'id'), Look(language: 'id', textScale: 1.3, width: 320)]) {
      testWidgets('golden: memory proposal in the chat ${look.name}', (tester) async {
        await pumpProposal(tester, look: look);
        expect(layoutErrors, isEmpty);
        await loadImages(tester);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('memory_proposal_${look.name}')));
      });
    }

    Map<String, dynamic> listed(String host) => {
      'host': host,
      'on': true,
      'entries': [
        {'id': 'm-1', 'text': 'Pengguna lebih suka TypeScript', 'source': 'Refactor auth', 'sessionId': 's1', 'createdAt': '2026-11-01', 'confirmedAt': '2026-11-06', 'replaced': ['m-0 (2026-11-06): "Pengguna suka JavaScript"']},
        {'id': 'm-2', 'text': 'Nama panggilannya Rosdi', 'source': 'you', 'createdAt': '2026-11-02', 'confirmedAt': '2026-11-02', 'replaced': <String>[]},
      ],
    };

    testWidgets('the memory screen: edit, delete one, delete all; it says where memory is kept', (tester) async {
      final host = FakeHost();
      host.answers['memory_list'] = (_) => listed('server');
      await pumpLook(tester, const Look(), MemoryScreen(agent: newAgent()));
      await frames(tester, 12);
      expect(find.text('Pengguna lebih suka TypeScript'), findsOneWidget);
      expect(find.textContaining('Kept on the server agent'), findsOneWidget);
      expect(find.textContaining('from Refactor auth'), findsOneWidget);
      await tester.tap(find.text('Nama panggilannya Rosdi'));
      await frames(tester);
      await tester.enterText(find.byType(TextField), 'Panggil aku Rosdi');
      await tester.tap(find.text('Save'));
      await frames(tester, 12);
      expect(host.sent('memory_update').single, allOf(containsPair('entryId', 'm-2'), containsPair('text', 'Panggil aku Rosdi')));
      await tester.tap(find.byTooltip('Delete').first);
      await frames(tester, 12);
      expect(host.sent('memory_remove').single['entryId'], 'm-1');
      await tester.tap(find.byTooltip('Delete all'));
      await frames(tester);
      await tester.tap(find.text('Delete all').last);
      await frames(tester, 12);
      expect(host.sent('memory_clear'), hasLength(1));
    });

    for (final look in const [Look(), Look(dark: true, language: 'id')]) {
      testWidgets('golden: memory screen ${look.name}', (tester) async {
        final host = FakeHost();
        host.answers['memory_list'] = (_) => listed('phone');
        await pumpLook(tester, look, MemoryScreen(agent: newAgent()));
        await frames(tester, 12);
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(MaterialApp), matchesGoldenFile(golden('memory_screen_${look.name}')));
      });
    }

    testWidgets('what the chat started with is shown as it was', (tester) async {
      final host = FakeHost();
      host.answers['memory_snapshot'] = (_) => {
        'global': [{'id': 'm-1', 'text': 'Pengguna lebih suka TypeScript'}],
        'project': [{'id': 'm-3', 'text': 'Proyek ini memakai Riverpod'}],
        'projectPath': '/w/app',
        'left': 2,
        'at': 0,
      };
      await pumpLook(tester, const Look(), MemorySnapshotScreen(agent: newAgent()));
      await frames(tester, 12);
      expect(find.text('Pengguna lebih suka TypeScript'), findsOneWidget);
      expect(find.text('Proyek ini memakai Riverpod'), findsOneWidget);
      expect(find.text('2 older facts did not fit the budget.'), findsOneWidget);
    });

    testWidgets('"ingat ini" saved or refused: said quietly in the chat', (tester) async {
      final host = FakeHost();
      final agent = newAgent()..sessionId = 's1';
      await tester.pump();
      host.emit({'type': 'memory_saved', 'layer': 'global', 'entry': {'text': 'aku pakai Vim'}});
      host.emit({'type': 'memory_refused', 'reason': 'This looks like a password or key. Memory never keeps passwords, keys or tokens; keep those in the app\'s accounts or a password manager.'});
      await frames(tester);
      final notices = agent.entries.whereType<NoticeEntry>().map((n) => n.text).toList();
      expect(notices.first, 'Remembered: aku pakai Vim');
      expect(notices.last, startsWith('Not remembered: This looks like a password or key'));
    });
  });
}

/// Sends a message with a picture without waiting: the dialog it may open has to be answered first.
void unawaitedSend(AgentController agent) {
  agent.sendWith('Apa ini?', images: const [
    {'type': 'image', 'data': 'iVBORw0KGgo=', 'mimeType': 'image/png'},
  ]);
}
