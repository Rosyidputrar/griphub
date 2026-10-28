import 'dart:async';

import 'package:flutter/material.dart';

import '../agent/agent_controller.dart';
import '../agent/agent_fs.dart';
import 'i18n.dart';
import 'preview_screen.dart';

// Adapted from CoderRa's server mode (seseegy/coderra lib/ui/preview_open.dart).

/// Opens a URL in the preview screen. Tests pass their own, since there is no WebView in a unit test.
typedef UrlOpener = Future<void> Function(BuildContext context, String title, String url);

Future<void> _openInPreview(BuildContext context, String title, String url) =>
    HtmlPreviewScreen.openUrl(context, title: title, url: url);

/// The address of the web page [path] as a server agent serves it (`preview_serve`, reached through an ssh forward), so
/// its relative links (css, js, pictures) load like on any web site. The project folder is served when it holds the
/// page, so `../style.css` from a subfolder works. Null with the agent on this phone.
Future<String?> serverPageUrl(AgentController agent, String path) async {
  if (agent.fs.isLocal) return null;
  return agent.remote.previewUrl(path, root: agent.cwd.isEmpty ? null : agent.cwd);
}

/// Shows the web page at [path] (which belongs to the agent's machine).
///
/// On this phone the page is read and shown with its folder as the base, so its pictures and styles load by path. With a
/// server agent the page is opened at [serverPageUrl].
Future<void> openFilePreview(
  BuildContext context,
  AgentController agent, {
  required String title,
  required String path,
  UrlOpener? opener,
}) async {
  final fs = agent.fs;
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    if (!fs.isLocal) {
      final url = await serverPageUrl(agent, path);
      if (url == null || !context.mounted) return;
      await (opener ?? _openInPreview)(context, title, url);
      return;
    }
    final html = await fs.readString(path);
    if (!context.mounted) return;
    await HtmlPreviewScreen.open(context, title: title, source: () => html, baseDir: parentPath(path));
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text('${tr('Could not open the preview')}: $e')));
  }
}

/// Shows HTML that is not (or not yet) the file on disk: an editor's unsaved text, or a page the agent is still writing
/// ([live]). Its relative links resolve next to [path]: on this phone in its folder, on a server through
/// [serverPageUrl] (when the server cannot serve it, the page still shows, without them).
Future<void> openTextPreview(
  BuildContext context,
  AgentController agent, {
  required String title,
  required String path,
  required String Function() source,
  Listenable? live,
}) async {
  String? baseUrl;
  if (!agent.fs.isLocal) {
    try {
      baseUrl = await serverPageUrl(agent, path);
    } catch (_) {}
    if (!context.mounted) return;
  }
  await HtmlPreviewScreen.open(
    context,
    title: title,
    source: source,
    baseDir: agent.fs.isLocal ? parentPath(path) : null,
    baseUrl: baseUrl,
    live: live,
  );
}

/// Opens a dev server the agent started. On this phone it is on localhost; on a server its port is forwarded first.
Future<void> openDevServer(
  BuildContext context,
  AgentController agent,
  int port,
  String localUrl, {
  UrlOpener? opener,
}) async {
  final title = agent.client.isRemote ? 'server:$port' : 'localhost:$port';
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final url = agent.client.isRemote ? await agent.remote.devServerUrl(port) : localUrl;
    if (url == null || !context.mounted) return;
    await (opener ?? _openInPreview)(context, title, url);
  } catch (e) {
    messenger?.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        content: Text(
          '${tr('Could not reach port {port} on the server').replaceAll('{port}', '$port')}: $e\n'
          '${tr('Make sure the dev server listens on 127.0.0.1 (for example --host 127.0.0.1).')}',
        ),
      ),
    );
  }
}
