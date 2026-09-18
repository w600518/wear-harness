import 'package:flutter/material.dart';

import 'tokens.dart';

/// Visual treatments of a [WearCard], mirroring the Wear M3 card variants.
enum WearCardVariant {
  /// Solid container colour, the default on a dark watch face.
  filled,

  /// Tonal surface with a subtle lift, for content that should stand out.
  elevated,

  /// Transparent with a hairline outline, for lightweight grouping.
  outlined,
}

/// A rounded Wear card with an optional leading icon and a title/subtitle
/// stack, tappable with either a fingertip or a mouse.
class WearCard extends StatelessWidget {
  const WearCard({
    super.key,
    this.child,
    this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.variant = WearCardVariant.filled,
    this.bordered = false,
    this.padding,
    this.semanticLabel,
  });

  /// Fully custom content. When provided, [title], [subtitle], [leading] and
  /// [trailing] are ignored.
  final Widget? child;

  final String? title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool selected;
  final WearCardVariant variant;

  /// Draws the same hairline outline the chips carry, while keeping this
  /// variant's fill.
  ///
  /// [WearCardVariant.outlined] cannot serve that: it pairs the outline with a
  /// transparent surface, so a card that has to look like the pill it replaced
  /// — the composer's expanded field, which opens where the send chip was —
  /// would lose its background to get the edge.
  final bool bordered;

  final EdgeInsetsGeometry? padding;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final shape = RoundedRectangleBorder(
      borderRadius: const BorderRadius.all(
        Radius.circular(WearTokens.radiusCard),
      ),
      side: !selected && (bordered || variant == WearCardVariant.outlined)
          ? BorderSide(color: colors.outlineVariant)
          : BorderSide.none,
    );

    final background = switch ((variant, selected)) {
      (_, true) => colors.primaryContainer,
      (WearCardVariant.filled, false) => colors.surfaceContainer,
      (WearCardVariant.elevated, false) => colors.surfaceContainerHigh,
      (WearCardVariant.outlined, false) => Colors.transparent,
    };
    final foreground = selected ? colors.onPrimaryContainer : colors.onSurface;
    final secondary = selected
        ? colors.onPrimaryContainer.withValues(alpha: 0.8)
        : colors.onSurfaceVariant;

    final content =
        child ??
        _DefaultCardContent(
          title: title,
          subtitle: subtitle,
          leading: leading == null
              ? null
              : _RoundBadge(
                  background: selected
                      ? colors.onPrimaryContainer.withValues(alpha: 0.16)
                      : colors.surfaceContainerHighest,
                  child: IconTheme.merge(
                    data: IconThemeData(color: foreground, size: 20),
                    child: leading!,
                  ),
                ),
          trailing: trailing == null
              ? null
              : IconTheme.merge(
                  data: IconThemeData(color: secondary, size: 20),
                  child: trailing!,
                ),
          titleStyle: Theme.of(
            context,
          ).textTheme.titleMedium!.copyWith(color: foreground),
          subtitleStyle: Theme.of(
            context,
          ).textTheme.bodySmall!.copyWith(color: secondary),
        );

    return Semantics(
      button: onTap != null || onLongPress != null,
      selected: selected,
      label: semanticLabel,
      container: true,
      child: Material(
        color: background,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          mouseCursor: onTap != null || onLongPress != null
              ? SystemMouseCursors.click
              : MouseCursor.defer,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: WearTokens.cardMinHeight,
            ),
            child: Padding(
              padding:
                  padding ??
                  const EdgeInsets.symmetric(
                    horizontal: WearTokens.space4,
                    vertical: WearTokens.space3,
                  ),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}

/// The circular plate a card's leading icon sits on.
///
/// Round-panel apps on this watch put a filled circle behind the leading glyph
/// — Wear QQ's conversation list is the reference. It reads as an avatar and,
/// more practically, keeps a small icon from looking lost inside a wide card.
class _RoundBadge extends StatelessWidget {
  const _RoundBadge({required this.background, required this.child});

  final Color background;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: WearTokens.cardLeadingSize,
      height: WearTokens.cardLeadingSize,
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: child,
    );
  }
}

class _DefaultCardContent extends StatelessWidget {
  const _DefaultCardContent({
    required this.title,
    required this.subtitle,
    required this.leading,
    required this.trailing,
    required this.titleStyle,
    required this.subtitleStyle,
  });

  final String? title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final TextStyle titleStyle;
  final TextStyle subtitleStyle;

  @override
  Widget build(BuildContext context) {
    final texts = <Widget>[
      if (title != null)
        Text(
          title!,
          style: titleStyle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
      if (subtitle != null)
        Padding(
          padding: EdgeInsets.only(
            top: title == null ? 0 : WearTokens.space1 / 2,
          ),
          child: Text(
            subtitle!,
            style: subtitleStyle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ),
    ];

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: <Widget>[
        if (leading != null) ...<Widget>[
          leading!,
          const SizedBox(width: WearTokens.space3),
        ],
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: texts,
          ),
        ),
        if (trailing != null) ...<Widget>[
          const SizedBox(width: WearTokens.space2),
          trailing!,
        ],
      ],
    );
  }
}
