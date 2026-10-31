// UI-04: English text reached the Indonesian UI through helpers that never called tr() ('Invalid name', 'Path copied',
// 'Committed abc1234', 'No chats yet...', an English plural for servers). This scans the screens for text written
// straight into a widget and fails on any that is not on the list below: product names, example inputs and technical
// labels that stay as they are. A new one either goes through tr() or onto this list, on purpose. It is a simple scan:
// a literal inside an expression (one side of a ternary) is not seen.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/ui/i18n.dart';
import 'package:griphub_agent/ui/settings_hub.dart';
import 'package:griphub_agent/ui/theme.dart';

/// file:text pairs that are meant to stay as written.
const _allowed = {
  'network_screen.dart:https://dns.example/dns-query',
  'network_screen.dart:Search1API',
  'network_screen.dart:TinyFish',
  'chat_export.dart:Download/GripHub',
  'mcp_screen.dart:memory',
  'mcp_screen.dart:npx -y @modelcontextprotocol/server-memory',
  'mcp_screen.dart:URL',
  'mcp_screen.dart:https://example.com/mcp',
  'settings_hub.dart:GripHub AI Agent',
  'settings_hub.dart:griphubrouter.web.id',
  'message_views.dart:json',
  'message_views.dart:output',
  'message_views.dart:command',
  'tasks_screen.dart:owner/repo',
  'tasks_screen.dart:agent',
  'templates_screen.dart:review',
  'image_gen_screen.dart:gpt-image',
  'accounts_screen.dart:GitHub connected', // accounts_screen's _snack translates what it is given
  'accounts_screen.dart:Ov23…',
  'accounts_screen.dart:id_ed25519.pub',
  'folder_picker.dart:my-project',
  'skills_screen.dart:owner/repo/skills/name',
  'skills_screen.dart:skills.md',
  'settings_screen.dart:GripHub Router',
  'server_screen.dart:agent.example.com',
  'server_screen.dart:griphub1:…',
};

final _literal = RegExp(r"""(?:\bText|_snack)\('([A-Za-z][^'$]*)'|\b(?:tooltip|hintText|labelText|label|title|message): '([A-Za-z][^'$]*)'""");
final _interpolated = RegExp(r"""(?:\bText|_snack)\('([^']*\$[^']*)'|\b(?:tooltip|hintText|labelText|label|title|message): '([A-Za-z][^']*\$[^']*)'""");

void main() {
  test('no text is written straight into a screen except what is on the list', () {
    final found = <String>[];
    for (final file in Directory('lib/ui').listSync().whereType<File>().where((f) => f.path.endsWith('.dart'))) {
      final name = file.uri.pathSegments.last;
      if (name == 'i18n.dart') continue;
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].trimLeft().startsWith('//')) continue;
        for (final m in _literal.allMatches(lines[i])) {
          final text = m[1] ?? m[2]!;
          if (!_allowed.contains('$name:$text')) found.add('$name:${i + 1}: $text');
        }
        for (final m in _interpolated.allMatches(lines[i])) {
          final text = m[1] ?? m[2]!;
          // Cut short by a quote inside `${...}` (the expression goes on past it), or already translated inside: not
          // something this simple scan can judge.
          if ('{'.allMatches(text).length != '}'.allMatches(text).length || text.contains('tr(')) continue;
          // An interpolation of only values (a name, a number) has no words to translate.
          if (RegExp(r'[A-Za-z]{3,}').hasMatch(text.replaceAll(RegExp(r'\$\{[^}]*\}|\$\w+'), ''))) found.add('$name:${i + 1}: $text');
        }
      }
    }
    expect(found, isEmpty, reason: 'untranslated text in a widget:\n${found.join('\n')}');
  });

  test('the strings that were English in the Indonesian UI', () {
    Appearance.instance.language = 'id';
    addTearDown(() => Appearance.instance.language = 'en');
    expect(tr('Invalid name'), 'Nama tidak valid');
    expect(tr('{name} already exists').replaceAll('{name}', 'a.txt'), 'a.txt sudah ada');
    expect(tr('No chats yet. Tap + to start one.'), 'Belum ada chat. Ketuk + untuk memulai.');
    expect(tr('preparing…'), 'menyiapkan…');
    expect(serverCount(1), '1 server');
    expect(serverCount(3), '3 server');
    Appearance.instance.language = 'en';
    expect(serverCount(1), '1 server');
    expect(serverCount(3), '3 servers');
  });
}
