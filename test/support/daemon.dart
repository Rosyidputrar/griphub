import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:griphub_agent/agent/agent_backend.dart';
import 'package:griphub_agent/agent/agent_client.dart';

/// The real host running as a daemon (agent/build/harness/host.mjs: host.ts bundled for the tests by
/// agent/test/build-harness.mjs), with a throwaway home, so Dart tests meet it the way the app does through ssh. The
/// attach program is the real `server/griphub-attach`.
///
/// GripHub's host only talks to GripHub Router; with a [MockModel] the router's chat completions are sent to it by a
/// preloaded fetch (agent/test/fixtures/router-redirect.mjs), and [useMockModel] saves a key and picks the model.
///
/// Needs the harness built and `node` on the PATH. Otherwise [unavailable] says what is missing and the tests skip,
/// unless `GRIPHUB_REQUIRE_NODE_SIDE` is set (CI), when they fail instead. Adapted from CoderRa's test/support.
class TestDaemon {
  TestDaemon._(this.home, this.sock, this._env);

  static const host = 'agent/build/harness/host.mjs';
  static const attach = 'server/griphub-attach';
  static const routerRedirect = 'agent/test/fixtures/router-redirect.mjs';

  static String get node => Platform.environment['NODE'] ?? 'node';

  static String? get unavailable {
    for (final f in [host, attach]) {
      if (!File(f).existsSync()) return 'run `node agent/test/build-harness.mjs` first: $f is missing';
    }
    try {
      if (Process.runSync(node, ['--version']).exitCode != 0) return 'node does not run';
    } on ProcessException {
      return 'node is not on the PATH (set NODE to its location)';
    }
    return null;
  }

  /// Passed to `skip:` of a test: null when the daemon can run.
  static String? get skip {
    final why = unavailable;
    if (why == null) return null;
    if (Platform.environment['GRIPHUB_REQUIRE_NODE_SIDE'] != null) throw StateError(why);
    return why;
  }

  final Directory home;
  final String sock;
  final Map<String, String> _env;
  Process? process;
  final stderrText = StringBuffer();

  String get workspace => '${home.path}/workspace';

  static Future<TestDaemon> start({
    MockModel? model,
    Map<String, String> env = const {},
    Directory? home,
    String? socket,
  }) async {
    home ??= Directory.systemTemp.createTempSync('gh-daemon-');
    final agentDir = '${home.path}/.pi/agent';
    Directory(agentDir).createSync(recursive: true);
    Directory('${home.path}/workspace').createSync(recursive: true);
    final sock = socket ?? '${home.path}/run/host.sock';
    final d = TestDaemon._(home, sock, {
      ...Platform.environment,
      'HOME': home.path,
      'PI_CODING_AGENT_DIR': agentDir,
      'GRIPHUB_WORKSPACE': '${home.path}/workspace',
      'GRIPHUB_DIR': '${home.path}/.griphub',
      'GRIPHUB_STORE_KEY': 'ab' * 32,
      'GRIPHUB_TEST_ROUTER': ?model?.baseUrl,
      'PI_SKIP_VERSION_CHECK': '1',
      'PI_TELEMETRY': '0',
      'GITHUB_TOKEN': '',
      'GH_TOKEN': '',
      'GRIPHUB_SOCK': sock,
      ...env,
    });
    await d.launch();
    return d;
  }

  /// Starts the process (again, after [kill]) on the same home and socket.
  Future<void> launch() async {
    final p = await Process.start(node, [
      '--import',
      File(routerRedirect).absolute.uri.toString(),
      host,
      '--listen',
      sock,
    ], environment: _env);
    process = p;
    final listening = Completer<void>();
    p.stderr.transform(utf8.decoder).listen((chunk) {
      stderrText.write(chunk);
      if (stderrText.toString().contains('listening on') && !listening.isCompleted) listening.complete();
    });
    p.stdout.drain<void>();
    unawaited(
      p.exitCode.then((c) {
        if (!listening.isCompleted) listening.completeError(StateError('the daemon exited early ($c):\n$stderrText'));
      }),
    );
    await listening.future.timeout(const Duration(seconds: 20));
  }

  /// What the app would run through ssh: the real attach program, pointed at this daemon's socket.
  LaunchSpec get launchSpec => LaunchSpec([node, attach], env: _env);

  /// Saves a GripHub key with the test model and picks it, as the app's onboarding would.
  static Future<void> useMockModel(AgentClient client) async {
    await client.call('custom_provider_save', {
      'provider': {
        'apiKey': 'sk-test',
        'models': [
          {'id': 'mock-1', 'name': 'Mock'},
        ],
      },
    });
    await client.call('set_model', {'provider': 'griphub', 'model': 'mock-1'});
  }

  Future<void> kill() async {
    final p = process;
    if (p == null) return;
    p.kill(ProcessSignal.sigkill);
    await p.exitCode;
    process = null;
  }

  Future<void> dispose() async {
    await kill();
    try {
      home.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// A pretend model: an OpenAI-compatible `/chat/completions` that answers from a script, and can hold an answer
/// half-way until the test lets it go (so a test can cut the connection while a reply is streaming).
class MockModel {
  MockModel._(this._server);

  final HttpServer _server;
  final script = <MockReply>[];
  var requests = 0;

  String get baseUrl => 'http://127.0.0.1:${_server.port}/v1';

  static Future<MockModel> start() async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    final m = MockModel._(server);
    server.listen(m._handle);
    return m;
  }

  Future<void> _handle(HttpRequest req) async {
    await utf8.decoder.bind(req).join();
    requests++;
    final reply = script.isEmpty ? MockReply(['ok']) : script.removeAt(0);
    // Without this Dart holds the first chunks back until the response is complete, which defeats holding one half-way.
    final res = req.response
      ..bufferOutput = false
      ..headers.contentType = ContentType('text', 'event-stream');
    void send(List<Map<String, Object?>> choices, [Map<String, Object?> extra = const {}]) {
      res.write(
        'data: ${jsonEncode({'id': 'mock', 'object': 'chat.completion.chunk', 'created': 0, 'model': 'mock-1', 'choices': choices, ...extra})}\n\n',
      );
    }

    if (reply.holdAfter == 0) {
      await res.flush();
      await reply.gate.future;
    }
    for (var i = 0; i < reply.chunks.length; i++) {
      if (i == reply.holdAfter && i > 0) {
        await res.flush();
        await reply.gate.future;
      }
      send([
        {
          'index': 0,
          'delta': {if (i == 0) 'role': 'assistant', 'content': reply.chunks[i]},
          'finish_reason': null,
        },
      ]);
      await res.flush();
    }
    final call = reply.toolCall;
    if (call != null) {
      send([
        {
          'index': 0,
          'delta': {
            if (reply.chunks.isEmpty) 'role': 'assistant',
            'tool_calls': [
              {
                'index': 0,
                'id': 'call_$requests',
                'type': 'function',
                'function': {'name': call.$1, 'arguments': jsonEncode(call.$2)},
              },
            ],
          },
          'finish_reason': null,
        },
      ]);
    }
    send([
      {'index': 0, 'delta': <String, Object?>{}, 'finish_reason': call != null ? 'tool_calls' : 'stop'},
    ]);
    send([], {
      'usage': {'prompt_tokens': 10, 'completion_tokens': 5, 'total_tokens': 15},
    });
    res.write('data: [DONE]\n\n');
    await res.close();
  }

  Future<void> close() => _server.close(force: true);
}

class MockReply {
  MockReply(this.chunks, {this.holdAfter = -1, this.toolCall});

  final List<String> chunks;

  /// Ends the reply with a call to this tool: (name, arguments).
  final (String, Map<String, Object?>)? toolCall;

  /// Stop after this many chunks until [release] is called; -1 = never stop.
  final int holdAfter;
  final gate = Completer<void>();

  void release() {
    if (!gate.isCompleted) gate.complete();
  }
}
