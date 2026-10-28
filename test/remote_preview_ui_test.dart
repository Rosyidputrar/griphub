import 'dart:io';

import 'package:griphub_agent/agent/agent_fs.dart';
import 'package:griphub_agent/ui/preview_open.dart';
import 'package:griphub_agent/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/remote_rig.dart';

/// The helpers the screens use to open a page or a dev server that is on the server, with the whole server rig behind
/// them. The widget tester only lets real I/O finish inside runAsync, so the rig is built and used in there.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  testWidgets('hand the preview screen a URL the phone can open, for a page and for a dev server', (tester) async {
    final rig = (await tester.runAsync(RemoteRig.start))!;
    addTearDown(() => tester.runAsync(rig.dispose));
    final ws = rig.workspace;
    Directory('$ws/site/docs').createSync(recursive: true);
    File('$ws/site/style.css').writeAsStringSync('h1{color:red}');
    File('$ws/site/docs/a.html').writeAsStringSync('<link rel="stylesheet" href="../style.css"><p>doc</p>');

    final opened = <(String, String)>[];
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Builder(
          builder: (c) {
            context = c;
            return const SizedBox();
          },
        ),
      ),
    );
    final agent = rig.agent..cwd = '$ws/site';

    await tester.runAsync(
      () => openFilePreview(
        context,
        agent,
        title: 'a.html',
        path: '$ws/site/docs/a.html',
        opener: (c, t, u) async => opened.add((t, u)),
      ),
    );
    expect(opened.single.$1, 'a.html');
    expect(
      opened.single.$2,
      matches(RegExp(r'^http://127\.0\.0\.1:\d+/[0-9a-f]{24}/docs/a\.html$')),
      reason: 'the project folder was served, so ../style.css works',
    );
    final got = await tester.runAsync(() => RemoteRig.fetch(opened.single.$2));
    expect(got!.$1, 200);
    final css = await tester.runAsync(
      () => RemoteRig.fetch(Uri.parse(opened.single.$2).resolve('../style.css').toString()),
    );
    expect(css, (200, 'h1{color:red}'));

    opened.clear();
    final port = (await tester.runAsync(() => rig.devServer('<h1>dev</h1>')))!;
    await tester.runAsync(
      () =>
          openDevServer(context, agent, port, 'http://localhost:$port', opener: (c, t, u) async => opened.add((t, u))),
    );
    expect(opened.single.$1, 'localhost:$port');
    expect(opened.single.$2, startsWith('http://127.0.0.1:'));
    expect(opened.single.$2, isNot(contains(':$port/')), reason: "a local port of the phone, not the server's");
    expect(await tester.runAsync(() => RemoteRig.fetch(opened.single.$2)), (200, '<h1>dev</h1>'));
  }, skip: RemoteRig.skip != null);

  testWidgets(
    'text that is not the file yet (an editor\'s unsaved page, one the agent is still writing) gets the server as its base',
    (tester) async {
      final rig = (await tester.runAsync(RemoteRig.start))!;
      addTearDown(() => tester.runAsync(rig.dispose));
      final ws = rig.workspace;
      Directory('$ws/site/docs').createSync(recursive: true);
      File('$ws/site/style.css').writeAsStringSync('h1{color:red}');
      final agent = rig.agent..cwd = '$ws/site';

      // The page itself does not exist yet: only its folder does.
      final base = (await tester.runAsync(() => serverPageUrl(agent, '$ws/site/docs/new.html')))!;
      expect(base, matches(RegExp(r'^http://127\.0\.0\.1:\d+/[0-9a-f]{24}/docs/new\.html$')));
      final css = await tester.runAsync(() => RemoteRig.fetch(Uri.parse(base).resolve('../style.css').toString()));
      expect(css, (200, 'h1{color:red}'), reason: 'what the page links to loads from the server');

      // On the phone there is no server address: the folder on disk is the base.
      agent.fs = const LocalFs();
      expect(await tester.runAsync(() => serverPageUrl(agent, '$ws/site/docs/new.html')), isNull);
    },
    skip: RemoteRig.skip != null,
  );
}
