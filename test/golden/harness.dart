import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_client.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/agent/clock.dart';
import 'package:griphub_agent/agent/subagents.dart';
import 'package:griphub_agent/ui/theme.dart';

/// Every golden renders at this instant, so live durations are stable.
final goldenNow = DateTime(2026, 10, 27, 12);

void pinClock() {
  SubagentState.clock = () => goldenNow;
  clock = () => goldenNow;
}

/// Loads every font in the test FontManifest (Geist, GeistMono, Lucide, ...)
/// so goldens show real text and icons instead of Ahem boxes.
Future<void> loadAppFonts() async {
  final manifest = jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final family in manifest.cast<Map>()) {
    final loader = FontLoader(family['family'] as String);
    for (final font in (family['fonts'] as List).cast<Map>()) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
}

/// An answer from [FakeHost.answers] that fails the command the way the host does ({ok: false, error}).
class HostError {
  const HostError(this.message);
  final String message;
}

/// A fake agent host on the platform channels. It answers `settings_get` /
/// `settings_set` the way agent/src/integrations.ts does (null or "" clears a
/// key; publicSettings fills defaults), records every command, and can push
/// host records into the app.
class FakeHost {
  FakeHost() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(const MethodChannel('griphub/agent'), (call) async {
      calls.add(call);
      switch (call.method) {
        case 'send':
          final cmd = (jsonDecode(call.arguments as String) as Map).cast<String, dynamic>();
          commands.add(cmd);
          final data = _answer(cmd);
          // A late answer: the host is still working on it (a test completes the future when it wants the reply).
          if (data is Future) {
            data.then(
              (v) => emit({'type': 'response', 'id': cmd['id'], 'ok': true, 'data': v}),
              onError: (Object e) => emit({'type': 'response', 'id': cmd['id'], 'ok': false, 'error': '$e'}),
            );
            return null;
          }
          if (data is HostError) {
            Future<void>.microtask(() => emit({'type': 'response', 'id': cmd['id'], 'ok': false, 'error': data.message}));
          } else if (data != _noReply) {
            Future<void>.microtask(() => emit({'type': 'response', 'id': cmd['id'], 'ok': true, 'data': data}));
          }
          return null;
        case 'notify':
          notifications.add((call.arguments as Map).cast<String, dynamic>());
          return null;
        default:
          return methods[call.method]?.call(call);
      }
    });
    m.setMockStreamHandler(
      const EventChannel('griphub/agent/events'),
      MockStreamHandler.inline(onListen: (_, sink) {
        _sink = sink;
      }, onCancel: (_) {}),
    );
  }

  static const _noReply = Object();
  MockStreamHandlerEventSink? _sink;
  final commands = <Map<String, dynamic>>[];
  final calls = <MethodCall>[];
  final notifications = <Map<String, dynamic>>[];

  /// Chat files `sessions` lists, and the ones opened.
  final sessions = <String>[];
  final opened = <String>[];

  /// Raw stored settings, like integrations.json `settings`.
  final stored = <String, dynamic>{};

  Map<String, dynamic> publicSettings() => {
    'dns': 'cloudflare',
    'approvalMode': stored['approvalMode'] ?? 'ask_risky',
    'fallbackModels': const [],
    'dailyBudget': stored['dailyBudget'] ?? 0,
    'subagentCreditLimit': stored['subagentCreditLimit'] ?? 50,
    'subagentMinutesLimit': stored['subagentMinutesLimit'] ?? 30,
    'subagentApprovalMode': stored['subagentApprovalMode'] ?? stored['approvalMode'] ?? 'ask_risky',
    'subagentNotifyDone': stored['subagentNotifyDone'] ?? true,
    'subagentNotifyFailed': stored['subagentNotifyFailed'] ?? true,
    'subagentNotifyApproval': stored['subagentNotifyApproval'] ?? true,
    'subagentNotifyRunning': stored['subagentNotifyRunning'] ?? true,
    'subagentApprovalOverride': stored.containsKey('subagentApprovalMode'),
  };

  /// Answers for the app's other calls to the platform side ('clipboardImage', ...), by method name.
  final methods = <String, Object? Function(MethodCall call)>{};

  /// Answers for commands a test needs beyond the defaults below, by command type. A [HostError] fails the command; a
  /// [Future] answers when it completes (an error then fails it), for work the host is still doing.
  final answers = <String, Object? Function(Map<String, dynamic> cmd)>{};

  Object? _answer(Map<String, dynamic> cmd) {
    final custom = answers[cmd['type']];
    if (custom != null) return custom(cmd);
    switch (cmd['type']) {
      case 'settings_get':
        return publicSettings();
      case 'settings_set':
        final patch = (cmd['settings'] as Map).cast<String, dynamic>();
        patch.forEach((k, v) {
          if (v == null || v == '') {
            stored.remove(k);
          } else {
            stored[k] = v;
          }
        });
        return publicSettings();
      case 'sessions':
        return [
          for (final path in sessions) {'path': path, 'id': path, 'name': path, 'modified': 0, 'messageCount': 1, 'firstMessage': ''},
        ];
      case 'subagent_list':
        return const [];
      case 'new_session':
        return {'sessionFile': 'new.jsonl', 'sessionId': 'new', 'cwd': cmd['cwd'] ?? '/workspace'};
      case 'abort':
        return null;
      case 'open_session':
        opened.add(cmd['path'] as String);
        return {'sessionFile': cmd['path'], 'sessionId': cmd['path']};
      case 'messages':
        return const [];
      default:
        return null;
    }
  }

  void emit(Map<String, dynamic> record) => _sink?.success({'kind': 'stdout', 'line': jsonEncode(record)});

  List<Map<String, dynamic>> sent(String type) => commands.where((c) => c['type'] == type).toList();
}

/// One render configuration of the app chrome around a widget.
class Look {
  const Look({this.dark = false, this.language = 'en', this.compact = false, this.textScale = 1, this.width = 390});
  final bool dark;
  final String language;
  final bool compact;
  final double textScale;
  final double width;

  String get name =>
      '${dark ? 'dark' : 'light'}_$language${compact ? '_compact' : ''}'
      '${textScale == 1 ? '' : '_x$textScale'}${width == 390 ? '' : '_w${width.toInt()}'}';
}

void applyLook(Look look) {
  final a = Appearance.instance;
  a.language = look.language;
  a.compact = look.compact;
  a.textScale = look.textScale;
  a.accent = 0;
}

/// Pumps [child] inside the app's real theme, at a phone size.
Future<void> pumpLook(WidgetTester tester, Look look, Widget child, {double height = 844}) async {
  applyLook(look);
  pinClock();
  tester.view.devicePixelRatio = 2;
  tester.view.physicalSize = Size(look.width * 2, height * 2);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      themeMode: look.dark ? ThemeMode.dark : ThemeMode.light,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(look.textScale)),
        child: child!,
      ),
      home: child,
    ),
  );
  // Indeterminate progress bars never settle; a fixed pump is enough.
  await tester.pump(const Duration(milliseconds: 300));
  collectLayoutErrors(tester, look.name);
}

/// Layout errors (overflows) are findings, not test failures: record them so
/// the golden still renders with Flutter's yellow/black overflow stripes.
final layoutErrors = <String>[];

void collectLayoutErrors(WidgetTester tester, String where) {
  final e = tester.takeException();
  if (e != null) {
    final line = '[$where] ${e.toString().split('\n').first}';
    layoutErrors.add(line);
    // ignore: avoid_print
    print('LAYOUT $line');
  }
}

AgentController newAgent() => AgentController(AgentClient());

/// Golden output folder; one file per scenario.
String golden(String name) => 'goldens/$name.png';

bool get updatingGoldens => autoUpdateGoldenFiles || Platform.environment['UPDATE_GOLDENS'] == '1';
