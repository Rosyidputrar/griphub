import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../agent/agent_controller.dart';
import 'griphub_screen.dart';
import 'kit.dart';
import 'i18n.dart';
import 'theme.dart';

/// First-run welcome, rewritten for GripHub: what the router gives you,
/// then straight to adding its API key.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key, required this.agent});
  final AgentController agent;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final pages = PageController();
  int page = 0;

  // Carousel kept, copy rewritten for GripHub: slide 1 is the brand,
  // slide 2 the models + credits, slide 3 ends on the key action.
  static const _slides = [
    (_Hero.logo, 'GripHub AI Agent', 'One GripHub key, every AI model.'),
    (
      _Hero.models,
      '50+ models,\none key',
      'Claude, GPT, Gemini, DeepSeek and more, paid with GripHub credits — 1 credit = Rp 300.'
    ),
    (
      _Hero.key,
      'Add your key\nto start',
      'Paste your GripHub Router API key. The model list loads itself — nothing else to configure.'
    ),
  ];

  // Home takes over from here and offers to connect a model if none is set.
  void _start() => Appearance.instance.finishOnboarding();

  void _next() => Motion.reduced(context)
      ? pages.jumpToPage((pages.page ?? 0).round() + 1)
      : pages.nextPage(duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);

  /// Push the GripHub key screen; a saved key finishes onboarding straight
  /// into Home (no connect card — the key is already there). Backing out
  /// leaves the user on this slide, with Skip still available.
  Future<void> _addKey() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => GripHubScreen(agent: widget.agent)),
    );
    if (saved == true && mounted) _start();
  }

  @override
  void dispose() {
    pages.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final text = Theme.of(context).textTheme;
    final last = page == _slides.length - 1;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
              child: Row(
                children: [
                  // A 48 dp touch box around the small pill it draws.
                  Semantics(
                    button: true,
                    label: tr('Skip'),
                    child: TapTarget(
                      onTap: _start,
                      child: ExcludeSemantics(
                        child: Material(
                          color: p.surface,
                          borderRadius: BorderRadius.circular(Radii.md),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(Radii.md),
                            onTap: _start,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                              child: Text(
                                tr('Skip'),
                                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Spacer(),
                ],
              ),
            ),
            Expanded(
              child: PageView.builder(
                controller: pages,
                itemCount: _slides.length,
                onPageChanged: (i) => setState(() => page = i),
                itemBuilder: (context, i) {
                  final (hero, title, body) = _slides[i];
                  // Scrolls when the page is taller than the room (a phone on its side, very large text), and the picture
                  // shrinks to leave room for the words.
                  return LayoutBuilder(
                    builder: (context, box) => SingleChildScrollView(
                      padding: const EdgeInsets.symmetric(horizontal: 28),
                      child: ConstrainedBox(
                        constraints: BoxConstraints(minHeight: box.maxHeight),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            SizedBox(
                              height: (box.maxHeight * 0.45).clamp(96.0, 240.0),
                              child: Center(child: _heroWidget(hero)),
                            ),
                            SizedBox(height: box.maxHeight < 400 ? 16 : 40),
                            Text(tr(title), textAlign: TextAlign.center, style: text.displayMedium),
                            const SizedBox(height: 14),
                            Text(
                              tr(body),
                              textAlign: TextAlign.center,
                              style: text.bodyLarge?.copyWith(color: p.muted),
                            ),
                            const SizedBox(height: 12),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            // The dots are one thing to a screen reader: which page this is.
            Semantics(
              label: tr('Page {n} of {total}')
                  .replaceAll('{n}', '${page + 1}')
                  .replaceAll('{total}', '${_slides.length}'),
              child: ExcludeSemantics(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    for (var i = 0; i < _slides.length; i++)
                      AnimatedContainer(
                        duration: Motion.of(context, const Duration(milliseconds: 220)),
                        margin: const EdgeInsets.symmetric(horizontal: 4),
                        width: 9,
                        height: 9,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          // The app accent, like every other selected state (accentAlt is for categories).
                          color: i == page ? p.accent : Colors.transparent,
                          border: Border.all(color: i == page ? p.accent : p.faint, width: 1.5),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
              child: PrimaryButton(label: last ? tr('Add API key') : tr('Next'), onPressed: last ? _addKey : _next),
            ),
          ],
        ),
      ),
    );
  }

  Widget _heroWidget(_Hero hero) => switch (hero) {
    _Hero.logo => Image.asset('assets/brand/logo.png', height: 200),
    _Hero.models => const IconTile(icon: LucideIcons.sparkles, size: 132),
    _Hero.key => const IconTile(icon: LucideIcons.keyRound, size: 132),
  };
}

enum _Hero { logo, models, key }
