import 'package:flutter/material.dart';

import 'tokens.dart';

/// Material 3 theming tuned for a round, dark-first watch panel.
///
/// The scheme itself comes from [ColorScheme.fromSeed] so the roles stay
/// standards compliant; only the surfaces are pushed towards true black,
/// because an OLED watch spends most of its time showing a mostly empty
/// screen.
abstract final class WearTheme {
  /// Dark scheme, the default for a watch.
  static ColorScheme darkScheme() {
    final seeded = ColorScheme.fromSeed(
      seedColor: WearTokens.seed,
      brightness: Brightness.dark,
      dynamicSchemeVariant: DynamicSchemeVariant.vibrant,
    );
    return seeded.copyWith(
      surface: WearTokens.backdrop,
      surfaceDim: WearTokens.backdrop,
      surfaceContainerLowest: const Color(0xFF08090A),
      surfaceContainerLow: const Color(0xFF0E1112),
      surfaceContainer: const Color(0xFF14181A),
      surfaceContainerHigh: const Color(0xFF1B2023),
      surfaceContainerHighest: const Color(0xFF222A2D),
      onSurface: const Color(0xFFE6EAEA),
      onSurfaceVariant: const Color(0xFFB6C2C4),
      outline: const Color(0xFF6C7A7D),
      outlineVariant: const Color(0xFF39474A),
    );
  }

  /// Light scheme, kept for completeness and for a desktop preview window.
  static ColorScheme lightScheme() => ColorScheme.fromSeed(
    seedColor: WearTokens.seed,
    brightness: Brightness.light,
    dynamicSchemeVariant: DynamicSchemeVariant.vibrant,
  );

  static ThemeData dark() => _base(darkScheme());

  static ThemeData light() => _base(lightScheme());

  static ThemeData _base(ColorScheme scheme) {
    final base = ThemeData(colorScheme: scheme, useMaterial3: true);
    final text = _textTheme(base.textTheme, scheme);

    return base.copyWith(
      scaffoldBackgroundColor: scheme.brightness == Brightness.dark
          ? WearTokens.backdrop
          : scheme.surface,
      canvasColor: scheme.surface,
      textTheme: text,
      // A cursor must read as clearly as a fingertip: hover and focus states
      // stay visible on a dark watch face.
      hoverColor: scheme.primary.withValues(alpha: 0.10),
      focusColor: scheme.primary.withValues(alpha: 0.18),
      highlightColor: scheme.primary.withValues(alpha: 0.14),
      splashColor: scheme.primary.withValues(alpha: 0.12),
      splashFactory: InkSparkle.splashFactory,
      visualDensity: VisualDensity.compact,
      iconTheme: IconThemeData(color: scheme.onSurfaceVariant, size: 20),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      // Rounded, compact, and free of the desktop-size default paddings.
      cardTheme: CardThemeData(
        color: scheme.surfaceContainer,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(
            Radius.circular(WearTokens.radiusCard),
          ),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(
            WearTokens.iconButtonSize,
            WearTokens.touchTarget,
          ),
          shape: const StadiumBorder(),
          padding: const EdgeInsets.symmetric(horizontal: WearTokens.space5),
          textStyle: text.labelLarge,
        ),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        selectedColor: scheme.primaryContainer,
        side: BorderSide(color: scheme.outlineVariant),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(
            Radius.circular(WearTokens.radiusChip),
          ),
        ),
        labelStyle: text.labelLarge,
        secondaryLabelStyle: text.labelLarge!.copyWith(
          color: scheme.onPrimaryContainer,
        ),
        padding: const EdgeInsets.symmetric(horizontal: WearTokens.space3),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
        circularTrackColor: scheme.surfaceContainerHighest,
        strokeCap: StrokeCap.round,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
    );
  }

  /// A compressed type scale: watch text is read at arm's length in a glance.
  static TextTheme _textTheme(TextTheme base, ColorScheme scheme) {
    final onSurface = scheme.onSurface;
    final onVariant = scheme.onSurfaceVariant;
    return base.copyWith(
      displaySmall: base.displaySmall!.copyWith(
        fontSize: 32,
        height: 1.15,
        fontWeight: FontWeight.w500,
        letterSpacing: 0,
        color: onSurface,
      ),
      headlineSmall: base.headlineSmall!.copyWith(
        fontSize: 22,
        height: 1.2,
        fontWeight: FontWeight.w500,
        color: onSurface,
      ),
      titleMedium: base.titleMedium!.copyWith(
        fontSize: 16,
        height: 1.25,
        fontWeight: FontWeight.w600,
        color: onSurface,
      ),
      bodyMedium: base.bodyMedium!.copyWith(
        fontSize: 14,
        height: 1.35,
        /*
         * w500 rather than the default w400. At arm's length on a watch panel
         * the regular weight of the body face goes thin against a black field,
         * which is why the reference reader uses w500 throughout; one step up
         * keeps the text legible without it reading as a heading.
         */
        fontWeight: FontWeight.w500,
        color: onSurface,
      ),
      bodySmall: base.bodySmall!.copyWith(
        fontSize: 12,
        height: 1.35,
        fontWeight: FontWeight.w500,
        color: onVariant,
      ),
      labelLarge: base.labelLarge!.copyWith(
        fontSize: 14,
        height: 1.2,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
        color: onSurface,
      ),
      labelMedium: base.labelMedium!.copyWith(
        fontSize: 12,
        height: 1.2,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.2,
        color: onVariant,
      ),
      labelSmall: base.labelSmall!.copyWith(
        fontSize: 11,
        height: 1.2,
        fontWeight: FontWeight.w500,
        letterSpacing: 0.4,
        color: onVariant,
      ),
    );
  }
}
