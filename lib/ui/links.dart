import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'i18n.dart';
import 'kit.dart';
import 'theme.dart';

/// Opens a URL outside the app (the phone's browser). Set once at boot to
/// the platform channel's openUrl; tests replace it.
Future<void> Function(String url) externalUrlOpener = (_) async {};

/// http(s) URLs and bare www. addresses in plain text. Trailing punctuation
/// that usually ends a sentence is not part of the link.
final _urlPattern = RegExp(r'''(?:https?://|www\.)[^\s<>"'`]+''', caseSensitive: false);

/// Splits [text] into plain parts and links, as (text, url) pairs; url is null for plain text.
List<(String, String?)> linkify(String text) {
  final out = <(String, String?)>[];
  var at = 0;
  for (final m in _urlPattern.allMatches(text)) {
    var raw = m.group(0)!;
    // Drop sentence punctuation, and a closing bracket the link did not open.
    while (raw.isNotEmpty) {
      final last = raw[raw.length - 1];
      if ('.,;:!?\'"'.contains(last)) {
        raw = raw.substring(0, raw.length - 1);
        continue;
      }
      const pairs = {')': '(', ']': '[', '}': '{'};
      final open = pairs[last];
      if (open != null && open.allMatches(raw).length < last.allMatches(raw).length) {
        raw = raw.substring(0, raw.length - 1);
        continue;
      }
      break;
    }
    if (raw.length < 8) continue;
    if (m.start > at) out.add((text.substring(at, m.start), null));
    out.add((raw, raw.toLowerCase().startsWith('www.') ? 'https://$raw' : raw));
    at = m.start + raw.length;
  }
  if (at < text.length) out.add((text.substring(at), null));
  return out;
}

/// What a link would open, judged before asking: null when it cannot be
/// opened at all (javascript:, file:, intent:, a malformed address).
Uri? openableUri(String url) {
  final u = Uri.tryParse(url.trim());
  if (u == null) return null;
  switch (u.scheme.toLowerCase()) {
    case 'http' || 'https':
      return u.host.isEmpty ? null : u;
    case 'mailto' || 'tel':
      return u;
    default:
      return null;
  }
}

/// The host a link's visible text names, when it looks like an address
/// ("github.com/x", "https://a.b"); null for ordinary words.
String? _hostOfLabel(String? label) {
  if (label == null) return null;
  final t = label.trim();
  if (t.contains(' ') || !t.contains('.')) return null;
  final u = Uri.tryParse(t.contains('://') ? t : 'https://$t');
  final h = u?.host.toLowerCase() ?? '';
  return h.contains('.') ? h : null;
}

/// Opens [url] in the browser: straight away for a trusted domain, after a
/// confirmation otherwise (with "Always trust this domain"). [label] is the
/// link's visible text; a mismatch with the real host is pointed out.
Future<void> openLink(BuildContext context, String url, {String? label}) async {
  final uri = openableUri(url);
  if (uri == null) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(tr("This kind of link can't be opened."))));
    return;
  }
  final web = uri.scheme == 'http' || uri.scheme == 'https';
  final host = uri.host.toLowerCase();
  if (web && Appearance.instance.isTrusted(host)) {
    HapticFeedback.selectionClick();
    await externalUrlOpener(uri.toString());
    return;
  }
  final labelHost = _hostOfLabel(label);
  final r = await showDialog<({bool open, bool trust})>(
    context: context,
    builder: (_) => LinkConfirmDialog(
      url: uri.toString(),
      host: web ? host : null,
      mismatchHost: web && labelHost != null && labelHost != host && !host.endsWith('.$labelHost') ? labelHost : null,
    ),
  );
  if (r == null || !r.open) return;
  if (r.trust && web) Appearance.instance.trustDomain(host);
  await externalUrlOpener(uri.toString());
}

/// "Leave the app?" for a link: the domain in bold, the full address, a
/// warning when the text showed another domain, and "Always trust".
class LinkConfirmDialog extends StatefulWidget {
  const LinkConfirmDialog({super.key, required this.url, this.host, this.mismatchHost});
  final String url;

  /// Null for mailto:/tel:, which cannot be trusted per domain.
  final String? host;
  final String? mismatchHost;

  @override
  State<LinkConfirmDialog> createState() => _LinkConfirmDialogState();
}

class _LinkConfirmDialogState extends State<LinkConfirmDialog> {
  bool _trust = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final host = widget.host;
    // Break long domains at their dots, not mid-word.
    final shownHost = host?.replaceAll('.', '.\u200B');
    return AlertDialog(
      title: Text(tr('Open this link outside the app?')),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              host == null ? tr('It opens in another app on your phone.') : tr('It opens in your browser.'),
              style: text.bodyMedium,
            ),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: p.surface, borderRadius: BorderRadius.circular(Radii.md)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (host != null) ...[
                    Row(
                      children: [
                        Icon(LucideIcons.globe, size: 16, color: p.accent),
                        const SizedBox(width: 6),
                        Expanded(child: Text(shownHost!, style: text.titleSmall)),
                      ],
                    ),
                    const SizedBox(height: 6),
                  ],
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 96),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        widget.url,
                        style: TextStyle(fontFamily: mono, fontSize: 12, height: 1.4, color: p.muted),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (widget.mismatchHost != null) ...[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(LucideIcons.triangleAlert, size: 15, color: p.warning),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      tr('The text said {a}, but the link goes to {b}.')
                          .replaceAll('{a}', widget.mismatchHost!)
                          .replaceAll('{b}', host ?? ''),
                      style: text.bodySmall?.copyWith(color: p.warning),
                    ),
                  ),
                ],
              ),
            ],
            if (host != null) ...[
              const SizedBox(height: 6),
              CheckboxListTile(
                value: _trust,
                onChanged: (v) => setState(() => _trust = v ?? false),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(tr('Always trust {host}').replaceAll('{host}', shownHost!), style: text.bodyMedium),
                subtitle: Text(tr('Its links open without asking. Manage in Settings.'), style: text.bodySmall),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Clipboard.setData(ClipboardData(text: widget.url));
            Navigator.pop(context, (open: false, trust: false));
            ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(tr('Link copied'))));
          },
          child: Text(tr('Copy')),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('Cancel'))),
        FilledButton(onPressed: () => Navigator.pop(context, (open: true, trust: _trust)), child: Text(tr('Open'))),
      ],
    );
  }
}

/// Plain text with its links tappable (and underlined in the accent).
class LinkifiedText extends StatefulWidget {
  const LinkifiedText(this.text, {super.key, this.style});
  final String text;
  final TextStyle? style;

  @override
  State<LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<LinkifiedText> {
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  TapGestureRecognizer _tap(VoidCallback onTap) {
    final r = TapGestureRecognizer()..onTap = onTap;
    _recognizers.add(r);
    return r;
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final parts = linkify(widget.text);
    if (parts.every((x) => x.$2 == null)) return Text(widget.text, style: widget.style);
    final p = context.palette;
    final base = widget.style ?? DefaultTextStyle.of(context).style;
    final linkStyle = base.copyWith(color: p.accentText, decoration: TextDecoration.underline, decorationColor: p.accentText);
    return Text.rich(
      TextSpan(
        style: base,
        children: [
          for (final (t, url) in parts)
            if (url == null)
              TextSpan(text: t)
            else
              TextSpan(text: t, style: linkStyle, recognizer: _tap(() => unawaited(openLink(context, url, label: t)))),
        ],
      ),
    );
  }
}


/// Settings → Trusted domains: links to these open without asking.
class TrustedDomainsScreen extends StatelessWidget {
  const TrustedDomainsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    return ListenableBuilder(
      listenable: Appearance.instance,
      builder: (context, _) {
        final domains = Appearance.instance.trustedDomains;
        return Scaffold(
          appBar: AppBar(title: Text(tr('Trusted domains'))),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 40),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 14),
                child: Text(
                  tr('Links to these domains open in the browser without asking first. Remove one to be asked again.'),
                  style: text.bodySmall,
                ),
              ),
              if (domains.isEmpty)
                SurfaceCard(
                  child: Row(
                    children: [
                      IconTile(icon: LucideIcons.shieldCheck, color: p.muted),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          tr('No trusted domains yet. Tick "Always trust" when opening a link to add one.'),
                          style: text.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                )
              else
                SettingsGroup(
                  children: [
                    for (final d in domains)
                      SettingsRow(
                        icon: LucideIcons.globe,
                        color: p.accent,
                        title: d,
                        trailing: IconButton(
                          tooltip: tr('Remove'),
                          icon: Icon(LucideIcons.trash2, size: 18, color: p.danger),
                          onPressed: () {
                            Appearance.instance.untrustDomain(d);
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(tr('{host} removed').replaceAll('{host}', d)),
                                action: SnackBarAction(
                                  label: tr('Undo'),
                                  onPressed: () => Appearance.instance.trustDomain(d),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }
}
