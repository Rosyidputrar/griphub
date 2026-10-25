import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'predictive_back.dart';

/// Design tokens. Clean and light by default: white canvas, soft grey
/// surfaces, near-black for primary actions, and colour only in accents and
/// the mesh artwork on cards.
@immutable
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.bg,
    required this.surface,
    required this.raised,
    required this.border,
    required this.text,
    required this.muted,
    required this.faint,
    required this.inverse,
    required this.danger,
    required this.success,
    required this.warning,
    required this.accent,
    required this.accentAlt,
    required this.glass,
    required this.nav,
  });

  final Color bg;
  final Color surface;
  final Color raised;
  final Color border;
  final Color text;
  final Color muted;
  final Color faint;
  final Color inverse;
  final Color danger;
  final Color success;
  final Color warning;
  final Color accent;
  final Color accentAlt;

  /// Translucent fill for floating bars over content.
  final Color glass;

  /// The floating bottom navigation bar.
  final Color nav;

  static const light = Palette(
    bg: Color(0xFFFFFFFF),
    surface: Color(0xFFF5F5F7),
    raised: Color(0xFFECECF0),
    border: Color(0xFFE9E9ED),
    text: Color(0xFF111113),
    muted: Color(0xFF6B6B73),
    faint: Color(0xFF71717A),
    inverse: Color(0xFFFFFFFF),
    danger: Color(0xFFE5484D),
    success: Color(0xFF30A46C),
    warning: Color(0xFFF76B15),
    accent: Color(0xFF6E56CF),
    accentAlt: Color(0xFF3E63DD),
    glass: Color(0xEBFFFFFF),
    nav: Color(0xFF111113),
  );

  static const dark = Palette(
    bg: Color(0xFF0B0B0D),
    surface: Color(0xFF17171A),
    raised: Color(0xFF212125),
    border: Color(0xFF26262B),
    text: Color(0xFFF5F5F7),
    muted: Color(0xFF9E9EA6),
    faint: Color(0xFF8E8E98),
    inverse: Color(0xFF0B0B0D),
    danger: Color(0xFFFF6369),
    success: Color(0xFF3DD68C),
    warning: Color(0xFFFF8B3E),
    accent: Color(0xFF9E8CFC),
    accentAlt: Color(0xFF7B93FF),
    glass: Color(0xE617171A),
    nav: Color(0xFF232328),
  );

  @override
  Palette copyWith({Color? accent}) => accent == null
      ? this
      : Palette(
          bg: bg,
          surface: surface,
          raised: raised,
          border: border,
          text: text,
          muted: muted,
          faint: faint,
          inverse: inverse,
          danger: danger,
          success: success,
          warning: warning,
          accent: accent,
          accentAlt: accentAlt,
          glass: glass,
          nav: nav,
        );

  @override
  Palette lerp(Palette? other, double t) => t < 0.5 ? this : (other ?? this);
}

extension PaletteX on BuildContext {
  Palette get palette => Theme.of(this).extension<Palette>()!;
}

const mono = 'GeistMono';

/// Accent colours the user can pick, as (light, dark) pairs. The first is the default violet.
const accentChoices = <(Color, Color)>[
  (Color(0xFF6E56CF), Color(0xFF9E8CFC)),
  (Color(0xFF3E63DD), Color(0xFF7B93FF)),
  (Color(0xFF30A46C), Color(0xFF3DD68C)),
  (Color(0xFFF76B15), Color(0xFFFF8B3E)),
  (Color(0xFFD6409F), Color(0xFFF07CC0)),
  (Color(0xFF12A594), Color(0xFF3BD3C0)),
];

/// UI preferences remembered on the device: theme, text size, density, accent, language, app lock, and
/// whether the welcome screen was seen.
class Appearance extends ValueNotifier<ThemeMode> {
  Appearance._() : super(ThemeMode.light) {
    try {
      final saved = jsonDecode(_file.readAsStringSync()) as Map<String, dynamic>;
      value = ThemeMode.values.firstWhere((m) => m.name == saved['theme'], orElse: () => ThemeMode.light);
      onboarded = saved['onboarded'] == true;
      textScale = (saved['textScale'] as num?)?.toDouble() ?? 1;
      compact = saved['compact'] == true;
      accent = ((saved['accent'] as num?)?.toInt() ?? 0).clamp(0, accentChoices.length - 1);
      language = saved['language'] as String? ?? 'en';
      appLock = saved['appLock'] == true;
      terminalFontSize = (saved['terminalFontSize'] as num?)?.toDouble() ?? terminalFontSize;
      // A modifiable copy: older ui.json files have no entry, and a const map can't be written to.
      deployTargets = {
        for (final e in (saved['deployTargets'] as Map? ?? {}).entries)
          if (e.key is String && e.value is String) e.key as String: e.value as String,
      };
      favoriteModels = [
        for (final e in (saved['favoriteModels'] as List? ?? []))
          if (e is String) e,
      ];
    } catch (_) {}
  }

  static final instance = Appearance._();
  static final _file = File('/data/data/id.griphub.agent/files/ui.json');

  bool onboarded = false;
  double textScale = 1;
  bool compact = false;
  int accent = 0;
  String language = 'en';
  bool appLock = false;

  /// Pinch or A−/A+ in the terminal.
  double terminalFontSize = 12.5;

  void set(ThemeMode mode) {
    value = mode;
    _save();
  }

  void update({
    double? textScale,
    bool? compact,
    int? accent,
    String? language,
    bool? appLock,
    double? terminalFontSize,
  }) {
    this.terminalFontSize = terminalFontSize ?? this.terminalFontSize;
    this.textScale = textScale ?? this.textScale;
    this.compact = compact ?? this.compact;
    this.accent = accent ?? this.accent;
    this.language = language ?? this.language;
    this.appLock = appLock ?? this.appLock;
    _save();
    notifyListeners();
  }

  /// Saved without notifying: only the terminal reads it, so the rest of the app needn't rebuild.
  void setTerminalFontSize(double size) {
    terminalFontSize = size;
    _save();
  }

  /// Model keys ('provider/id') starred in the model picker, in starring order.
  /// Keys whose model left the catalog stay stored, so they reappear if it returns.
  List<String> favoriteModels = [];

  bool isFavorite(String key) => favoriteModels.contains(key);

  void toggleFavorite(String key) {
    favoriteModels = List.of(favoriteModels);
    if (!favoriteModels.remove(key)) favoriteModels.add(key);
    _save();
    notifyListeners();
  }

  /// The deploy target last used per project folder, so the deploy sheet opens on it.
  Map<String, String> deployTargets = {};

  void setDeployTarget(String project, String target) {
    deployTargets = Map.of(deployTargets);
    deployTargets
      ..remove(project)
      ..[project] = target;
    while (deployTargets.length > 50) {
      deployTargets.remove(deployTargets.keys.first);
    }
    _save();
  }

  void finishOnboarding() {
    onboarded = true;
    _save();
    notifyListeners();
  }

  void _save() {
    try {
      _file.writeAsStringSync(
        jsonEncode({
          'theme': value.name,
          'onboarded': onboarded,
          'textScale': textScale,
          'compact': compact,
          'accent': accent,
          'language': language,
          'appLock': appLock,
          'terminalFontSize': terminalFontSize,
          'deployTargets': deployTargets,
          'favoriteModels': favoriteModels,
        }),
      );
    } catch (_) {}
  }
}

/// Corner-radius tokens. Each constant is one radius value already used
/// across the UI; the migration from literals was mechanical, so no pixel
/// value changed. `pill` is the fully-rounded (99) case, not a corner size.
class Radii {
  const Radii._();

  static const double r2 = 2;
  static const double r3 = 3;
  static const double r4 = 4;
  static const double r6 = 6;
  static const double r8 = 8;
  static const double r10 = 10;
  static const double r12 = 12;
  static const double r14 = 14;
  static const double r16 = 16;
  static const double r18 = 18;
  static const double r20 = 20;
  static const double r22 = 22;
  static const double r24 = 24;
  static const double r28 = 28;
  static const double r32 = 32;
  static const double r34 = 34;
  static const double pill = 99;
}

ThemeData buildTheme(Brightness brightness) {
  final look = Appearance.instance;
  final light = brightness == Brightness.light;
  final pick = accentChoices[look.accent];
  final p = (light ? Palette.light : Palette.dark).copyWith(
    accent: look.accent == 0 ? null : (light ? pick.$1 : pick.$2),
  );
  final base = ThemeData(
    brightness: brightness,
    useMaterial3: true,
    fontFamily: 'Geist',
    splashFactory: InkSparkle.splashFactory,
    visualDensity: look.compact ? VisualDensity.compact : VisualDensity.standard,
  );

  TextStyle t(double size, FontWeight w, Color c, {double height = 1.4, double spacing = 0}) =>
      TextStyle(fontFamily: 'Geist', fontSize: size, fontWeight: w, color: c, height: height, letterSpacing: spacing);

  final text = TextTheme(
    displayMedium: t(36, FontWeight.w700, p.text, height: 1.08, spacing: -1.4),
    displaySmall: t(30, FontWeight.w700, p.text, height: 1.12, spacing: -1.1),
    headlineSmall: t(24, FontWeight.w700, p.text, height: 1.2, spacing: -0.7),
    titleLarge: t(19, FontWeight.w700, p.text, height: 1.3, spacing: -0.4),
    titleMedium: t(16, FontWeight.w600, p.text, spacing: -0.2),
    titleSmall: t(14.5, FontWeight.w600, p.text, spacing: -0.1),
    bodyLarge: t(15.5, FontWeight.w400, p.text, height: 1.6),
    bodyMedium: t(14, FontWeight.w400, p.text, height: 1.5),
    bodySmall: t(12.5, FontWeight.w400, p.muted, height: 1.45),
    labelLarge: t(14.5, FontWeight.w600, p.text),
    labelMedium: t(12.5, FontWeight.w500, p.muted),
    labelSmall: t(11, FontWeight.w600, p.faint, spacing: 0.5),
  );

  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.text,
    onPrimary: p.inverse,
    secondary: p.accent,
    onSecondary: Colors.white,
    error: p.danger,
    onError: Colors.white,
    surface: p.bg,
    onSurface: p.text,
    onSurfaceVariant: p.muted,
    surfaceContainerLowest: p.bg,
    surfaceContainerLow: p.surface,
    surfaceContainer: p.surface,
    surfaceContainerHigh: p.raised,
    surfaceContainerHighest: p.raised,
    outline: p.border,
    outlineVariant: p.border,
    surfaceTint: Colors.transparent,
    secondaryContainer: p.raised,
    onSecondaryContainer: p.text,
  );

  final overlay = brightness == Brightness.light ? SystemUiOverlayStyle.dark : SystemUiOverlayStyle.light;
  final radius = BorderRadius.circular(Radii.r16);

  OutlineInputBorder field(Color c, [double w = 1]) => OutlineInputBorder(
    borderRadius: radius,
    borderSide: BorderSide(color: c, width: w),
  );

  return base.copyWith(
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    dividerColor: p.border,
    textTheme: text,
    extensions: [p],
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      foregroundColor: p.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleSpacing: 4,
      titleTextStyle: text.titleLarge,
      iconTheme: IconThemeData(color: p.text, size: 20),
      actionsIconTheme: IconThemeData(color: p.text, size: 20),
      systemOverlayStyle: overlay.copyWith(statusBarColor: Colors.transparent, systemNavigationBarColor: p.bg),
    ),
    dividerTheme: DividerThemeData(color: p.border, thickness: 1, space: 1),
    iconTheme: IconThemeData(color: p.text, size: 20),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: p.text, highlightColor: p.raised, shape: const CircleBorder()),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: p.bg,
      width: 320,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.horizontal(right: Radius.circular(Radii.r28))),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.bg,
      modalBackgroundColor: p.bg,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: p.raised,
      dragHandleSize: const Size(40, 5),
      modalBarrierColor: Colors.black.withValues(alpha: 0.35),
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Radii.r32))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.bg,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.r28)),
      titleTextStyle: text.titleLarge,
      contentTextStyle: text.bodyMedium,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.nav,
      contentTextStyle: text.bodyMedium!.copyWith(color: Colors.white),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.r18)),
      elevation: 0,
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: p.surface,
      hintStyle: text.bodyMedium!.copyWith(color: p.faint),
      labelStyle: text.bodyMedium!.copyWith(color: p.muted),
      floatingLabelStyle: text.bodyMedium!.copyWith(color: p.text),
      helperStyle: text.bodySmall,
      prefixIconColor: p.faint,
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      border: field(Colors.transparent),
      enabledBorder: field(Colors.transparent),
      focusedBorder: field(p.text.withValues(alpha: 0.25), 1.2),
      errorBorder: field(p.danger),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.text,
        foregroundColor: p.inverse,
        disabledBackgroundColor: p.raised,
        disabledForegroundColor: p.faint,
        minimumSize: const Size(0, 50),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        textStyle: text.labelLarge,
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.text,
        backgroundColor: p.surface,
        minimumSize: const Size(0, 50),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        textStyle: text.labelLarge,
        side: BorderSide.none,
        shape: RoundedRectangleBorder(borderRadius: radius),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.text,
        textStyle: text.labelLarge,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.r12)),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.surface,
      selectedColor: p.text,
      side: BorderSide.none,
      shape: const StadiumBorder(),
      labelStyle: text.labelMedium!.copyWith(color: p.text),
      secondaryLabelStyle: text.labelMedium!.copyWith(color: p.inverse),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      showCheckmark: false,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.inverse : p.faint),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.text : p.raised),
      trackOutlineColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    listTileTheme: ListTileThemeData(
      iconColor: p.muted,
      textColor: p.text,
      titleTextStyle: text.bodyLarge,
      subtitleTextStyle: text.bodySmall,
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      minVerticalPadding: 10,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.r16)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 8,
      shadowColor: Colors.black.withValues(alpha: 0.15),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.r18)),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(color: p.nav, borderRadius: BorderRadius.circular(Radii.r10)),
      textStyle: text.labelMedium!.copyWith(color: Colors.white),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.text, linearTrackColor: p.raised),
    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.text,
      selectionColor: p.accent.withValues(alpha: 0.25),
      selectionHandleColor: p.accent,
    ),
    pageTransitionsTheme: const PageTransitionsTheme(builders: {TargetPlatform.android: SmoothPageTransitions()}),
  );
}
