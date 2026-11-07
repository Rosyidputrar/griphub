// The home-screen widgets' snapshot (lib/agent/widget_sync.dart, Fitur 7): what the widgets show is the app's real
// state at that moment: the chat at work, background jobs, subagents, tasks, the next schedule, approvals, credits
// and the model; a calm empty state; and a push only when something changed.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_client.dart';
import 'package:griphub_agent/agent/agent_controller.dart';
import 'package:griphub_agent/agent/features.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/agent/router_account.dart';
import 'package:griphub_agent/agent/widget_sync.dart';

import 'golden/harness.dart';

final _now = DateTime(2026, 11, 7, 10, 0);

WidgetSync sync(AgentController agent, {List<String>? sent}) =>
    WidgetSync(agent, translate: (s) => s, now: () => _now, dark: () => true, send: (j) async => sent?.add(j));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('nothing running: the calm empty state, with the next task when there is one', () {
    FakeHost();
    final agent = AgentController(AgentClient());
    var s = sync(agent).snapshot();
    expect(s['rows'], isEmpty);
    expect(s['empty'], 'Nothing running');
    expect(s['emptySub'], '');
    agent.features.schedules = [
      ScheduleInfo({'id': 'a', 'name': 'Laporan pagi', 'prompt': 'x', 'enabled': true, 'dailyAt': '14:00'}),
    ];
    s = sync(agent).snapshot();
    expect(s['emptySub'], 'Next task: Laporan pagi at 14:00');
    expect((s['rows'] as List).single, containsPair('kind', 'schedule'));
  });

  test('what is going on, each row opening its own place', () {
    FakeHost();
    final agent = AgentController(AgentClient())
      ..sessionFile = '/s/a.jsonl'
      ..sessionName = 'Refactor auth'
      ..busy = true
      ..turnStartedAt = _now.subtract(const Duration(minutes: 3))
      ..model = ModelInfo(const {'provider': 'griphub', 'id': 'kimi-k3', 'name': 'Kimi K3'});
    agent.jobStore.apply({'id': 'j1', 'sessionFile': '/s/b.jsonl', 'command': 'npm run build', 'label': 'Build', 'cwd': '/w', 'status': 'running', 'limitMinutes': 30, 'elapsedMs': 120000});
    agent.subagentStore.applyRecord({
      'type': 'subagent_started',
      'subagent': {'id': 'sa1', 'parentSessionFile': '/s/c.jsonl', 'parentTitle': 'Riset', 'task': 'cari', 'status': 'running', 'profile': 'read'},
    });
    final s = sync(agent).snapshot();
    final rows = (s['rows'] as List).cast<Map>();
    expect(rows.first['title'], 'Working in Refactor auth');
    expect(rows.first['sub'], 'For 3m');
    expect(rows.first['launch'], {'action': 'open_chat', 'path': '/s/a.jsonl'});
    final job = rows.firstWhere((r) => r['kind'] == 'job');
    expect(job['title'], 'Build');
    expect(job['launch'], {'action': 'open_chat', 'path': '/s/b.jsonl'});
    final sub = rows.singleWhere((r) => r['kind'] == 'subagent');
    expect(sub['title'], 'A subagent is working');
    expect(sub['sub'], 'For Riset');
    expect(sub['launch'], {'action': 'open_chat', 'path': '/s/c.jsonl'});
    expect(s['model'], 'Kimi K3');
    expect(s['dark'], true);
  });

  test('the approvals badge counts what waits, and opens the chat it waits in', () async {
    final host = FakeHost();
    final agent = AgentController(AgentClient())..sessionFile = '/s/a.jsonl';
    expect(sync(agent).snapshot()['approvals'], 0);
    host.emit({'type': 'approval', 'approvalId': 'a1', 'toolName': 'bash', 'summary': 'rm', 'reason': 'x'});
    host.emit({'type': 'approval', 'approvalId': 'a2', 'toolName': 'bash', 'summary': 'rm', 'reason': 'x'});
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    final s = sync(agent).snapshot();
    expect(s['approvals'], 2);
    expect(s['approvalsLaunch'], {'action': 'open_chat', 'path': '/s/a.jsonl'});
    host.emit({'type': 'approval_dismiss', 'approvalId': 'a1'});
    host.emit({'type': 'approval_dismiss', 'approvalId': 'a2'});
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);
    expect(sync(agent).snapshot()['approvals'], 0, reason: 'the badge goes when nothing waits');
  });

  test('credits from the router, and the model the smart router picked last', () {
    FakeHost();
    final agent = AgentController(AgentClient())
      ..model = ModelInfo(const {'provider': 'griphub', 'id': 'kimi-k3', 'name': 'Kimi K3'})
      ..smartRouter = const SmartRouterState(enabled: true, auto: true)
      ..routingLog = [
        RoutingDecision({'kind': 'route', 'turn': 0, 'model': 'glm-5.3-flash', 'modelName': 'GLM 5.3 Flash', 'reason': ''}),
      ];
    agent.integrations.router = RouterAccount({
      'account': {'balance': 1234.5},
    });
    final s = sync(agent).snapshot();
    expect(s['credits'], '1235 credits');
    expect(s['model'], 'GLM 5.3 Flash · automatic');
  });

  test('the next scheduled task: daily times roll to tomorrow, intervals count from the last run', () {
    ScheduleInfo daily(String at) => ScheduleInfo({'id': at, 'name': at, 'prompt': '', 'enabled': true, 'dailyAt': at});
    expect(WidgetSync.nextScheduled([daily('09:00'), daily('11:30')], _now)!.$2, DateTime(2026, 11, 7, 11, 30));
    expect(WidgetSync.nextScheduled([daily('09:00')], _now)!.$2, DateTime(2026, 11, 8, 9, 0));
    final every = ScheduleInfo({'id': 'e', 'name': 'e', 'prompt': '', 'enabled': true, 'everyMinutes': 30, 'lastRun': _now.subtract(const Duration(minutes: 10)).millisecondsSinceEpoch});
    expect(WidgetSync.nextScheduled([every, daily('11:30')], _now)!.$2, _now.add(const Duration(minutes: 20)));
    final off = ScheduleInfo({'id': 'x', 'name': 'x', 'prompt': '', 'enabled': false, 'dailyAt': '10:05'});
    expect(WidgetSync.nextScheduled([off], _now), isNull);
  });

  test('pushed only when something changed, not on every tick', () async {
    FakeHost();
    final agent = AgentController(AgentClient());
    final sent = <String>[];
    final w = sync(agent, sent: sent);
    await w.push();
    await w.push();
    expect(sent, hasLength(1));
    agent.busy = true;
    await w.push();
    expect(sent, hasLength(2));
    expect((jsonDecode(sent.last)['rows'] as List).single['kind'], 'session');
  });
}
