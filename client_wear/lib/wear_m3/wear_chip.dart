import 'package:flutter/material.dart';

import 'tokens.dart';

/// A compact pill for filters and quick actions.
///
/// Fixed height and a fully rounded shape keep it readable on a 384px panel;
/// the whole pill is the touch target, never just the label.
class WearChip extends StatelessWidget {
  const WearChip({
    super.key,
    required this.label,
    this.icon,
    this.avatar,
    this.selected = false,
    this.enabled = true,
    this.onTap,
    this.semanticLabel,
    this.dense = false,
  });

  final String label;
  final IconData? icon;

  /// Widget shown before the label instead of [icon].
  final Widget? avatar;

  final bool selected;
  final bool enabled;
  final VoidCallback? onTap;
  final String? semanticLabel;

  /// Trims the horizontal padding.
  ///
  /// On a 233dp panel four pills at the normal padding plus their gaps come to
  /// more than a row, so a set that has to sit on one line — the reasoning
  /// levels — uses this. The 48dp minimum touch target is unaffected.
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final background = selected
        ? colors.primaryContainer
        : colors.surfaceContainerHigh;
    final foreground = selected ? colors.onPrimaryContainer : colors.onSurface;
    final border = selected ? Colors.transparent : colors.outlineVariant;

    final effective = enabled ? onTap : null;

    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: semanticLabel ?? label,
      child: Opacity(
        opacity: enabled ? 1 : 0.45,
        child: Material(
          color: background,
          shape: RoundedRectangleBorder(
            borderRadius: const BorderRadius.all(
              Radius.circular(WearTokens.radiusChip),
            ),
            side: border == Colors.transparent
                ? BorderSide.none
                : BorderSide(color: border),
          ),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: effective,
            mouseCursor: enabled
                ? SystemMouseCursors.click
                : SystemMouseCursors.basic,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: WearTokens.chipHeight,
                minWidth: WearTokens.touchTarget,
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(
                  horizontal: dense ? WearTokens.space2 : WearTokens.space3,
                  vertical: WearTokens.space1,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (avatar != null) ...<Widget>[
                      avatar!,
                      const SizedBox(width: WearTokens.space1),
                    ] else if (icon != null) ...<Widget>[
                      Icon(
                        icon,
                        size: WearTokens.chipIconSize,
                        color: foreground,
                      ),
                      const SizedBox(width: WearTokens.space1),
                    ],
                    Text(
                      label,
                      style: Theme.of(
                        context,
                      ).textTheme.labelLarge!.copyWith(color: foreground),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Wraps a set of [WearChip]s and lets them flow onto more than one row, which
/// a round screen needs as soon as there are more than two of them.
class WearChipRow extends StatelessWidget {
  const WearChipRow({
    super.key,
    required this.children,
    this.spacing = WearTokens.space2,
    this.runSpacing = WearTokens.space2,
    this.alignment = WrapAlignment.center,
  });

  final List<Widget> children;
  final double spacing;
  final double runSpacing;
  final WrapAlignment alignment;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: spacing,
      runSpacing: runSpacing,
      alignment: alignment,
      children: children,
    );
  }
}
