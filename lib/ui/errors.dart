import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../agent/agent_client.dart';
import '../agent/agent_fs.dart';
import '../agent/remote_profile.dart';
import 'i18n.dart';

/// What to tell the user about [e], in their language. The host's messages and the app's own (an [AgentError], a
/// thrown string, a [StateError] with a sentence in it) are already written for people and go through as they are;
/// the network and timeouts get a sentence that says what to do; a bug (a [TypeError], a cast that failed on data
/// the app didn't expect) never shows its Dart text: it is logged, and the user reads that something went wrong.
String friendlyError(Object? e) {
  final fallback = tr('Something went wrong. Try again.');
  switch (e) {
    case null:
      return fallback;
    case String():
      return e.trim().isEmpty ? fallback : tr(e);
    case AgentError():
      return e.message.trim().isEmpty ? fallback : trHost(e.message);
    case Cancelled():
      return tr('Cancelled');
    case TimeoutException():
      return tr('It took too long. Check the connection and try again.');
    case SocketException() || HttpException() || HandshakeException() || TlsException():
      return tr("Couldn't reach the network. Check the connection and try again.");
    case FileSystemException():
      final why = e.osError?.message.trim();
      final name = e.path == null ? '' : ' ${baseName(e.path!)}';
      return '${tr(e.message)}$name${why == null || why.isEmpty ? '' : ' ($why)'}';
    case PlatformException():
      final m = e.message?.trim();
      return m == null || m.isEmpty ? fallback : tr(m);
    case SetupCodeError():
      return trMsg(e.say);
    case FormatException():
      // A reply that wasn't what the app expected (JSON that didn't parse): its offsets mean nothing to anyone.
      debugPrint('friendlyError: $e');
      return tr("Got an answer the app couldn't read. Try again.");
    case StateError():
      return e.message.trim().isEmpty ? fallback : tr(e.message);
    case Error():
      debugPrint('friendlyError: $e\n${e.stackTrace ?? ''}');
      return fallback;
  }
  final text = '$e'.replaceFirst(RegExp(r'^Exception: '), '').trim();
  return text.isEmpty ? fallback : tr(text);
}
