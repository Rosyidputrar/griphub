// When an edit counts as a long paste (and becomes an attachment) and when it
// stays text in the field.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/ui/chat_extras.dart';

TextEditingValue v(String text, [int? cursor]) =>
    TextEditingValue(text: text, selection: TextSelection.collapsed(offset: cursor ?? text.length));

void main() {
  late List<String> pasted;
  late LongPasteFormatter f;
  setUp(() {
    pasted = [];
    f = LongPasteFormatter(pasted.add);
  });

  Future<TextEditingValue> edit(TextEditingValue before, TextEditingValue after) async {
    final r = f.formatEditUpdate(before, after);
    await Future<void>.delayed(Duration.zero);
    return r;
  }

  test('typing and short pastes stay text', () async {
    expect((await edit(v('hal'), v('halo'))).text, 'halo');
    final short = 'x' * longPasteChars;
    expect((await edit(v(''), v(short))).text, short, reason: 'exactly the limit is not "more than"');
    final lines = List.filled(longPasteLines - 1, 'a').join('\n');
    expect((await edit(v(''), v(lines))).text, lines, reason: '9 lines stay text');
    final trailing = '${List.filled(longPasteLines - 1, 'a').join('\n')}\n';
    expect((await edit(v(''), v(trailing))).text, trailing, reason: 'a trailing line break is not a 10th line');
    expect(pasted, isEmpty);
  });

  test('more than 1000 characters becomes an attachment, the field unchanged', () async {
    final long = 'y' * (longPasteChars + 1);
    final r = await edit(v('Tolong cek: '), v('Tolong cek: $long'));
    expect(r.text, 'Tolong cek: ');
    expect(pasted, [long]);
  });

  test('10 short lines become an attachment', () async {
    final log = List.generate(10, (i) => 'E$i').join('\n');
    expect(log.length, lessThan(longPasteChars));
    final r = await edit(v(''), v(log));
    expect(r.text, '');
    expect(pasted, [log]);
  });

  test('pasting in the middle, or over a selection, hands over exactly what was pasted', () async {
    final long = List.generate(20, (i) => 'line $i').join('\n');
    // Cursor between "awal " and " akhir".
    await edit(v('awal  akhir', 5), v('awal $long akhir'));
    // Selection "XXX" replaced.
    final before = const TextEditingValue(text: 'a XXX b', selection: TextSelection(baseOffset: 2, extentOffset: 5));
    await edit(before, v('a $long b'));
    expect(pasted, [long, long]);
  });

  test('a paste that shares characters with its surroundings is still found whole in length', () async {
    final long = 'a' * 1200;
    await edit(v('aaa', 3), v('aaa$long'));
    expect(pasted.single.length, 1200);
  });

  test('deleting a long text is not a paste', () async {
    final long = 'z' * 3000;
    expect((await edit(v(long), v(''))).text, '');
    expect(pasted, isEmpty);
  });
}
