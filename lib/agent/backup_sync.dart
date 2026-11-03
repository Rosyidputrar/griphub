import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'agent_fs.dart';
import 'agent_client.dart' show AgentError;

/// Calls a command on the server's host (AgentClient.call).
typedef BackupCall = Future<T> Function<T>(String type, [Map<String, dynamic> args]);

/// Fetches a server's incremental backup to this phone (agent/src/autobackup.ts): the snapshot, and only the blobs
/// this phone does not have yet. Every blob is named by a keyed hash of its content, so one the phone has is the same
/// whatever backup it came with, and the next backup's unchanged files cost nothing.
///
/// On the phone, beside the zip backups from before:
///
/// ```text
/// [dir]/auto-AT.ghs        a snapshot (encrypted; the host reads it with the key)
/// [dir]/auto-AT.ghs.ids    the blobs it needs, by name only (keyed hashes: they say nothing of the content)
/// [dir]/blobs/ID           a blob, as the server stored it (encrypted)
/// [dir]/blobs/.ID.part     a blob still coming; a fetch cut short goes on from where it stopped
/// ```
///
/// The snapshot is written last, so one is on this phone only once all of its blobs are.
class BackupSync {
  BackupSync(this._call, this.dir, {this.waitOnline, this.chunkBytes = 1024 * 1024});

  final BackupCall _call;
  final Directory dir;

  /// Resolves when the connection is back; null fails the fetch when it drops (the next fetch goes on from there).
  final Future<void> Function()? waitOnline;

  /// Bytes asked for per answer: many small blobs in one, a large one over several.
  final int chunkBytes;

  Directory get blobsDir => Directory('${dir.path}/blobs');

  /// The blobs on this phone, by name.
  Set<String> haveBlobs() {
    if (!blobsDir.existsSync()) return {};
    return {
      for (final f in blobsDir.listSync().whereType<File>())
        if (_blobId.hasMatch(_base(f.path))) _base(f.path),
    };
  }

  static final _blobId = RegExp(r'^[0-9a-f]{64}$');
  static final snapshotName = RegExp(r'^auto-(\d+)\.ghs$');

  static String _base(String path) => path.substring(path.lastIndexOf('/') + 1);

  /// Fetches the snapshot [name] and the blobs it needs that are not here. [onProgress] counts the bytes still to
  /// come, not the backup's whole size. Returns the snapshot file, and how many bytes came over the link.
  Future<({File file, int fetched})> fetch(String name, {Progress? onProgress, CancelToken? cancel}) async {
    if (!snapshotName.hasMatch(name)) throw AgentError('Not a snapshot: $name');
    final needs = (await _again(() => _call<Map>('auto_backup_needs', {'name': name}))).cast<String, dynamic>();
    final blobs = (needs['blobs'] as List).cast<Map>();
    await blobsDir.create(recursive: true);
    final have = haveBlobs();
    // What is still to come; a part from a fetch cut short goes on from its length.
    final queue = <String, int>{};
    final sizes = <String, int>{};
    for (final b in blobs) {
      final id = b['id'] as String;
      if (!_blobId.hasMatch(id) || have.contains(id) || queue.containsKey(id)) continue;
      final size = (b['size'] as num).toInt();
      final part = File('${blobsDir.path}/.$id.part');
      final at = part.existsSync() ? part.lengthSync() : 0;
      queue[id] = at <= size ? at : 0;
      sizes[id] = size;
    }
    final total = sizes.values.fold<int>(0, (a, b) => a + b) - queue.values.fold<int>(0, (a, b) => a + b);
    var done = 0;
    onProgress?.call(0, total);
    while (queue.isNotEmpty) {
      cancel?.check();
      final ask = [for (final e in queue.entries) {'id': e.key, 'offset': e.value}];
      final r = (await _again(() => _call<Map>('auto_backup_read', {'items': ask, 'max': chunkBytes}))).cast<String, dynamic>();
      final chunks = (r['chunks'] as List).cast<Map>();
      if (chunks.isEmpty) throw AgentError('The server sent nothing for this backup; try again');
      for (final c in chunks) {
        final id = c['id'] as String;
        final offset = (c['offset'] as num).toInt();
        final size = (c['size'] as num).toInt();
        if (queue[id] != offset) continue; // not what was asked for: asked again next round
        final data = base64Decode(c['data'] as String);
        if (data.isEmpty && offset < size) {
          throw AgentError('A part of the backup changed on the server while it was fetched; try again');
        }
        final part = File('${blobsDir.path}/.$id.part');
        final sink = await part.open(mode: offset == 0 ? FileMode.write : FileMode.append);
        try {
          await sink.writeFrom(data);
        } finally {
          await sink.close();
        }
        done += data.length;
        onProgress?.call(done, total);
        if (offset + data.length >= size) {
          await part.rename('${blobsDir.path}/$id');
          queue.remove(id);
        } else {
          queue[id] = offset + data.length;
        }
      }
    }
    final file = File('${dir.path}/$name');
    await File('${file.path}.ids').writeAsString(jsonEncode([for (final b in blobs) b['id']]), flush: true);
    final tmp = File('${file.path}.part');
    await tmp.writeAsBytes(base64Decode(needs['snapshot'] as String), flush: true);
    await tmp.rename(file.path);
    return (file: file, fetched: done);
  }

  /// The blobs the snapshot [file] needs, from its `.ids`; null when that is missing or damaged.
  static Set<String>? idsOf(File file) {
    try {
      return (jsonDecode(File('${file.path}.ids').readAsStringSync()) as List).cast<String>().toSet();
    } catch (_) {
      return null;
    }
  }

  /// Deletes the snapshot [file] with its list of blobs.
  static void deleteSnapshot(File file) {
    for (final f in [file, File('${file.path}.ids')]) {
      if (f.existsSync()) f.deleteSync();
    }
  }

  /// Removes the blobs that none of the snapshots [kept] needs, and parts of blobs a fetch left. Nothing when one of
  /// them does not say what it needs: its blobs could go with the rest.
  void pruneBlobs(Iterable<File> kept) {
    if (!blobsDir.existsSync()) return;
    final needed = <String>{};
    for (final f in kept) {
      final ids = idsOf(f);
      if (ids == null) return;
      needed.addAll(ids);
    }
    for (final f in blobsDir.listSync().whereType<File>()) {
      final name = _base(f.path);
      final id = name.startsWith('.') && name.endsWith('.part') ? name.substring(1, name.length - 5) : name;
      if (!needed.contains(id)) f.deleteSync();
    }
  }

  /// Runs a request again after the connection comes back, a few times (every request here can be repeated).
  Future<T> _again<T>(Future<T> Function() request) async {
    for (var attempt = 0; ; attempt++) {
      try {
        return await request();
      } on AgentError catch (e) {
        final lost = e.code == 'connection_lost' || e.code == 'offline' || e.code == 'not_sent';
        if (!lost || waitOnline == null || attempt >= 30) rethrow;
        await waitOnline!();
      }
    }
  }
}
