import 'package:flutter/material.dart';

import '../agent/agent_controller.dart';
import '../agent/agent_fs.dart';
import 'i18n.dart';
import 'preview_screen.dart';

/// Shows the web page at [path], which belongs to the agent's machine.
///
/// On this phone the page is read and shown with its folder as the base, so its pictures and styles load by path. With a
/// server agent the page is read over the link and shown on its own; its pictures and styles come with the preview
/// through the server (server_agent.md, phase 6). Adapted from CoderRa's lib/ui/preview_open.dart.
Future<void> openFilePreview(
  BuildContext context,
  AgentController agent, {
  required String title,
  required String path,
}) async {
  final fs = agent.fs;
  final messenger = ScaffoldMessenger.maybeOf(context);
  String html;
  try {
    html = await fs.readString(path);
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text('${tr('Could not open the preview')}: $e')));
    return;
  }
  if (!context.mounted) return;
  await HtmlPreviewScreen.open(
    context,
    title: title,
    source: () => html,
    baseDir: fs.isLocal ? parentPath(path) : null,
  );
}
