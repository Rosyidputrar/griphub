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

  void _next() => pages.nextPage(duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic);

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
                  Material(
                    color: p.surface,
                    borderRadius: BorderRadius.circular(Radii.md),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(Radii.md),
                      onTap: _start,
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                        child: Text(tr('Skip'), style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13.5)),
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
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        SizedBox(height: 240, child: Center(child: _heroWidget(hero))),
                        const SizedBox(height: 40),
                        Text(tr(title), textAlign: TextAlign.center, style: text.displayMedium),
                        const SizedBox(height: 14),
                        Text(
                          tr(body),
                          textAlign: TextAlign.center,
                          style: text.bodyLarge?.copyWith(color: p.muted),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < _slides.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
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
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
              child: PrimaryButton(
                label: last ? tr('Add API key') : tr('Next'),
                onPressed: last ? _addKey : _next,
              ),
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
