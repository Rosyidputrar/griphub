import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import '../agent/pricing.dart';
import 'errors.dart';
import 'i18n.dart';
import 'kit.dart';

/// The limits offered, in GripHub credits a day.
const dailyLimitChoices = <double>[10, 25, 50, 100];

/// "Rp 7.500", with dot thousands.
String rupiahOf(num credits) {
  final s = (credits * kRupiahPerCredit).round().toString();
  return 'Rp ${s.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => '.')}';
}

/// Spending has no limit until one is set, and nothing said so: a new key started with none. Offered once, right after
/// a key is first saved (and only when no limit is set), with what each choice means in rupiah; "No limit" leaves it
/// as it was. Returns the limit chosen, or null when none was set.
Future<double?> offerDailyLimit(BuildContext context, AgentController agent) async {
  try {
    final settings = await agent.integrations.refreshSettings();
    if (settings.dailyBudget > 0) return null;
  } catch (_) {
    return null; // not knowing is not a reason to ask
  }
  if (!context.mounted) return null;
  final picked = await showAppSheet<double>(
    context: context,
    builder: (sheet) {
      final text = Theme.of(sheet).textTheme;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(tr('Set a daily limit?'), style: text.titleLarge),
              const SizedBox(height: 10),
              Text(
                tr('The agent stops starting requests once a day\'s spend reaches it. 1 credit = Rp 300. You can change it later in Settings, under Usage & budget.'),
                style: text.bodyMedium,
              ),
              const SizedBox(height: 16),
              for (final v in dailyLimitChoices) ...[
                OutlinedButton(
                  onPressed: () => Navigator.of(sheet).pop(v),
                  child: Text('${localNumber(formatCredits(v))} ${tr('credits')} · ${rupiahOf(v)} ${tr('a day')}'),
                ),
                const SizedBox(height: 8),
              ],
              TextButton.icon(
                onPressed: () => Navigator.of(sheet).pop(),
                icon: const Icon(LucideIcons.infinity, size: 18),
                label: Text(tr('No limit')),
              ),
            ],
          ),
        ),
      );
    },
  );
  if (picked == null) return null;
  try {
    await agent.integrations.updateSettings({'dailyBudget': picked});
    return picked;
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(friendlyError(e))));
    return null;
  }
}
