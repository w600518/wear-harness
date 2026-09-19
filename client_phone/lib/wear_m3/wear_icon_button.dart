import 'package:flutter/material.dart';

import 'tokens.dart';

/// Visual treatments of a [WearIconButton].
enum WearButtonVariant {
  /// Solid primary circle, for the single most important action.
  filled,

  /// Tonal circle, the everyday default.
  tonal,

  /// Outline only.
  outlined,

  /// No background at all, for dense rows.
  plain,
}

/// A round icon button sized for a watch: a 48dp square hit area with a
/// circular visual, so it stays reachable by fingertip and obviously clickable
/// by mouse.
class WearIconButton extends StatelessWidget {
  const WearIconButton({
    super.key,
    required this.icon,
    required this.onPressed,
    this.variant = WearButtonVariant.tonal,
    this.tooltip,
    this.semanticLabel,
    this.size = WearTokens.iconButtonSize,
    this.iconSize = WearTokens.iconButtonIconSize,
    this.color,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final WearButtonVariant variant;
  final String? tooltip;
  final String? semanticLabel;
  final double size;
  final double iconSize;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = onPressed != null;

    final (Color background, Color foreground) = switch (variant) {
      WearButtonVariant.filled => (colors.primary, colors.onPrimary),
      WearButtonVariant.tonal => (
        colors.surfaceContainerHighest,
        colors.primary,
      ),
      WearButtonVariant.outlined => (Colors.transparent, colors.onSurface),
      WearButtonVariant.plain => (Colors.transparent, colors.onSurfaceVariant),
    };

    Widget button = Semantics(
      button: true,
      enabled: enabled,
      label: semanticLabel ?? tooltip ?? icon.codePoint.toString(),
      child: Opacity(
        opacity: enabled ? 1 : 0.38,
        child: Material(
          color: background,
          shape: CircleBorder(
            side: variant == WearButtonVariant.outlined
                ? BorderSide(color: colors.outlineVariant)
                : BorderSide.none,
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onPressed,
            customBorder: const CircleBorder(),
            mouseCursor: enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            child: SizedBox(
              width: size,
              height: size,
              child: Icon(icon, size: iconSize, color: color ?? foreground),
            ),
          ),
        ),
      ),
    );

    if (tooltip != null) {
      button = Tooltip(message: tooltip!, child: button);
    }
    return button;
  }
}
