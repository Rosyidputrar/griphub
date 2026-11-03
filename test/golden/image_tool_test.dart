// Pictures in the chat (the agent's generate_image tool) and Settings → Pictures: the card while pictures are made
// (shimmer), as they land (reveal), finished, partly failed, opened again later; the approval over the limit with no
// "Always"; and the settings screen with its limits.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/agent/integrations.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/ui/chat_extras.dart';
import 'package:griphub_agent/ui/image_settings_screen.dart';
import 'package:griphub_agent/ui/image_tool_card.dart';
import 'package:griphub_agent/ui/message_views.dart';

import 'harness.dart';

const _looks = [Look(), Look(dark: true, language: 'id'), Look(language: 'id', textScale: 1.3, width: 320)];

Future<void> frames(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The two pictures' paths, written from the constants at the end for the run.
late String _png1;
late String _png2;
late Directory _dir;

Map<String, dynamic> _details(List<Map<String, dynamic>> slots, {int asked = 2, double? credits, int? finishedAt}) => {
  'model': 'gemini-3.1-flash-image',
  'size': '1024x1024',
  'prompt': 'A minimal coffee shop logo: a cup with steam shaped like a leaf, warm brown, plain background',
  'asked': asked,
  'slots': slots,
  'rate': 2.5,
  'credits': credits ?? 0,
  'cheapest': true,
  'startedAt': DateTime(2026, 11, 3, 9, 59, 21).millisecondsSinceEpoch,
  'finishedAt': ?finishedAt,
};

/// The chat as the app has it: the user's ask, the agent's call to generate_image, and its result so far.
AgentController _chat(Map<String, dynamic> details, {required String status, String output = ''}) {
  final agent = newAgent();
  agent.entries.add(UserEntry('buatkan logo kedai kopi, 2 variasi'));
  final reply = AssistantEntry()
    ..applyMessage({
      'role': 'assistant',
      'content': [
        {'type': 'text', 'text': 'Saya buatkan 2 variasi dengan model gambar termurah.'},
        {
          'type': 'toolCall',
          'id': 'img1',
          'name': 'generate_image',
          'arguments': {'prompt': details['prompt'], 'count': 2},
        },
      ],
    })
    ..streaming = false;
  agent.entries.add(reply);
  agent.tools['img1'] = ToolRun('img1')
    ..status = switch (status) {
      'done' => ToolStatus.done,
      'failed' => ToolStatus.failed,
      _ => ToolStatus.running,
    }
    ..output = output
    ..imageJob = ImageJob.fromDetails(details);
  return agent;
}

Widget _view(AgentController agent) => Scaffold(
  body: ListView(
    padding: const EdgeInsets.all(16),
    children: [
      for (final e in agent.entries.whereType<AssistantEntry>()) AssistantMessageView(e, tools: agent.tools),
    ],
  ),
);

/// Pumps until the tiles have read and decoded their pictures (real file reads and decoding happen outside fake time).
Future<void> settle(WidgetTester tester, {Duration step = const Duration(milliseconds: 50)}) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(() async {
      // Decoding runs on the engine; precaching here waits for it in real time.
      for (final e in find.byType(ImageTile).evaluate()) {
        final f = (e.widget as ImageTile).slot.file;
        if (f != null && File(f).existsSync()) {
          await precacheImage(ResizeImage.resizeIfNeeded(768, null, MemoryImage(File(f).readAsBytesSync())), e);
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    });
    await tester.pump(step);
  }
}

void main() {
  setUpAll(() async {
    await loadAppFonts();
    _dir = Directory.systemTemp.createTempSync('gh-img-');
    _png1 = '${_dir.path}/logo-1.png';
    _png2 = '${_dir.path}/logo-2.png';
    File(_png1).writeAsBytesSync(base64Decode(_coffeePng));
    File(_png2).writeAsBytesSync(base64Decode(_leafPng));
  });
  tearDownAll(() => _dir.deleteSync(recursive: true));
  setUp(() {
    applyLook(const Look());
    layoutErrors.clear();
  });

  group('the card in the chat', () {
    for (final look in _looks) {
      testWidgets('golden: one landed, one still being made ${look.name}', (tester) async {
        FakeHost();
        final agent = _chat(
          _details([
            {'status': 'done', 'file': _png1},
            {'status': 'running'},
          ], credits: 2.5),
          status: 'running',
        );
        await pumpLook(tester, look, _view(agent), height: 640);
        await settle(tester);
        await tester.pump(const Duration(seconds: 1));
        expect(find.byType(ImageToolCard), findsOneWidget);
        expect(find.byType(ImageTile), findsNWidgets(2));
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('image_tool_running_${look.name}')));
      });
    }

    for (final look in _looks.take(2)) {
      testWidgets('golden: done, one failed (said whether billed), fewer than asked ${look.name}', (tester) async {
        FakeHost();
        final agent = _chat(
          _details(
            [
              {'status': 'done', 'file': _png1},
              {'status': 'done', 'file': _png2},
              {'status': 'failed', 'error': 'No answer after 3 minutes', 'maybeBilled': true},
            ],
            asked: 6,
            credits: 5,
            finishedAt: DateTime(2026, 11, 3, 10, 0, 0).millisecondsSinceEpoch,
          ),
          status: 'done',
        );
        await pumpLook(tester, look, _view(agent), height: 900);
        await settle(tester);
        expect(find.textContaining('3 of 6'.replaceAll('of', look.language == 'id' ? 'dari' : 'of')), findsOneWidget);
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('image_tool_done_${look.name}')));
      });
    }

    testWidgets('a picture already there when the chat opens shows at once; a new one is revealed', (tester) async {
      FakeHost();
      final agent = _chat(_details([{'status': 'done', 'file': _png1}, {'status': 'running'}]), status: 'running');
      await pumpLook(tester, const Look(), _view(agent), height: 640);
      await settle(tester);
      // The first tile was done before it was built: no reveal (full opacity at once).
      final first = tester.widgetList<ShimmerReveal>(find.byType(ShimmerReveal)).first;
      expect(first.reveal, 1);
      // The second lands now: it starts its reveal from 0 and ends at 1 after 600 ms.
      agent.tools['img1']!.imageJob = ImageJob.fromDetails(_details([{'status': 'done', 'file': _png1}, {'status': 'done', 'file': _png2}]));
      await pumpLook(tester, const Look(), _view(agent), height: 640);
      // Real time for the decode, but no animation time: the reveal has only just started.
      await settle(tester, step: Duration.zero);
      await tester.pump(const Duration(milliseconds: 150));
      final mid = tester.widgetList<ShimmerReveal>(find.byType(ShimmerReveal)).last.reveal;
      expect(mid, inExclusiveRange(0, 1), reason: 'the new picture is coming in');
      await tester.pump(const Duration(milliseconds: 700));
      expect(tester.widgetList<ShimmerReveal>(find.byType(ShimmerReveal)).last.reveal, 1);
    });

    testWidgets('with animations off, nothing shimmers and the picture shows at once', (tester) async {
      FakeHost();
      final agent = _chat(_details([{'status': 'running'}, {'status': 'running'}]), status: 'running');
      await pumpLook(tester, const Look(), MediaQuery(data: const MediaQueryData(disableAnimations: true), child: _view(agent)));
      await tester.pump(const Duration(seconds: 1));
      expect(tester.widgetList<ShimmerReveal>(find.byType(ShimmerReveal)).every((w) => w.shimmer == 0), isTrue);
      agent.tools['img1']!.imageJob = ImageJob.fromDetails(_details([{'status': 'done', 'file': _png1}, {'status': 'running'}]));
      await pumpLook(tester, const Look(), MediaQuery(data: const MediaQueryData(disableAnimations: true), child: _view(agent)));
      await settle(tester);
      expect(tester.widgetList<ShimmerReveal>(find.byType(ShimmerReveal)).first.reveal, 1);
    });

    testWidgets('a picture file that is gone says so instead of an endless shimmer', (tester) async {
      FakeHost();
      final agent = _chat(_details([{'status': 'done', 'file': '${_dir.path}/deleted.png'}], asked: 1), status: 'done');
      await pumpLook(tester, const Look(), _view(agent));
      await settle(tester);
      expect(find.text('Picture not found'), findsOneWidget);
    });

    testWidgets('a refusal before any picture (a limit) is a plain tool card with the reason', (tester) async {
      FakeHost();
      final agent = newAgent();
      agent.entries.add(
        AssistantEntry()
          ..applyMessage({
            'role': 'assistant',
            'content': [
              {'type': 'toolCall', 'id': 'img2', 'name': 'generate_image', 'arguments': {'prompt': 'x'}},
            ],
          })
          ..streaming = false,
      );
      agent.tools['img2'] = ToolRun('img2')
        ..status = ToolStatus.failed
        ..output = 'Daily picture limit of 50 credits reached';
      await pumpLook(tester, const Look(), _view(agent));
      expect(find.byType(ImageToolCard), findsNothing);
      expect(find.byType(ToolCallView), findsOneWidget);
    });
  });

  group('the details as the host sends them', () {
    test('parsed, with the shape of the pictures', () {
      final j = ImageJob.fromDetails({
        ..._details([{'status': 'done', 'file': '/a.png'}, {'status': 'stopped', 'maybeBilled': true}]),
        'size': '1536x1024',
      })!;
      expect(j.aspect, 1.5);
      expect(j.done, 1);
      expect(j.running, isFalse);
      expect(j.slots[1].status, ImageSlotStatus.stopped);
      expect(j.slots[1].maybeBilled, isTrue);
      expect(j.cheapest, isTrue);
    });
    test('anything else is not one', () {
      expect(ImageJob.fromDetails(null), isNull);
      expect(ImageJob.fromDetails({'jobId': 'x'}), isNull);
      expect(ImageJob.fromDetails({'model': 'm', 'slots': []}), isNull);
      expect(ImageJob.fromDetails({'model': 'm', 'slots': [{}], 'size': 'odd'})!.aspect, 1);
    });
    test('a saved chat brings the pictures back (toolResult details)', () {
      final entries = <ChatEntry>[];
      final tools = <String, ToolRun>{};
      AgentController.addSavedMessage({
        'role': 'toolResult',
        'toolCallId': 't1',
        'content': [{'type': 'text', 'text': 'Made 1 of 1'}],
        'details': _details([{'status': 'done', 'file': '/x.png'}]),
        'isError': false,
      }, entries, tools);
      expect(tools['t1']!.imageJob!.slots.single.file, '/x.png');
    });
  });

  group('over the limit the user is asked, with no Always', () {
    for (final look in _looks) {
      testWidgets('golden: the spending card ${look.name}', (tester) async {
        final host = FakeHost();
        final agent = newAgent();
        await pumpLook(tester, look, Scaffold(body: ListView(children: [ApprovalCards(features: agent.features)])), height: 420);
        host.emit({
          'type': 'approval',
          'approvalId': 'a9',
          'toolName': 'generate_image',
          'summary': '3 × gpt-image (1024x1024) ≈ 12 credits\nA minimal coffee shop logo',
          'reason': 'Over your picture limit without asking',
          'key': '',
        });
        await frames(tester);
        expect(find.text(look.language == 'id' ? 'Selalu' : 'Always'), findsNothing);
        expect(find.text(look.language == 'id' ? 'Buat gambar ini?' : 'Make these pictures?'), findsOneWidget);
        expect(find.textContaining(look.language == 'id' ? 'Lewati semua' : 'Bypass all'), findsNothing);
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('image_approval_${look.name}')));
      });
    }
  });

  group('Settings → Pictures', () {
    Map<String, dynamic> usage({double credits = 17.5, int count = 7}) => {
      'day': '2026-11-03',
      'count': count,
      'credits': credits,
      'cheapest': 'gemini-3.1-flash-image',
      'modelsError': null,
      'models': [
        {'id': 'gpt-image', 'name': 'GPT Image', 'credits': 4},
        {'id': 'gemini-3.1-flash-image', 'name': 'Gemini', 'credits': 2.5},
      ],
    };

    for (final look in _looks) {
      testWidgets('golden: the screen ${look.name}', (tester) async {
        final host = FakeHost()..answers['image_usage'] = (_) => usage();
        host.stored['dailyBudget'] = 120;
        final agent = newAgent();
        agent.integrations.settings = AppSettings(host.publicSettings());
        await pumpLook(tester, look, ImageSettingsScreen(agent: agent), height: 2000);
        await frames(tester);
        expect(layoutErrors, isEmpty);
        await expectLater(find.byType(Scaffold).first, matchesGoldenFile(golden('image_settings_${look.name}')));
      });
    }

    testWidgets('choices are saved to the host', (tester) async {
      final host = FakeHost()..answers['image_usage'] = (_) => usage();
      final agent = newAgent();
      agent.integrations.settings = AppSettings(host.publicSettings());
      await pumpLook(tester, const Look(), ImageSettingsScreen(agent: agent), height: 2000);
      await frames(tester);
      Map<String, dynamic> lastSet() => (host.sent('settings_set').last['settings'] as Map).cast<String, dynamic>();

      await tester.tap(find.text('gpt-image'));
      await frames(tester);
      expect(lastSet(), {'imageModel': 'gpt-image'});

      await tester.tap(find.text('Always ask'));
      await frames(tester);
      expect(lastSet(), {'imageAutoCredits': 0});

      await tester.tap(find.text('8'));
      await frames(tester);
      expect(lastSet(), {'imageMaxPerCall': 8});

      await tester.tap(find.text('Refuse'));
      await frames(tester);
      expect(lastSet(), {'imageOverLimit': 'refuse'});
      expect(find.textContaining('Nothing over the limit is made'), findsOneWidget);

      await tester.tap(find.text('Agent can make pictures').first);
      await frames(tester);
      expect(lastSet(), {'imageAgentTool': false});
      expect(find.text('The agent does not make pictures'), findsOneWidget);
    });

    testWidgets('a default model the router no longer offers is shown, and says the cheapest is used', (tester) async {
      final host = FakeHost()..answers['image_usage'] = (_) => usage();
      host.stored['imageModel'] = 'old-image-model';
      final agent = newAgent();
      agent.integrations.settings = AppSettings(host.publicSettings());
      await pumpLook(tester, const Look(), ImageSettingsScreen(agent: agent), height: 2000);
      await frames(tester);
      expect(find.text('old-image-model'), findsOneWidget);
      expect(find.text('No longer offered: the cheapest is used instead'), findsOneWidget);
    });

    testWidgets('an older host without picture settings is told to update', (tester) async {
      final host = FakeHost()..answers['image_usage'] = (_) => HostError('Unknown command: image_usage');
      final agent = newAgent();
      agent.integrations.settings = AppSettings(const {'dns': 'cloudflare'});
      host.answers['settings_get'] = (_) => {'dns': 'cloudflare'};
      await pumpLook(tester, const Look(), ImageSettingsScreen(agent: agent), height: 2000);
      await frames(tester);
      expect(find.textContaining('too old for picture limits'), findsOneWidget);
    });

    test('the summary line for the Settings row', () {
      applyLook(const Look());
      expect(imageLimitsSummary(null), 'Up to 10 credits without asking • 4 per request • 50 credits a day');
      expect(
        imageLimitsSummary(AppSettings(const {'imageAutoCredits': 0, 'imageMaxPerCall': 2, 'imageDailyCredits': 0})),
        'Always ask • 2 per request • No daily picture limit',
      );
      expect(imageLimitsSummary(AppSettings(const {'imageAgentTool': false})), 'The agent does not make pictures');
    });
  });
}

// 96x96 PNGs: a warm gradient with a cup, and a green one with a leaf (drawn offline, kept small).
const _coffeePng = 'iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAIAAABt+uBvAAAFC0lEQVR42u3a13MXVRQH8O9/YxcbipUaaqihhtAJNb1CSO+9994r6b1X0iuBEAgQIAQRRRB1xjfdnw8/NTucycPeu6Oemfv0fdvP7J5z7r2LX59M/7J4/efHU68WJl89mvjp4fjLB2Mv5kdfzI/8eH/4+b2h53eHfpgb/P7OwLPb/c9mr3032/f0Vu/TmZ5vb3Y/udG1ON21eL3z8VTHwlT7wmTbo4nWh+MtD8aaH4w2zY803h9WVsO9ofq7g3VzA7Vz/TV3rlXf7qua7a2c7a241VMx010+03X1ZmfZjY7S6faS6bbi621FU62FUy0Fk80FE03544154w25Y/U5o/XZo3VZI7WZwzUZQ9XpQ1Xpg5VpAxWpAxUp/eXJ164m9ZUl9pUm9JbE9xTHdRcpK7arMKazILozP6ojL7I9N6ItJ7wtO6w1O7QlK7QlM6Q5I7gpPagxLbAxNaAhxb8+xa8+2bcuyac20acmwbsm3qs6zrMq1gOsQ+hUxbqDdQidypgrYB1CpyLaDaxD6JRHXQbrEDrlkZfAOoTO1QhXsA6hUxZuAGKd1+qUhrmAdQid0jBnsA6hUxLqBNYhdIpDHME6hE5xsANYh9ApCrIH6xA6hYF2YB1CpyDAFqxD6BT424B1CJ18AxDrvF4nz88arEPo5PlagXUInVyfi2AdQifH+wJYh9DJ9joP1iF0sj3PgXUInSyPs2AdQifT4wxYh9DJdLcE6xA6GVcsIV/n999eqnWUUK2jhPrqpLudhvx3xwCkencMQKp3xwCkq07a5VOQ/2Upj63+spRQ/WUpob46aZdOQn7dUR5bXXeUUF13lFBfnVTXE5BflZXHVldlJVRXZSXUVyfF5Tjk96w/gZb2LAOQqmcZgHTVSXE5BvkdXXlsdUdXQnVHV0J9dZKdj0L+vLP8jq6E+uokOR2B/Glw+R3dAKSrTqKjBeTPysvv6Eqor06igwX+5zsJWifB/jBYh9CJtzMH6xA6cbaHwDqETpztQQidd8QtOTqxNgcgdN4RCSRDJ8Z6P4TOO+KWHJ0Yq30QOu+IW3J0oi/uhbiqLBZIik7UBTOI61lCgeToRJ43g7iOLhSIXlrpRJ7bA3Hzjo5AWulEnNsNcdOgnkAa6YSf3QVxs7IEiCV1x5hrpRN+ZifE7SQkAC2pysZcK50wyx0Qt8+SALSkZxlzrXRCT2+HuF2oBKAlHf0vII10Qk6ZQtweXQbQP+cdY66VTsjJbRB3giF/3jHmWukEn9gKcec78uedvwFpoxOkAIk7/ZI/7xhzrXSCjm+BuLNBCUBL5h1jrpVO4LHNEHdyquMkrZVOwNFNEHeurCeQRjr+RzZC3Km7jkBa6fhbmEDcnYRQAg1nZULH7/AGiLuxEQskRcfXfD3E3WcJBZKj42u+DuJu+4QCydHxObQW4u5CBQPJ0PE+qAAJuykWCiRHx+vAGoi7RxcKJEfHa/9qiPvL4N8yKxM6nvu+wX/jHwxBOh57vwbrEDruZl+BdQgdd7MvwTqEzpU9X4B1CB233Z+DdQgdt12rwDqEzuWdq8A6hM6lHZ+BdQgd1+2fgnUIHVfTlWAdQsfF9BOwDqHjvO1jsA6h47z1I7AOoeO05UOwDqHjuPkDsA6h47BpBViH0HHYuAKsQ+jYm7wP1iF07EzeA+sQOnYb3gXrEDq2698B6xA6NuveBusQOtZr3wLrEDrWa94E6xA6Vqvf+ANG1+eb5j7z5gAAAABJRU5ErkJggg==';
const _leafPng = 'iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAIAAABt+uBvAAAEaUlEQVR42u3axW9cVxTH8d9fVUzDDjvgxCEzM4+ZmZmZmZmZme0xUxxq2mbZXTvRSFEUyUet3xt7/HSk7+otP4ure895eP/56N1fh2//PDj+Y//Np72jT7uHv+8cfNze/7C1/2Fz7/3G7ruNnbfy7eP1reO1zTerG0cr8sNl+eHS+sHi2v7C6t78yt788u7c0s7s4vbMwtb0wtbU/Obk3MbErHx8Rj42vT42tTY6uToyuTo8sTI0vjw4tjQwutg/stg3vNA7NN8zOKeoe2C2q3+ms2+6o3e6vWeqrXuytWuipXO8uXO8qWOsqX20sW2koXWkvmW4rnmotmmwpnGgunGgqqG/sr6vsq63ora3vKanrLq7tKqrpKqruLKzqKKjsLy9oKwtv7Qtv6Q1r7glt6g5p6g5u7Apq6AxM78hI68hPbc+LacuNbs2NasmJasmObM6KaMqMb0yIa0yPrUiLqU8NrksBqxD6HwBYh1CJ6k0GqxD6CSWRIF1CJ2E4kiwDqETXxQB1iF04orCwTqETmxhGFiH0IkpCAXrEDrR+SFgHUInOj8YrEPoROUFgXUIncjcILAOoROREwjWIXTCswPAOoROWLY/WIfQCc3yA+sQOiGZvmAdQic4wwesQ+gEZ3iDdQidoHQvsA6hE5jmCdYhdAJSPcA6hI6/Aoh1CB2/FHewDqHjm+wG1iF0fJJcwTqEjneiDKxD6HgnuoB1CB2vBGewDqHjGe8E1iF0POIcwTqEjnucA1iH0HGLdYC66fzz92f10XGNsce56CgUTtcZ68ii7XBmOqdG+a6z1JFF20LVOmK5fKfz7UfV6bhE2UB1OuLSnKTzNVXoOEdaQxo6ykTXcYqwgug6otP8R52viajjGG4JiekoE0vHIdwC0tNRJoqOfZg5JKmjTLiOXagZLvSpTCdcxzbEDFLVUSZQxzbEFBflNni6BOrYBJtAlJeEeuooEqhjHWQMCesoE6JjFWgEUd7oUtWxDDSEKBMM9dRRJFDHIsAA5zvfUamOIoE65v76EGs2KEkdMz89iDU5VTcdRcJ1TH11IeJcWXo6pr46EHfqLjEdEx8diL6xkZKOsfdrqGifdXFP5W91jLxeQXXbPgnoGHq9hKp3oRfiNniSjoHnC5z9pli8Z4RM+EuC1tH3eI5z2aOf43znf+nouWtD3f4yUCiIuJMQqKPr9gzS+AdDRTq6bk/BOoSOjqsWWIfQeS3TAusQOq9cnoB1CJ2XLo/BOoTOC+dHYB1C57nTQ7AOoaPtqAnWIXS0HR+AdQidZw73wTqEzlP7e2AdQkfL7i5Yh9B5YnsHrEPoPFYAsQ6h88jmNliH0HlofQusQ+hoWmmAdQgdTaubYB1C54HlDbAOoXPf4jpYh9C5Z34NrEPo3DW/CtYhdO6YXQHrEDq3TS+DdQidWyZfgFjnRB0N49/AOoSOhvElsA6hc9PoV7AOoXPD8BewDqFz3eBnsA6hc83gJ7AOoXNV/0ewDqFzRe+HfwFDG5iich7dVAAAAABJRU5ErkJggg==';
