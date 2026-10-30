import 'dart:convert';
import 'dart:io';

import 'package:griphub_agent/agent/agent_client.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/agent/agent_fs.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/files_ui_suite.dart';
import 'support/fs_screens_suite.dart';

/// The file screens on the phone's own disk.
class LocalVariant extends FsVariant {
  @override
  Directory makeDir() => Directory.systemTemp.createTempSync('files_ui_test_');

  /// An agent whose platform channels are stubbed: no host process, phone storage not granted.
  @override
  Future<AgentFs> makeFs() async => const LocalFs();

  /// Of the host's commands only `new_session` is answered (as host.ts does: the new chat's state), since the new chat
  /// sheet waits for the chat to exist before it closes.
  @override
  Future<AgentController> makeAgent(WidgetTester tester, Directory dir) async {
    final messenger = tester.binding.defaultBinaryMessenger;
    MockStreamHandlerEventSink? sink;
    messenger.setMockStreamHandler(
      const EventChannel('griphub/agent/events'),
      MockStreamHandler.inline(onListen: (_, s) {
        sink = s;
      }, onCancel: (_) {}),
    );
    messenger.setMockMethodCallHandler(const MethodChannel('griphub/agent'), (call) async {
      if (call.method == 'storageAccess') return {'available': true, 'granted': false, 'root': '/storage/emulated/0'};
      if (call.method == 'send') {
        final cmd = (jsonDecode(call.arguments as String) as Map).cast<String, dynamic>();
        if (cmd['type'] == 'new_session') {
          final state = {'sessionId': 'new', 'sessionFile': '${dir.path}/new.jsonl', 'cwd': cmd['cwd'] ?? dir.path};
          final line = jsonEncode({'type': 'response', 'id': cmd['id'], 'ok': true, 'data': state});
          Future<void>.microtask(() => sink?.success({'kind': 'stdout', 'line': line}));
        }
      }
      return null;
    });
    addTearDown(() {
      messenger.setMockStreamHandler(const EventChannel('griphub/agent/events'), null);
      messenger.setMockMethodCallHandler(const MethodChannel('griphub/agent'), null);
    });
    return AgentController(AgentClient())..info = {'workspace': dir.path};
  }
}

void main() => fsScreensSuite(LocalVariant());
