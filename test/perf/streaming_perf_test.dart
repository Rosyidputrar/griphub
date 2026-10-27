// How the chat copes while the agent writes a long file: the write tool's
// arguments stream in a few characters at a time and the transcript rebuilds
// about 30 times a second. Measures the cost of one rebuild of the tool card
// early in a 30 KB HTML file and at its end; that cost must not grow with the
// file (it used to: the whole file was re-parsed, re-highlighted and laid out
// on every frame).
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/models.dart';
import 'package:griphub_agent/ui/code_view.dart';
import 'package:griphub_agent/ui/message_views.dart';

import '../golden/harness.dart';

String _html(int kb) {
  final b = StringBuffer('<!doctype html>\n<html lang="id">\n<head>\n<style>\n');
  var i = 0;
  while (b.length < kb * 1024) {
    b.writeln('.card-$i { display: flex; padding: ${i % 24}px; color: #${(i * 7919 % 0xffffff).toRadixString(16).padLeft(6, '0')}; }');
    b.writeln('<section class="card-$i"><h2>Judul $i</h2><p>Paragraf "contoh" nomor $i dengan teks yang cukup panjang.</p></section>');
    i++;
  }
  return b.toString();
}

void main() {
  testWidgets('a tool card rebuild costs about the same at 2 KB and at 30 KB', (tester) async {
    final html = _html(30);
    // The raw JSON the model streams: {"path": "...", "content": "<escaped html>
    final json = '{"path": "site/index.html", "content": ${jsonEncode(html)}';
    final block = Block(BlockKind.toolCall)
      ..toolCallId = 't1'
      ..toolName = 'write';
    final live = ValueNotifier(0);
    await pumpLook(
      tester,
      const Look(),
      Scaffold(
        body: SingleChildScrollView(
          child: ValueListenableBuilder<int>(
            valueListenable: live,
            builder: (_, _, _) => ToolCallView(block: block, run: null, live: live),
          ),
        ),
      ),
    );

    // ~13 characters per frame: a model writing ~100 tokens/s at 30 fps.
    const step = 13;
    Future<Duration> frameAt(int end) async {
      final sw = Stopwatch();
      var frames = 0;
      // Average over a few frames around [end].
      for (var at = end - step * 8; at < end; at += step) {
        block.buffer.write(json.substring(block.buffer.length, at));
        live.value++;
        sw.start();
        await tester.pump();
        sw.stop();
        frames++;
      }
      return sw.elapsed ~/ frames;
    }

    // Warm up (first layout, fonts, highlighter), then measure at growing sizes.
    await frameAt(1024);
    final at = <int, Duration>{};
    for (final kb in [2, 8, 16, 30]) {
      final end = (kb * 1024).clamp(0, json.length - step);
      block.buffer.write(json.substring(block.buffer.length, end - step * 8));
      at[kb] = await frameAt(end);
    }
    // The same rebuild with nothing new: what a frame costs regardless of the file.
    final idle = Stopwatch()..start();
    for (var k = 0; k < 8; k++) {
      live.value++;
      await tester.pump();
    }
    idle.stop();
    // ignore: avoid_print
    print('PERF idle rebuild ${(idle.elapsedMicroseconds / 8000).toStringAsFixed(1)} ms');
    // ignore: avoid_print
    print('PERF tool card rebuild per frame: ${at.entries.map((e) => '${e.key} KB ${(e.value.inMicroseconds / 1000).toStringAsFixed(1)} ms').join(', ')}');
    // Before: 38 ms at 2 KB, 173 ms at 30 KB. Debug-mode numbers; release builds are several times faster.
    expect(at[30]!.inMicroseconds, lessThan(at[2]!.inMicroseconds * 2 + 5000));
  });

  testWidgets('while writing, the card shows the newest lines with their real numbers; all of it once written', (
    tester,
  ) async {
    final content = List.generate(200, (i) => '<p>line ${i + 1}</p>').join('\n');
    final block = Block(BlockKind.toolCall)
      ..toolCallId = 't1'
      ..toolName = 'write';
    block.buffer.write('{"path": "site/index.html", "content": ${jsonEncode(content)}'.replaceFirst(RegExp(r'"$'), ''));
    final live = ValueNotifier(0);
    ToolRun? run;
    await pumpLook(
      tester,
      const Look(),
      Scaffold(
        body: SingleChildScrollView(
          child: ValueListenableBuilder<int>(
            valueListenable: live,
            builder: (_, _, _) => ToolCallView(block: block, run: run, live: live),
          ),
        ),
      ),
    );
    var box = tester.widget<CodeBox>(find.byType(CodeBox));
    expect('\n'.allMatches(box.text).length + 1, 14);
    expect(box.firstLine, 187);
    expect(box.text.split('\n').first, '<p>line 187</p>');
    expect(box.copyText, content, reason: 'Copy takes the whole file, not the visible lines');
    expect(box.label, 'index.html · 200 lines · ${(content.length / 1024).toStringAsFixed(1)} KB');

    // The call lands and runs: the whole file shows (in its scrollable panel).
    block.args = {'path': 'site/index.html', 'content': content};
    run = ToolRun('t1')..status = ToolStatus.done;
    live.value++;
    await tester.pump();
    box = tester.widget<CodeBox>(find.byType(CodeBox));
    expect(box.text, content);
    expect(box.firstLine, 1);
  });

  testWidgets('a short file being written shows from line 1', (tester) async {
    final block = Block(BlockKind.toolCall)
      ..toolCallId = 't2'
      ..toolName = 'write';
    block.buffer.write(r'{"path": "a.css", "content": "body {\n  margin: 0;');
    await pumpLook(
      tester,
      const Look(),
      Scaffold(body: ToolCallView(block: block, run: null, live: ValueNotifier(0))),
    );
    final box = tester.widget<CodeBox>(find.byType(CodeBox));
    expect(box.text, 'body {\n  margin: 0;');
    expect(box.firstLine, 1);
    expect(box.label, 'a.css · 2 lines · 19 B');
  });
}
