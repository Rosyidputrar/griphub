import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/models.dart';
import 'i18n.dart';
import 'kit.dart';
import 'theme.dart';

/// What the person chose when asked to go back to a message.
enum RewindChoice { fork, edit }

/// How many messages (yours and the agent's) come after [entry] in [entries]: what going back to it takes out of this chat.
int messagesAfter(List<ChatEntry> entries, UserEntry entry) {
  final at = entries.indexOf(entry);
  if (at < 0) return 0;
  return entries.skip(at + 1).where((e) => e is UserEntry || e is AssistantEntry).length;
}

/// "Edit & resend" moves this chat back to just before a message: everything after it leaves the chat and the model's
/// context, with no way back, and the files the agent changed meanwhile stay changed. Asked before it happens, with
/// Fork (a copy that keeps this chat as it is) as the safe first choice. Null when dismissed.
Future<RewindChoice?> confirmRewind(BuildContext context, {required int messages}) => showAppSheet<RewindChoice>(
  context: context,
  builder: (sheet) {
    final text = Theme.of(sheet).textTheme;
    final p = sheet.palette;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(tr('Go back to this message?'), style: text.titleLarge),
            const SizedBox(height: 10),
            Text(
              messages > 1
                  ? tr('The {n} messages after it leave this chat, and the agent forgets them. There is no undo.').replaceAll('{n}', '$messages')
                  : tr('What comes after it leaves this chat, and the agent forgets it. There is no undo.'),
              style: text.bodyMedium,
            ),
            const SizedBox(height: 8),
            Text(
              tr('Files the agent already changed stay changed. Use Changes & undo for those.'),
              style: text.bodyMedium?.copyWith(color: p.muted),
            ),
            const SizedBox(height: 18),
            PrimaryButton(
              label: tr('Fork instead: keep this chat'),
              icon: LucideIcons.gitFork,
              onPressed: () => Navigator.of(sheet).pop(RewindChoice.fork),
            ),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              style: OutlinedButton.styleFrom(
                foregroundColor: p.danger,
                side: BorderSide(color: p.danger.withValues(alpha: 0.6)),
              ),
              onPressed: () => Navigator.of(sheet).pop(RewindChoice.edit),
              icon: const Icon(LucideIcons.pencil, size: 18),
              label: Text(tr('Go back and edit')),
            ),
            TextButton(onPressed: () => Navigator.of(sheet).pop(), child: Text(tr('Cancel'))),
          ],
        ),
      ),
    );
  },
);
