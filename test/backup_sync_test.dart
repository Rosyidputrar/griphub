import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:griphub_agent/agent/agent_client.dart';
import 'package:griphub_agent/agent/backup_sync.dart';

/// A server's incremental backups as the phone fetches them (lib/agent/backup_sync.dart), against a server that
/// answers as agent/src/autobackup.ts does (auto_backup_needs / auto_backup_read), so what goes over the link can be
/// counted and cut. The real host is in auto_backup_test.dart.
class FakeServer {
  final blobs = <String, Uint8List>{};
  final snapshots = <String, List<String>>{};
  var readBytes = 0;
  var reads = 0;

  /// Cut the link after this many more read answers (a dropped connection).
  int? dropAfter;

  String add(int size, int seed) {
    final r = Random(seed);
    final data = Uint8List.fromList(List.generate(size, (_) => r.nextInt(256)));
    final id = seed.toRadixString(16).padLeft(64, '0');
    blobs[id] = data;
    return id;
  }

  Future<T> call<T>(String type, [Map<String, dynamic> args = const {}]) async {
    switch (type) {
      case 'auto_backup_needs':
        final ids = snapshots[args['name']]!;
        return {
          'name': args['name'],
          'snapshot': base64Encode(utf8.encode('snapshot ${args['name']}')),
          'blobs': [for (final id in ids) {'id': id, 'size': blobs[id]!.length}],
        } as T;
      case 'auto_backup_read':
        final drop = dropAfter;
        if (drop != null) {
          if (drop <= 0) {
            dropAfter = null;
            throw AgentError('Connection lost', code: 'connection_lost');
          }
          dropAfter = drop - 1;
        }
        reads++;
        var left = args['max'] as int;
        final chunks = <Map<String, dynamic>>[];
        for (final item in (args['items'] as List).cast<Map>()) {
          if (left <= 0) break;
          final data = blobs[item['id']]!;
          final offset = item['offset'] as int;
          final n = min(left, data.length - offset);
          left -= n;
          readBytes += n;
          chunks.add({'id': item['id'], 'offset': offset, 'size': data.length, 'data': base64Encode(data.sublist(offset, offset + n))});
        }
        return {'chunks': chunks} as T;
    }
    throw StateError(type);
  }
}

void main() {
  late Directory dir;
  late FakeServer server;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('backup-sync-');
    server = FakeServer();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  BackupSync sync({Future<void> Function()? waitOnline}) =>
      BackupSync(server.call, dir, waitOnline: waitOnline, chunkBytes: 64 * 1024);

  test('the first fetch takes every blob; the next only the ones that changed', () async {
    final a = server.add(200 * 1024, 1);
    final b = server.add(3000, 2);
    final c = server.add(10, 3);
    server.snapshots['auto-1.ghs'] = [a, b, c, c];
    final first = await sync().fetch('auto-1.ghs');
    expect(first.fetched, 200 * 1024 + 3000 + 10);
    expect(server.reads, greaterThanOrEqualTo(4), reason: '200 KB in 64 KB answers');
    expect(File('${dir.path}/blobs/$a').readAsBytesSync(), server.blobs[a]);
    expect(first.file.readAsStringSync(), 'snapshot auto-1.ghs');

    final b2 = server.add(3100, 4);
    server.snapshots['auto-2.ghs'] = [a, b2, c];
    server.readBytes = 0;
    final progress = <(int, int)>[];
    final second = await sync().fetch('auto-2.ghs', onProgress: (d, t) => progress.add((d, t)));
    expect(second.fetched, 3100, reason: 'only the changed file');
    expect(server.readBytes, 3100);
    expect(progress.last, (3100, 3100), reason: 'progress counts what is still to come, not the whole backup');
  });

  test('a dropped link is waited out; a fetch cut short goes on from where it stopped', () async {
    final a = server.add(300 * 1024, 5);
    server.snapshots['auto-1.ghs'] = [a];
    var waited = 0;
    server.dropAfter = 2;
    final got = await sync(waitOnline: () async => waited++).fetch('auto-1.ghs');
    expect(waited, 1);
    expect(got.fetched, 300 * 1024, reason: 'nothing fetched twice');
    expect(File('${dir.path}/blobs/$a').readAsBytesSync(), server.blobs[a]);

    // Without a way to wait: the fetch fails, keeps its part, and the next one finishes it.
    final b = server.add(300 * 1024, 6);
    server.snapshots['auto-2.ghs'] = [a, b];
    server.dropAfter = 2;
    await expectLater(sync().fetch('auto-2.ghs'), throwsA(isA<AgentError>()));
    expect(File('${dir.path}/auto-2.ghs').existsSync(), isFalse, reason: 'no snapshot without its blobs');
    expect(File('${dir.path}/blobs/.$b.part').lengthSync(), 128 * 1024);
    server.readBytes = 0;
    final again = await sync().fetch('auto-2.ghs');
    expect(again.fetched, 172 * 1024);
    expect(server.readBytes, 172 * 1024);
    expect(File('${dir.path}/blobs/$b').readAsBytesSync(), server.blobs[b]);
    expect(File('${dir.path}/blobs/.$b.part').existsSync(), isFalse);
  });

  test('blobs no kept snapshot needs are removed; none when a snapshot does not say what it needs', () async {
    final a = server.add(100, 7);
    final b = server.add(100, 8);
    final c = server.add(100, 9);
    server.snapshots['auto-1.ghs'] = [a, b];
    server.snapshots['auto-2.ghs'] = [a, c];
    final s = sync();
    final one = (await s.fetch('auto-1.ghs')).file;
    final two = (await s.fetch('auto-2.ghs')).file;
    File('${dir.path}/blobs/.${'f' * 64}.part').writeAsStringSync('left by a fetch of a backup since dropped');
    final stray = File('${dir.path}/blobs/.$c.part')..writeAsStringSync('a part whose blob is whole');

    expect(BackupSync.idsOf(one), {a, b});
    File('${one.path}.ids').writeAsStringSync('{damaged');
    s.pruneBlobs([one, two]);
    expect(s.haveBlobs(), {a, b, c}, reason: 'kept: one snapshot does not say what it needs');

    BackupSync.deleteSnapshot(one);
    expect(File('${one.path}.ids').existsSync(), isFalse);
    s.pruneBlobs([two]);
    expect(s.haveBlobs(), {a, c});
    expect(stray.existsSync(), isTrue, reason: 'a part of a blob still needed may be finished');
    expect(File('${dir.path}/blobs/.${'f' * 64}.part').existsSync(), isFalse);
  });

  test('only a snapshot name is fetched', () async {
    await expectLater(sync().fetch('../auto-1.ghs'), throwsA(isA<AgentError>()));
    await expectLater(sync().fetch('auto-1.ghb'), throwsA(isA<AgentError>()));
  });
}
