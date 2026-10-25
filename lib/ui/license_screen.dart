import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'i18n.dart';
import 'kit.dart';

/// Shows the app's own LICENSE plus third-party credits. The LICENSE file is
/// bundled as a Flutter asset (see pubspec.yaml); the credits below name the
/// big pieces the app is built on.
class LicenseScreen extends StatelessWidget {
  const LicenseScreen({super.key});

  static const _credits = [
    ('pi (pi-coding-agent)', 'MIT — the on-device agent host this app bundles.'),
    ('Termux', 'GPL-3.0 — the Linux environment (tools, shell, apt) inside the app.'),
    ('Flutter', 'BSD — the UI framework.'),
    ('Geist + Geist Mono', 'OFL — the UI and code fonts.'),
    ('Lucide icons', 'ISC — the icon set.'),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(tr('Licenses'))),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          SectionLabel(tr('Third-party')),
          for (final (name, note) in _credits)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text('$name — $note', style: Theme.of(context).textTheme.bodyMedium),
            ),
          const SizedBox(height: 8),
          SectionLabel(tr('App license')),
          FutureBuilder<String>(
            future: rootBundle.loadString('LICENSE'),
            builder: (context, snap) {
              if (snap.hasError) return Text('${snap.error}');
              if (!snap.hasData) return const Center(child: CircularProgressIndicator());
              return SelectableText(snap.data!, style: Theme.of(context).textTheme.bodySmall);
            },
          ),
        ],
      ),
    );
  }
}
