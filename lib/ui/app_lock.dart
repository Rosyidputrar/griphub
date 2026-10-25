import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'i18n.dart';
import 'kit.dart';
import 'theme.dart';

/// Covers the app with a lock screen when app lock is on: at start, and when it comes back after
/// being in the background for a while. Uses the phone's fingerprint, face or screen lock.
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.child});
  final Widget child;

  static const relockAfter = Duration(minutes: 2);

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  final auth = LocalAuthentication();
  late bool locked = Appearance.instance.appLock;
  DateTime? leftAt;
  bool asking = false;
  String? error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // FLAG_SECURE follows the setting from the first frame: the leak is
    // the Recents snapshot, taken while backgrounded, not the lock screen.
    // (The toggle in Settings sends the same call when it flips.)
    unawaited(
      const MethodChannel('griphub/agent')
          .invokeMethod('setSecure', Appearance.instance.appLock)
          .catchError((_) {}),
    );
    if (locked) WidgetsBinding.instance.addPostFrameCallback((_) => _unlock());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!Appearance.instance.appLock) return;
    if (state == AppLifecycleState.paused) {
      leftAt ??= DateTime.now();
    } else if (state == AppLifecycleState.resumed) {
      final away = leftAt == null ? Duration.zero : DateTime.now().difference(leftAt!);
      leftAt = null;
      if (away >= AppLockGate.relockAfter && !locked) {
        setState(() => locked = true);
        _unlock();
      }
    }
  }

  Future<void> _unlock() async {
    if (asking) return;
    setState(() {
      asking = true;
      error = null;
    });
    try {
      if (!await auth.isDeviceSupported()) {
        // Nothing to check against; don't lock people out of their own app.
        setState(() => locked = false);
        return;
      }
      final ok = await auth.authenticate(localizedReason: tr('Unlock GripHub AI Agent'));
      if (mounted && ok) setState(() => locked = false);
    } catch (e) {
      if (mounted) setState(() => error = '$e');
    } finally {
      if (mounted) setState(() => asking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // The child stays mounted under the lock screen: swapping it out used
    // to destroy the Navigator (and any unsaved editor) on every lock.
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return Stack(
      children: [
        widget.child,
        if (locked)
          Scaffold(
            body: SafeArea(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(32),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const LogoMark(size: 56),
                      const SizedBox(height: 22),
                      Text(tr('GripHub AI Agent is locked'), style: text.titleLarge),
                      if (error != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          error!,
                          textAlign: TextAlign.center,
                          style: text.bodySmall?.copyWith(color: p.danger),
                        ),
                      ],
                      const SizedBox(height: 24),
                      PrimaryButton(label: tr('Unlock'), icon: LucideIcons.fingerprint, busy: asking, onPressed: _unlock),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
