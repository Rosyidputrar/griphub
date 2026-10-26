import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/drafts.dart';
import 'package:griphub_agent/agent/sent_attachments.dart';
import 'package:griphub_agent/ui/chat_extras.dart';

void main() {
  late Directory root;
  final store = SentAttachments.instance;

  setUpAll(() {
    root = Directory.systemTemp.createTempSync('sent_attachments');
    Drafts.root = root.path;
  });

  tearDownAll(() => root.deleteSync(recursive: true));

  test('records attachments per chat and message, and replaces on resend', () {
    const a = (path: '/x/photo.jpg', name: 'photo.jpg', mime: 'image/jpeg', size: 42);
    const b = (path: '/x/notes.txt', name: 'notes.txt', mime: null, size: 7);
    store.record('chat-a', 0, [a]);
    store.record('chat-a', 1, [b]);
    store.record('chat-b', 0, [b]);
    expect(store.forMessage('chat-a', 0), [a]);
    expect(store.forMessage('chat-a', 1), [b]);
    expect(store.forMessage('chat-b', 0), [b]);
    expect(store.forMessage('chat-a', 2), isEmpty);
    expect(store.forMessage('nope', 0), isEmpty);
    expect(store.forMessage(null, 0), isEmpty);

    // A rewind-and-resend reuses the index: the new record replaces it.
    store.record('chat-a', 0, [b]);
    expect(store.forMessage('chat-a', 0), [b]);
  });

  test('drops corrupt records but keeps entries for missing files', () {
    store.record('chat-c', 0, [
      (path: '', name: 'nameless', mime: null, size: -1),
      (path: '/gone/file.txt', name: 'file.txt', mime: null, size: -1),
    ]);
    // The empty path is dropped; the missing file stays, so the viewer can
    // explain it instead of the message silently losing its attachment.
    expect(store.forMessage('chat-c', 0), [
      (path: '/gone/file.txt', name: 'file.txt', mime: null, size: -1),
    ]);
  });

  test('stripAttachedNote only strips a trailing machine note', () {
    expect(stripAttachedNote('hello'), 'hello');
    expect(stripAttachedNote('hello\n\nAttached files:\n- /a/b.txt'), 'hello');
    expect(stripAttachedNote('Attached files:\n- /a/b.txt'), '');
    expect(
      stripAttachedNote('I wrote about Attached files:\n- not a note'),
      'I wrote about Attached files:\n- not a note',
    );
    expect(
      stripAttachedNote('hello\n\nAttached files:\n- /a/b.txt\nand more text'),
      'hello\n\nAttached files:\n- /a/b.txt\nand more text',
    );
    expect(stripAttachedNote(''), '');
  });

  test('sentIsImage honours mime first, then extension', () {
    expect(sentIsImage((path: '/a', name: 'x.bin', mime: 'image/png', size: 1)), isTrue);
    expect(sentIsImage((path: '/a', name: 'photo.JPG', mime: null, size: 1)), isTrue);
    expect(sentIsImage((path: '/a', name: 'notes.txt', mime: null, size: 1)), isFalse);
    expect(sentIsImage((path: '/a', name: 'README', mime: null, size: 1)), isFalse);
  });

  test('preparePrompt copies every attachment uniquely and keeps model input', () async {
    final cwd = Directory('${root.path}/proj')..createSync();
    final photo = File('${root.path}/photo.jpg')..writeAsBytesSync(List.filled(100, 7));
    final doc = File('${root.path}/notes.txt')..writeAsStringSync('hello');
    final dup = File('${root.path}/sub_notes.txt')..writeAsStringSync('other');
    final missing = '${root.path}/gone.png';

    final prompt = await preparePrompt('look', [
      Attachment(photo.path, 'photo.jpg', mime: 'image/jpeg'),
      Attachment(doc.path, 'notes.txt'),
      Attachment(dup.path, 'notes.txt'),
      Attachment(missing, 'gone.png', mime: 'image/png'),
    ], cwd.path);

    // The picture still reaches the model as an image.
    expect(prompt.images, hasLength(1));
    expect(prompt.images.first['mimeType'], 'image/jpeg');
    // Every readable attachment got its own copy; nothing was clobbered.
    expect(prompt.files, hasLength(3));
    final targets = prompt.files.map((f) => f.path).toList();
    expect(targets.toSet(), hasLength(3));
    for (final t in targets) {
      expect(File(t).existsSync(), isTrue);
      expect(t, startsWith('${cwd.path}/.attachments/'));
    }
    expect(prompt.files.firstWhere((f) => f.name == 'photo.jpg').mime, 'image/jpeg');
    // Files (both notes.txt copies) are referenced by path in the text.
    expect(prompt.text, contains('Attached files:'));
    expect(prompt.text, contains(targets[1]));
    expect(prompt.text, contains(targets[2]));
    // The missing file was skipped, not fatal.
    expect(prompt.text, isNot(contains('gone.png')));
  });

  test('preparePrompt sends big pictures down the file route', () async {
    final cwd = Directory('${root.path}/proj2')..createSync();
    final big = File('${root.path}/big.jpg')..writeAsBytesSync(List.filled(8 * 1024 * 1024 + 1, 3));
    final prompt = await preparePrompt('', [Attachment(big.path, 'big.jpg', mime: 'image/jpeg')], cwd.path);
    expect(prompt.images, isEmpty);
    expect(prompt.files, hasLength(1));
    expect(prompt.text, contains('Attached files:'));
  });
}
