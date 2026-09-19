import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Design tokens for the hand-rolled Wear Material 3 layer.
///
/// Flutter ships no first-party Wear Compose equivalent, so the physical
/// constants of a round watch screen (spacing, radii, touch targets, motion)
/// live here and every primitive in `lib/wear_m3/` reads them instead of
/// inventing local numbers.
abstract final class WearTokens {
  /// Brand seed. A brisk cyan keeps the generated scheme away from the
  /// default Material purple.
  static const Color seed = Color(0xFF57D9E0);

  /// OLED-friendly true black used as the scaffold background.
  static const Color backdrop = Color(0xFF000000);

  // ── spacing scale (dp) ────────────────────────────────────────────────
  static const double space1 = 4;
  static const double space2 = 8;
  static const double space3 = 12;
  static const double space4 = 16;
  static const double space5 = 20;
  static const double space6 = 24;
  static const double space7 = 32;

  // ── corner radii (dp) ─────────────────────────────────────────────────
  static const double radiusCard = 24;
  static const double radiusChip = 16;
  static const double radiusButton = 22;
  static const double radiusSheet = 28;
  static const double radiusIndicator = 4;

  // ── touch targets ─────────────────────────────────────────────────────
  /// Wear M3 keeps 48dp as the minimum tappable size so a fingertip lands on
  /// a 384px watch the way a cursor lands on a 2x desktop window.
  static const double touchTarget = 48;
  static const double iconButtonSize = 48;
  static const double iconButtonIconSize = 24;
  static const double chipHeight = 32;
  static const double chipIconSize = 18;
  static const double cardMinHeight = 56;

  /// Diameter of the circle a card's leading icon sits on.
  static const double cardLeadingSize = 36;

  // ── screen safe area ──────────────────────────────────────────────────
  /*
   * No safe area. Content runs edge to edge and the round panel is what crops
   * it; reserving space here produced black bands rather than protection.
   */

  /// Round screens are narrow; content wider than this sits under the bezel
  /// once it leaves the vertical centre, which is why Wear centres it.
  static const double maxContentWidth = 192;

  // ── scaling list ──────────────────────────────────────────────────────
  /*
   * Matching the reference Wear reader on this watch (MR): entries shrink only
   * slightly as they leave the anchor and fade part of the way out. Its
   * numbers are minScale 0.82 / minOpacity 0.45 / cardGap 4, and the effect
   * reads as depth rather than as the list being squeezed.
   */

  /// Scale applied to an item at the very edge of the viewport.
  static const double minItemScale = 0.82;

  /// Scale applied to the item on the anchor line.
  static const double maxItemScale = 1.0;

  /// Opacity applied to an item at the very edge of the viewport. Never 0 so
  /// an off-centre item still reads as present.
  static const double minItemOpacity = 0.45;

  /// Horizontal margin a list row keeps from the panel edge.
  ///
  /// Zero: rows run the full width of the panel, and nothing narrows or clips
  /// them. Only the top inset positions the list.
  static const double cardMarginH = 0;

  /// Vertical room kept clear at the top of the list.
  ///
  /// Zero: the list's own centring positions the content, so an inset here
  /// would be added on top of it and pull the list off-centre.
  static const double screenInsetTop = 0;

  /// Vertical room kept clear at the bottom of the list.
  ///
  /// Zero. The page dots sit on the last few pixels of the panel, and the rows
  /// above them are free to run to the edge — reserving height here only
  /// shortens the list.
  static const double screenInsetBottom = 0;

  /// Distance between two entries in a [ScalingLazyColumn].
  static const double itemSpacing = 4;

  /// Height of the composer row pinned to the bottom of the transcript.
  ///
  /// Shared because the list reserves this much space below its last message,
  /// and anything that scrolls "to the bottom" has to account for it.
  static const double composerHeight = 64;

  /// Gutters for a full-panel prompt: clear of the clock, the bezel arc and
  /// the page dots.
  ///
  /// These pages are plain Columns rather than scaling lists, so they get no
  /// top spacer from the list machinery; without this their title sits under
  /// the clock and a field's text runs into the bezel on both sides.
  static const EdgeInsets promptInsets = EdgeInsets.fromLTRB(
    space4,
    46,
    space4,
    space4,
  );

  // ── position indicator ────────────────────────────────────────────────
  /// A hairline, as on the watch's own apps: the bar on a round panel has to
  /// read without taking width away from the cards beside it.
  static const double indicatorThickness = 4;
  static const double indicatorSideMargin = 3;
  static const double indicatorMinLength = 20;

  /// How much of the panel height the bar occupies, centred.
  ///
  /// A bar spanning the whole right edge reads as a second border on a round
  /// screen; the apps that look right keep it to a short run in the middle of
  /// the panel, where the bezel is at its widest.
  static const double indicatorTrackFraction = 0.24;

  /// The track is barely there — the thumb is the information.
  static const double indicatorInactiveOpacity = 0.05;
  static const double indicatorActiveOpacity = 0.95;

  // ── progress ──────────────────────────────────────────────────────────
  static const double progressDefaultSize = 48;
  static const double progressStrokeWidth = 4;

  // ── motion ────────────────────────────────────────────────────────────
  static const Duration durationFast = Duration(milliseconds: 120);
  static const Duration durationBase = Duration(milliseconds: 200);
  static const Duration durationSlow = Duration(milliseconds: 320);
  static const Curve motionStandard = Curves.easeOutCubic;
  static const Curve motionEmphasized = Curves.easeOutQuart;
}

/// Round-screen geometry helpers.
///
/// A watch panel is either round or squarish, and only the app can decide how
/// much of the corners it is willing to lose. Everything here is derived from
/// the current [MediaQuery] so the same widget tree works in the widget tests,
/// on a desktop window and on a real device.
abstract final class WearScreen {
  /// True when the panel has a 1:1 aspect ratio, the signature of a round
  /// Wear OS device.
  static bool isRound(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    if (size.width <= 0 || size.height <= 0) {
      return false;
    }
    return (size.width - size.height).abs() <= 1.0;
  }

  /// Shortest panel edge in logical pixels.
  static double shortestSide(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return math.min(size.width, size.height);
  }

  /// Insets that keep content clear of the bezel.
  ///
  /// [top] can be raised when the screen puts a [TimeText] above the content.
  static EdgeInsets insets(
    BuildContext context, {
    double top = 0,
    double bottom = 0,
  }) {
    /*
     * Card gutters, not a safe area.
     *
     * This is how the reference reader on this watch solves the round panel:
     * each row keeps a fixed horizontal margin (its cardMarginH is 12), and the
     * list centres its content vertically so the rows that are on screen sit
     * across the widest part of the circle. Nothing is reserved at the top or
     * bottom, because the rows themselves never reach the arc.
     */
    return EdgeInsets.only(
      left: WearTokens.cardMarginH,
      right: WearTokens.cardMarginH,
      top: top + WearTokens.screenInsetTop,
      bottom: bottom + WearTokens.screenInsetBottom,
    );
  }
}

/// Convenience access to the Wear tokens that depend on the theme.
extension WearTokensX on BuildContext {
  ColorScheme get wearColors => Theme.of(this).colorScheme;

  TextTheme get wearText => Theme.of(this).textTheme;

  /// The card colour for a given surface level, keeping the call sites free of
  /// raw Material role names.
  Color wearSurface({bool elevated = false, bool selected = false}) {
    final colors = wearColors;
    if (selected) {
      return colors.primaryContainer;
    }
    return elevated ? colors.surfaceContainerHigh : colors.surfaceContainer;
  }
}
