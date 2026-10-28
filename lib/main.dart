import 'dart:async';

import 'package:flutter/material.dart';

import 'agent/agent_client.dart';
import 'agent/agent_controller.dart';
import 'ui/app_lock.dart';
import 'ui/home_shell.dart';
import 'ui/onboarding.dart';
import 'ui/predictive_back.dart';
import 'ui/server_screen.dart';
import 'ui/i18n.dart';
import 'ui/kit.dart';
import 'ui/links.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized().addObserver(PredictiveBack.instance);
  final client = AgentClient();
  externalUrlOpener = client.openUrl;
  final agent = AgentController(client)..translate = tr;
  // The saved server (if the user set one up and uses it) decides where boot connects.
  unawaited(agent.remote.load().catchError((_) {}).whenComplete(agent.boot));
  runApp(GripHubApp(agent: agent));
}

class GripHubApp extends StatelessWidget {
  const GripHubApp({super.key, required this.agent});
  final AgentController agent;

  @override
  Widget build(BuildContext context) {
    final appearance = Appearance.instance;
    return ListenableBuilder(
      listenable: appearance,
      builder: (context, _) => MaterialApp(
        title: tr('GripHub AI Agent'),
        debugShowCheckedModeBanner: false,
        navigatorObservers: [PredictiveBack.instance],
        themeMode: appearance.value,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(appearance.textScale * MediaQuery.textScalerOf(context).scale(14) / 14),
          ),
          child: AppLockGate(child: child!),
        ),
        home: ListenableBuilder(
          listenable: agent,
          builder: (context, _) => AnimatedSwitcher(
            duration: const Duration(milliseconds: 250),
            child: !appearance.onboarded
                ? OnboardingScreen(agent: agent)
                : switch (agent.status) {
                    BootStatus.ready => HomeShell(agent: agent),
                    BootStatus.starting => _Boot(agent: agent),
                    BootStatus.failed =>
                      agent.client.isRemote ? ServerBootFailed(agent: agent) : _BootFailed(agent: agent),
                  },
          ),
        ),
      ),
    );
  }
}

class _Boot extends StatelessWidget {
  const _Boot({required this.agent});
  final AgentController agent;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const LogoMark(size: 56),
            const SizedBox(height: 20),
            SizedBox(width: 120, child: LinearProgressIndicator(minHeight: 2, borderRadius: BorderRadius.circular(Radii.xs))),
            const SizedBox(height: 14),
            Text(
              agent.client.isRemote ? tr('Connecting to your server') : tr('Starting agent'),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _BootFailed extends StatelessWidget {
  const _BootFailed({required this.agent});
  final AgentController agent;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 32),
              Text(tr('The agent could not start'), style: text.headlineSmall),
              const SizedBox(height: 8),
              Text(tr('Details from the runtime are below.'), style: text.bodyMedium?.copyWith(color: p.muted)),
              const SizedBox(height: 20),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: p.surface,
                    borderRadius: BorderRadius.circular(Radii.md),
                    border: Border.all(color: p.border),
                  ),
                  child: SingleChildScrollView(
                    child: SelectableText(
                      agent.bootError ?? 'Unknown error',
                      style: TextStyle(fontFamily: mono, fontSize: 12, height: 1.5, color: p.text),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(onPressed: agent.boot, child: Text(tr('Try again'))),
              const SizedBox(height: 8),
              // A server that cannot be reached has its own screen (ServerBootFailed); this one is the phone's.
              OutlinedButton(
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: Text(tr('Reset saved keys?')),
                      content: Text(
                        tr(
                          'The saved store key could not be unlocked. Resetting it makes all saved tokens unreadable; you will need to sign in again.',
                        ),
                      ),
                      actions: [
                        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('Cancel'))),
                        FilledButton(
                          style: FilledButton.styleFrom(
                            backgroundColor: context.palette.danger,
                            foregroundColor: Colors.white,
                          ),
                          onPressed: () => Navigator.pop(context, true),
                          child: Text(tr('Reset')),
                        ),
                      ],
                    ),
                  );
                  if (ok == true) {
                    await agent.client.resetStoreKey();
                    await agent.boot();
                  }
                },
                child: Text(tr('Reset saved keys')),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
