import 'package:griphub_agent/agent/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads a value that is still being streamed', () {
    final args = partialJsonStrings(r'{"path": "index.html", "content": "<h1>Hi</h1>\n<p>wor');
    expect(args['path'], 'index.html');
    expect(args['content'], '<h1>Hi</h1>\n<p>wor');
  });

  test('decodes escapes and stops before a cut escape', () {
    expect(partialJsonStrings(r'{"a": "say \"hi\"\tA"}')['a'], 'say "hi"\tA');
    expect(partialJsonStrings(r'{"a": "x\')['a'], 'x');
    expect(partialJsonStrings(r'{"a": "x\u00')['a'], 'x');
  });

  test('keeps the latest repeated key', () {
    final args = partialJsonStrings(r'{"path":"a.html","edits":[{"oldText":"1","newText":"2"},{"oldText":"3","newText":"4');
    expect(args['newText'], '4');
  });

  test('empty or keyless input', () {
    expect(partialJsonStrings(''), isEmpty);
    expect(partialJsonStrings('{"pa'), isEmpty);
  });

  // Streaming reads (PartialJsonReader): fed the growing text in pieces, the
  // result after every piece equals what the previous (whole-text) reader gave
  // for the same prefix, even
  // when a piece ends inside a key, an escape or a \u sequence.
  group('incremental reader', () {
    const samples = [
      r'{"path": "index.html", "content": "<h1>Hi</h1>\n<p>say \"hi\"\tA \u00e9\u0041 back\\slash</p>"}',
      r'{"path":"a.html","edits":[{"oldText":"1","newText":"2"},{"oldText":"3\n","newText":"4\u0021"}]}',
      r'{"limit": 40, "command": "ls -la \"my dir\"", "path": ""}',
    ];

    for (final raw in samples) {
      test('every cut of ${raw.substring(0, 20)}…', () {
        for (final chunk in [1, 2, 3, 7, 13]) {
          final reader = PartialJsonReader();
          for (var end = 0; end <= raw.length; end += chunk) {
            final prefix = raw.substring(0, end.clamp(0, raw.length));
            reader.update(prefix);
            expect(reader.values, _reference(prefix), reason: 'chunk $chunk, at $end');
          }
          reader.update(raw);
          expect(reader.values, _reference(raw));
        }
      });
    }

    test('matches the one-shot result of the old reader for a finished value', () {
      final reader = PartialJsonReader()..update(samples.first);
      expect(reader.values['content'], '<h1>Hi</h1>\n<p>say "hi"\tA éA back\\slash</p>');
    });

    test('a block re-reads from the start when its buffer is replaced', () {
      final b = Block(BlockKind.toolCall);
      b.buffer.write(r'{"path": "a.html", "content": "long text');
      expect(b.liveArgs!['content'], 'long text');
      b.text = r'{"path": "b.html", "content": "x';
      expect(b.liveArgs, {'path': 'b.html', 'content': 'x'});
      b.args = {'path': 'final'};
      expect(b.liveArgs, {'path': 'final'});
    });
  });
}

/// The reader before it became incremental, kept as the reference behaviour.
Map<String, dynamic> _reference(String raw) {
  final out = <String, dynamic>{};
  final key = RegExp(r'"([A-Za-z_][A-Za-z0-9_]*)"\s*:\s*"');
  var pos = 0;
  while (true) {
    final m = key.firstMatch(raw.substring(pos));
    if (m == null) break;
    var i = pos + m.end;
    final value = StringBuffer();
    while (i < raw.length) {
      final c = raw[i];
      if (c == '"') break;
      if (c != r'\') {
        value.write(c);
        i++;
        continue;
      }
      if (i + 1 >= raw.length) {
        i = raw.length;
        break;
      }
      final e = raw[i + 1];
      switch (e) {
        case 'n':
          value.write('\n');
        case 't':
          value.write('\t');
        case 'r':
          value.write('\r');
        case 'b':
          value.write('\b');
        case 'f':
          value.write('\f');
        case 'u':
          if (i + 6 > raw.length) {
            i = raw.length;
            continue;
          }
          final code = int.tryParse(raw.substring(i + 2, i + 6), radix: 16);
          if (code != null) value.writeCharCode(code);
          i += 6;
          continue;
        default:
          value.write(e);
      }
      i += 2;
    }
    out[m.group(1)!] = value.toString();
    pos = i < raw.length ? i + 1 : raw.length;
    if (pos >= raw.length) break;
  }
  return out;
}
