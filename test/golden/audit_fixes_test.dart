// The UI/UX audit's fixes: the home bar on a 320 dp phone, the search screen's folder name, labelled switches,
// 48 dp touch boxes, status colours that read as text in light mode, and errors in the user's words.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_client.dart';
import 'package:griphub_agent/agent/msg.dart';
import 'package:griphub_agent/agent/remote_profile.dart';
import 'package:griphub_agent/ui/chat_screen.dart';
import 'package:griphub_agent/ui/errors.dart';
import 'package:griphub_agent/ui/home_shell.dart';
import 'package:griphub_agent/ui/i18n.dart';
import 'package:griphub_agent/ui/kit.dart';
import 'package:griphub_agent/ui/search_screen.dart';
import 'package:griphub_agent/ui/settings_hub.dart';
import 'package:griphub_agent/ui/subagent_settings_screen.dart';
import 'package:griphub_agent/ui/theme.dart';

import 'harness.dart';

Future<void> frames(WidgetTester tester, [int n = 8]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (la > lb ? la + .05 : lb + .05) / (la > lb ? lb + .05 : la + .05);
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() {
    applyLook(const Look());
    layoutErrors.clear();
  });

  testWidgets('the home bar fits a 320 dp phone: its tabs give way to 48 dp instead of overflowing', (tester) async {
    FakeHost();
    await pumpLook(tester, const Look(language: 'id', textScale: 1.3, width: 320), HomeShell(agent: newAgent()));
    await frames(tester);
    expect(layoutErrors, isEmpty);
    expect(tester.takeException(), isNull);
    for (final tab in ['Beranda', 'Chat']) {
      final f = find.bySemanticsLabel(RegExp('^$tab'));
      if (f.evaluate().isEmpty) continue;
      expect(tester.getSize(f.first).width, greaterThanOrEqualTo(48));
    }
  });

  testWidgets('search names the folder in the app\'s language when there is no project yet', (tester) async {
    FakeHost();
    await pumpLook(tester, const Look(language: 'id'), SearchScreen(agent: newAgent()));
    await frames(tester);
    expect(find.text('Cari di semua file dalam proyek'), findsOneWidget);
    expect(find.textContaining('the project'), findsNothing);
  });

  test('the strings the audit found untranslated have Indonesian now', () {
    Appearance.instance.language = 'id';
    addTearDown(() => Appearance.instance.language = 'en');
    expect(tr('Delete local chats?'), 'Hapus chat lokal?');
    expect(tr('the project'), 'proyek');
    expect(tr('Loading…'), 'Memuat…');
    expect(tr('Branches'), 'Branch');
  });

  testWidgets('every switch says what it switches', (tester) async {
    final semantics = tester.ensureSemantics();
    FakeHost();
    await pumpLook(tester, const Look(), SubagentSettingsScreen(agent: newAgent()), height: 1600);
    await frames(tester);
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    expect(find.bySemanticsLabel(RegExp('^Same as the chat')), findsWidgets);
    semantics.dispose();
  });

  group('48 dp to touch', () {
    testWidgets('the composer\'s small controls', (tester) async {
      final semantics = tester.ensureSemantics();
      FakeHost();
      await pumpLook(tester, const Look(), ChatScreen(agent: newAgent()));
      await frames(tester);
      for (final label in ['Attach', 'Plan mode', 'Voice', 'Choose model']) {
        final size = tester.getSize(find.bySemanticsLabel(label).first);
        expect(size.height, greaterThanOrEqualTo(48), reason: label);
        expect(size.width, greaterThanOrEqualTo(48), reason: label);
      }
      // A tap on the margin, outside the 34 dp circle, still attaches.
      final attach = tester.getRect(find.bySemanticsLabel('Attach').first);
      await tester.tapAt(attach.topLeft + const Offset(3, 3));
      await frames(tester);
      expect(find.text('Photos'), findsOneWidget, reason: 'the attach sheet opened');
      expect(layoutErrors, isEmpty);
      semantics.dispose();
    });

    testWidgets('the home header and the segmented choices', (tester) async {
      final semantics = tester.ensureSemantics();
      FakeHost();
      await pumpLook(tester, const Look(), HomeShell(agent: newAgent()));
      await frames(tester);
      for (final label in ['Settings', 'Tasks', 'Accounts & servers']) {
        expect(tester.getSize(find.bySemanticsLabel(label).first).height, greaterThanOrEqualTo(48), reason: label);
      }
      await pumpLook(tester, const Look(), SettingsHub(agent: newAgent()), height: 1600);
      await frames(tester);
      expect(tester.getSize(find.bySemanticsLabel('Ask all')).height, greaterThanOrEqualTo(48));
      semantics.dispose();
    });
  });

  test('light mode: red, green and orange read as small text on the page and on cards (4.5:1)', () {
    const p = Palette.light;
    for (final (name, c) in [('danger', p.danger), ('success', p.success), ('warning', p.warning)]) {
      for (final (where, bg) in [('page', p.bg), ('card', p.surface)]) {
        expect(_contrast(c, bg), greaterThanOrEqualTo(4.5), reason: '$name on $where');
      }
    }
  });

  group('errors in the user\'s words', () {
    setUp(() => Appearance.instance.language = 'en');

    test('a bug never shows its Dart text', () {
      Object? caught;
      try {
        (null as dynamic) as Map;
      } catch (e) {
        caught = e;
      }
      expect(friendlyError(caught), 'Something went wrong. Try again.');
      expect(friendlyError(RangeError('index')), 'Something went wrong. Try again.');
      expect(friendlyError(null), 'Something went wrong. Try again.');
    });

    test('the network and timeouts say what to do', () {
      expect(friendlyError(TimeoutException('x')), startsWith('It took too long'));
      expect(friendlyError(const SocketException('Failed host lookup')), startsWith("Couldn't reach the network"));
      expect(friendlyError(const FormatException('Unexpected character', '{', 1)), startsWith('Got an answer'));
    });

    test('messages written for people go through, translated', () {
      expect(friendlyError(AgentError('Daily budget of 5 credits reached')), 'Daily budget of 5 credits reached');
      expect(friendlyError(StateError('The connection to the server took too long.')),
          'The connection to the server took too long.');
      expect(friendlyError(Exception('no space left')), 'no space left');
      expect(friendlyError('Not connected to the server.'), 'Not connected to the server.');
      expect(friendlyError(SetupCodeError(const Msg('That is not a setup code'))), 'That is not a setup code');
      expect(friendlyError(PlatformException(code: 'x', message: 'Camera unavailable')), 'Camera unavailable');
      Appearance.instance.language = 'id';
      expect(friendlyError(TimeoutException('x')), 'Terlalu lama. Periksa koneksi lalu coba lagi.');
      Appearance.instance.language = 'en';
    });

    testWidgets('an error alone on a screen offers to try again', (tester) async {
      var tries = 0;
      await pumpLook(
        tester,
        const Look(),
        Scaffold(body: Center(child: ErrorNotice(error: TimeoutException('x'), onRetry: () => tries++, center: true))),
      );
      expect(find.textContaining('It took too long'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      expect(tries, 1);
    });
  });
}
