import 'package:flutter/material.dart';

import 'tokens.dart';

/// The page dots a Wear app puts under a horizontally paged surface.
///
/// Deliberately small and quiet: on a round watch the dots are the only hint
/// that there is more than one page, so they sit close to the bottom bezel
/// where a swipe naturally ends.
class WearPageIndicator extends StatelessWidget {
  const WearPageIndicator({
    super.key,
    required this.count,
    required this.current,
    this.onSelected,
    this.semanticLabel,
  });

  final int count;
  final int current;

  /// Called with the page index when a dot is tapped.
  final ValueChanged<int>? onSelected;

  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    return Semantics(
      label: semanticLabel ?? '第 ${current + 1} 页，共 $count 页',
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          for (var i = 0; i < count; i++)
            GestureDetector(
              onTap: onSelected == null ? null : () => onSelected!(i),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                /*
                 * No vertical padding: the row sits directly under the content,
                 * and any space above the dots turns into a black band across
                 * the bottom of the panel. The tap target is still wide enough
                 * horizontally for a fingertip.
                 */
                padding: const EdgeInsets.symmetric(horizontal: 5),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  curve: Curves.easeOut,
                  width: i == current ? 14 : 5,
                  height: 4,
                  decoration: BoxDecoration(
                    color: i == current
                        ? colors.primary
                        : colors.outlineVariant,
                    borderRadius: const BorderRadius.all(
                      Radius.circular(WearTokens.radiusIndicator),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
