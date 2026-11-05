// The model board as the phone reads it (lib/agent/model_board.dart). The fixtures are what the host sends: the
// agent's own parsers run over the router's real responses (agent/test/fixtures), so the two sides cannot drift apart
// without this failing.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/model_board.dart';

Map<String, dynamic> _fixture(String name) =>
    (jsonDecode(File('test/fixtures/$name').readAsStringSync()) as Map).cast<String, dynamic>();

Served<StatusBoard> _status() => parseServedStatus(_fixture('served-status.json'));
Served<RankBoard> _rank() => parseServedRank(_fixture('served-rank.json'));

void main() {
  group('status', () {
    test('summary, totals and the 15 models of the fixture', () {
      final s = _status();
      expect(s.stale, isFalse);
      expect(s.fetchedAt, DateTime.fromMillisecondsSinceEpoch(1793851875063, isUtc: true).toLocal());
      final b = s.board;
      expect(b.window, '24h');
      expect(b.barMs, 1800000);
      expect([b.up, b.degraded, b.down, b.active, b.modelCount], [34, 2, 1, 34, 49]);
      expect(b.requests, b.requests);
      expect(b.successRate, 98);
      expect(b.models, hasLength(15));
      expect(b.errorCategories.first.category, isNotEmpty);
    });

    test('a model: state, activity, numbers and its bars on the bar grid', () {
      final m = _status().board.models.firstWhere((m) => m.model == 'gpt-5.6-luna');
      expect(m.state, ModelState.degraded);
      expect(m.active, isTrue);
      expect(m.name, 'GPT 5.6 Luna');
      expect(m.bars, hasLength(48));
      expect(m.bars.last.level, BarLevel.down);
      expect(m.bars.last.fail, greaterThan(0));
      expect(m.errors.map((e) => e.category), contains('empty_response'));
      expect(m.barStart(0)!.millisecondsSinceEpoch % m.barMs, 0, reason: 'bars start on the grid');
      expect(m.barStart(1)!.difference(m.barStart(0)!), const Duration(minutes: 30));
      expect(m.barStart(47)!.isAfter(m.barStart(0)!), isTrue);
    });

    test('a number the router did not send stays null, never 0', () {
      final m = _status().board.models.firstWhere((m) => m.model == 'grok-4.6');
      expect(m.state, ModelState.quiet);
      expect(m.recentSuccessRate, isNull);
      expect(m.ttftP50Ms, isNull);
      expect(m.tokensPerSecond, isNull);
      expect(m.latencyP50Ms, 1250);
    });

    test('ordered: what is failing and in use first, quiet last; the rest by traffic', () {
      final order = _status().board.ordered().map((m) => m.model).toList();
      // down+active, degraded+active come first, then down/degraded not active (Grok 4.7), then up, then quiet.
      final b = _status().board;
      final states = [for (final m in b.ordered()) (m.state, m.active)];
      expect(states.first.$1, ModelState.degraded, reason: 'gpt-5.6-luna is the only failing model in use');
      expect(order.indexOf('grok-4.7'), lessThan(order.indexOf('claude-opus-5.5')), reason: 'a dead model is worth a look before a healthy one');
      expect(order.last, anyOf('grok-4.6', 'claude-opus-4.5'), reason: 'quiet ones are last');
      final up = b.ordered().where((m) => m.state == ModelState.up).map((m) => m.requests).toList();
      expect(up, [...up]..sort((a, b) => b.compareTo(a)), reason: 'healthy models by traffic');
    });

    test('ordered: down and in use, then slow and in use, then down but idle, then the healthy', () {
      // The fixture has no model that is down and in use (Grok 4.7 is down but not active), so the first rule is tried here.
      final board = StatusBoard({
        'barMs': 1,
        'models': [
          {'model': 'healthy-busy', 'state': 'up', 'active': true, 'requests': 900},
          {'model': 'quiet', 'state': 'quiet', 'active': false, 'requests': 5},
          {'model': 'slow-in-use', 'state': 'degraded', 'active': true, 'requests': 10},
          {'model': 'down-idle', 'state': 'down', 'active': false, 'requests': 400},
          {'model': 'down-in-use', 'state': 'down', 'active': true, 'requests': 1},
          {'model': 'healthy-small', 'state': 'up', 'active': true, 'requests': 20},
          {'model': 'weird', 'state': 'melting', 'active': true, 'requests': 50},
        ],
      });
      expect(board.ordered().map((x) => x.model), ['down-in-use', 'slow-in-use', 'down-idle', 'weird', 'healthy-busy', 'healthy-small', 'quiet']);
    });

    test('relevantOnly keeps what is in use and what is failing, drops the quiet and idle', () {
      final b = _status().board;
      final shown = b.ordered(relevantOnly: true);
      expect(shown.every((m) => m.relevant), isTrue);
      expect(shown.map((m) => m.model), contains('grok-4.7'), reason: 'down, though not active');
      expect(shown.map((m) => m.model), isNot(contains('grok-4.6')));
      expect(shown.length, lessThan(b.models.length));
      expect(shown.any((m) => m.state == ModelState.quiet), isFalse);
    });

    test('a board with nothing in it, an unknown state or level and odd types does not throw', () {
      final empty = StatusBoard({});
      expect(empty.models, isEmpty);
      expect(empty.ordered(), isEmpty);
      expect(empty.successRate, isNull);
      final odd = StatusBoard({
        'window': '6h',
        'barMs': 600000,
        'totals': 'x',
        'summary': [],
        'models': [
          {'model': 'a', 'state': 'melting', 'active': 'yes', 'successRate': '99', 'bars': [[1, 2, 9], [1], 'x', null, [3, 0, -4]]},
          {'name': 'no id'},
          'junk',
        ],
      });
      expect(odd.models, hasLength(1));
      final m = odd.models.single;
      expect(m.state, ModelState.unknown);
      expect(m.active, isFalse);
      expect(m.successRate, isNull);
      expect(m.name, 'a');
      expect(m.bars.map((b) => b.level), [BarLevel.down, BarLevel.none], reason: 'level 9 clamps to the last, -4 to the first; short or bad bars are dropped');
      expect(m.barStart(0), isNull);
    });
  });

  group('rank', () {
    test('rows keep the router\'s order and the image model is told apart', () {
      final r = _rank();
      final b = r.board;
      expect(b.period, '7d');
      expect(b.rows.first.model, 'deepseek-v4.1-flash');
      expect(b.rows.first.name, 'Deepseek V4.1 Flash');
      final img = b.rows.firstWhere((x) => x.model == 'gemini-3.1-flash-image');
      expect(img.isImage, isTrue);
      expect(img.name, isNull, reason: 'the router does not name its image models');
      expect(b.rows.where((x) => x.isImage).map((x) => x.model), ['gemini-3.1-flash-image'], reason: 'by what it was asked for, though it has a few tokens');
      expect(b.rows.firstWhere((x) => x.model == 'gemini-4-argon').isImage, isFalse, reason: '1 picture among 24,768 text requests');
      expect(b.totalTokens, b.rows.fold<int>(0, (a, x) => a + x.tokens));
      expect(b.rows.first.tokens / b.totalTokens, inInclusiveRange(0.3, 0.9));
    });

    test('a row without a model is dropped; counts that are not numbers are 0', () {
      final b = RankBoard({
        'period': '24h',
        'rows': [
          {'requests': 3},
          {'model': 'a', 'requests': 'many', 'tokens': -5, 'images': 2.6},
          5,
        ],
      });
      expect(b.rows.map((r) => r.model), ['a']);
      expect(b.rows.single.requests, 0);
      expect(b.rows.single.images, 3);
      expect(RankBoard({}).rows, isEmpty);
    });
  });

  test('a stale copy keeps its reason', () {
    final s = parseServedRank({
      'board': {'period': '7d', 'rows': []},
      'fetchedAt': 1000,
      'stale': true,
      'error': 'fetch failed',
    });
    expect(s.stale, isTrue);
    expect(s.error, 'fetch failed');
    expect(parseServedStatus({}).board.models, isEmpty, reason: 'a reply with nothing in it is an empty board, not a crash');
  });

  test('the periods and windows offered are the ones the host accepts', () {
    final src = File('agent/src/modelboard.ts').readAsStringSync();
    for (final p in rankPeriods) {
      expect(src, contains('"$p"'), reason: p);
    }
    for (final w in statusWindows) {
      expect(src, contains('"$w"'), reason: w);
    }
    final listed = RegExp(r'RANK_PERIODS = \[([^\]]*)\]').firstMatch(src)!.group(1)!;
    for (final p in rankPeriods) {
      expect(listed, contains('"$p"'));
    }
    expect(rankPeriods, ['24h', '7d', '14d', '30d', 'all']);
    final windows = RegExp(r'STATUS_WINDOWS = \[([^\]]*)\]').firstMatch(src)!.group(1)!;
    expect(RegExp(r'"(\w+)"').allMatches(windows).map((m) => m.group(1)).toList(), statusWindows);
  });
}
