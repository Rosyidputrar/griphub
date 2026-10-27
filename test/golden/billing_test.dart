// Billing UI from GripHub Router data: the Usage account card and request
// list, the subagent cost panel (model, thinking level, live credits), and
// the model picker's prices. Data comes from the anonymised fixtures shape
// the host sends (router_account).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/agent/router_account.dart';
import 'package:griphub_agent/agent/subagents.dart';
import 'package:griphub_agent/ui/subagent_card.dart';
import 'package:griphub_agent/ui/usage_screen.dart';

import 'harness.dart';

int _ms(Duration ago) => goldenNow.subtract(ago).millisecondsSinceEpoch;

RouterAccount account({double balance = 19.8, double granted = 1109.39, bool real = true}) => RouterAccount({
  'account': {
    'balance': balance,
    'granted': granted,
    'used': granted - balance,
    'suspended': false,
    'discountRate': 0,
    'source': 'user-usage',
    'fetchedAt': _ms(const Duration(minutes: 2)),
    'batches': [
      {'credits': 6.55, 'expiresAt': goldenNow.add(const Duration(days: 3)).toIso8601String()},
      {'credits': 40, 'expiresAt': goldenNow.add(const Duration(days: 25)).toIso8601String()},
    ],
    'byModel': [
      {'model': 'claude-sonnet-5', 'requests': 3639, 'inputTokens': 263000000, 'outputTokens': 1200000, 'credits': 658.79},
      {'model': 'claude-opus-5.5', 'requests': 145, 'inputTokens': 12000000, 'outputTokens': 35000, 'credits': 49.31},
      {'model': 'gemini-3.1-flash-image', 'requests': 1, 'images': 1, 'credits': 2.5},
    ],
  },
  'spentToday': 52.46,
  'spentTodayReal': real,
  'daily': {'2026-10-25': 31.2, '2026-10-26': 44.0, '2026-10-27': 52.46},
  'requests': [
    {'id': 5, 'model': 'claude-opus-5.5', 'endpoint': '/v1/chat/completions', 'ok': true, 'at': _ms(const Duration(minutes: 3)), 'inputTokens': 86101, 'cacheReadTokens': 82472, 'outputTokens': 2788, 'credits': 0.344404, 'thinkingEffort': 'high'},
    {'id': 4, 'model': 'claude-opus-5.5', 'endpoint': '/v1/chat/completions', 'ok': true, 'at': _ms(const Duration(minutes: 4)), 'inputTokens': 135, 'outputTokens': 16, 'credits': 0.1, 'floor': 0.1},
    {'id': 3, 'model': 'gpt-5.6-luna', 'endpoint': '/v1/responses', 'ok': true, 'at': _ms(const Duration(minutes: 5)), 'inputTokens': 1700, 'outputTokens': 300, 'credits': 0.01, 'floor': 0.01},
    {'id': 2, 'model': 'kimi-k2.7', 'endpoint': '/v1/chat/completions', 'ok': false, 'error': 'Upstream model reached its output limit without returning an answer.', 'at': _ms(const Duration(minutes: 9)), 'inputTokens': 19, 'outputTokens': 16, 'credits': null},
  ],
});

SubagentState subagent({String status = 'running'}) {
  final store = SubagentStore();
  store.applyRecord({
    'type': 'subagent_started',
    'subagent': {
      'id': 's1',
      'parentSessionFile': 'chat.jsonl',
      'brief': 'Audit billing',
      'profile': 'read',
      'status': status,
      'createdAt': _ms(const Duration(minutes: 2)),
      'startedAt': _ms(const Duration(minutes: 2)),
      'currentTool': 'read',
      'currentArgs': 'agent/src/router.ts',
      'toolCalls': [],
      'queue': [],
      'inputTokens': 2400,
      'outputTokens': 6100,
      'cacheReadTokens': 164000,
      'cacheWriteTokens': 900,
      'credits': 1.27,
      'requests': 9,
      'flooredRequests': 4,
      'model': 'claude-opus-5.5',
      'modelName': 'Claude Opus 5.5',
      'thinkingLevel': 'high',
      'rate': 4,
    },
  });
  return store['s1']!;
}

Future<void> frames(WidgetTester tester, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() {
    layoutErrors.clear();
    pinClock();
  });

  group('router account model', () {
    test('parses real figures, low-balance and days left', () {
      final a = account();
      expect(a.balance, 19.8);
      expect(a.spentToday, 52.46);
      expect(a.lowBalance, isTrue, reason: '19.8 left at ~42 a day');
      expect(a.daysLeft()!.round(), 0);
      expect(a.nextExpiry!.credits, 6.55);
      expect(a.requests.where((r) => r.floor != null), hasLength(2));
      expect(a.requests.firstWhere((r) => r.endpoint == '/v1/responses').isSearch, isTrue);
      expect(account(balance: 900).lowBalance, isFalse);
    });

    test('missing fields never crash and read as zero / null', () {
      final a = RouterAccount(const {});
      expect(a.balance, 0);
      expect(a.requests, isEmpty);
      expect(a.daysLeft(), isNull);
      expect(a.source, 'credits');
    });
  });

  for (final look in const [Look(), Look(dark: true, language: 'id'), Look(language: 'id', textScale: 1.3, width: 320)]) {
    testWidgets('golden: account card + requests ${look.name}', (tester) async {
      FakeHost();
      final a = account();
      await pumpLook(
        tester,
        look,
        Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              AccountCard(account: a, budget: 60),
              const SizedBox(height: 16),
              RequestList(requests: a.requests),
            ],
          ),
        ),
        height: 1500,
      );
      await frames(tester);
      expect(layoutErrors, isEmpty);
      await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('usage_account_${look.name}')));
    });

    testWidgets('golden: subagent card + cost panel ${look.name}', (tester) async {
      FakeHost();
      final agent = newAgent();
      final s = subagent();
      await pumpLook(
        tester,
        look,
        Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [SubagentCard(state: s, agent: agent), const SizedBox(height: 16), SubagentCostPanel(state: s)],
          ),
        ),
        height: 900,
      );
      await frames(tester);
      expect(layoutErrors, isEmpty);
      expect(find.textContaining('Claude Opus 5.5'), findsWidgets);
      await expectLater(find.byType(Scaffold), matchesGoldenFile(golden('subagent_cost_${look.name}')));
    });
  }

  test('model pricing: promo only while it runs; unavailable models flagged', () {
    final m = ModelInfo({
      'provider': 'griphub',
      'id': 'gpt-6-astra',
      'pricing': {'credits': 5, 'list': 8, 'promo': 'GPT YES', 'promoEndsAt': '2999-01-01T00:00:00Z', 'floor': null, 'available': true},
    });
    expect(m.pricing!.onPromo, isTrue);
    final ended = ModelInfo({'provider': 'griphub', 'id': 'x', 'pricing': {'credits': 5, 'list': 8, 'promoEndsAt': '2000-01-01T00:00:00Z'}});
    expect(ended.pricing!.onPromo, isFalse);
    expect(ModelInfo({'provider': 'griphub', 'id': 'y', 'pricing': {'available': false}}).pricing!.available, isFalse);
    expect(ModelInfo({'provider': 'openai', 'id': 'z'}).pricing, isNull);
  });

  test('subagent status updates keep model, reasoning and cost, and add up', () {
    applyLook(const Look());
    final s = subagent();
    s.applyStatus({'status': 'running', 'credits': 1.5, 'requests': 10, 'thinkingLevel': 'high'});
    expect(s.credits, 1.5);
    expect(s.requests, 10);
    expect(s.modelName, 'Claude Opus 5.5');
    expect(s.totalTokens, 2400 + 6100 + 164000 + 900);
    expect(subagentModelLine(s), 'Claude Opus 5.5 · High');
  });
}
