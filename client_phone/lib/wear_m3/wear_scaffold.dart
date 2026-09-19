import 'package:flutter/material.dart';

import 'time_text.dart';
import 'tokens.dart';

/// A swipe starting at the left edge pops the current route.
///
/// Armed only when there is something to pop and only for drags that begin
/// inside the edge strip, so the home pager keeps its own horizontal drags
/// everywhere else on the screen.
class EdgeBackGesture extends StatefulWidget {
  const EdgeBackGesture({
    super.key,
    required this.enabled,
    required this.child,
  });

  final bool enabled;
  final Widget child;

  /// Width of the strip that counts as the edge.
  static const double edgeWidth = 48;

  @override
  State<EdgeBackGesture> createState() => _EdgeBackGestureState();
}

class _EdgeBackGestureState extends State<EdgeBackGesture> {
  double _startX = double.infinity;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return widget.child;
    }
    return GestureDetector(
      onHorizontalDragStart: (details) {
        _startX = details.globalPosition.dx;
      },
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (_startX <= EdgeBackGesture.edgeWidth && velocity > 300) {
          Navigator.of(context).maybePop();
        }
        _startX = double.infinity;
      },
      child: widget.child,
    );
  }
}

/// Screen shell for a Wear app: a flat black backdrop, the Wear clock pinned to
/// the top, and content inside round-screen safe insets.
class WearScaffold extends StatelessWidget {
  const WearScaffold({
    super.key,
    required this.child,
    this.top,
    this.bottom,
    this.overlays = const <Widget>[],
    this.showTimeText = true,
    this.timeTextController,
    this.contentPadding,
    this.backgroundColor,
    this.resizeToAvoidBottomInset = true,
    this.showGlow = false,
    this.edgeBack = true,
  });

  /// The screen body. It is already inside the bezel-safe inset.
  final Widget child;

  /// Extra widget under the clock and above [child] (a title, a chip row).
  final Widget? top;

  /// Widget pinned to the bottom of the safe inset.
  final Widget? bottom;

  /// Widgets drawn over the whole panel, outside the content inset.
  ///
  /// A scroll bar belongs here: it hugs the hardware bezel, and the body's
  /// inset box ends well inside that circle, so placing it with the content
  /// would clip it away exactly where the panel is widest. Each entry is
  /// stretched to fill the panel.
  final List<Widget> overlays;

  final bool showTimeText;
  final ScrollController? timeTextController;
  final EdgeInsets? contentPadding;
  final Color? backgroundColor;
  final bool resizeToAvoidBottomInset;

  /// Off by default: the backdrop is flat black, so the panel stays black and
  /// an OLED watch does not light pixels it does not need.
  final bool showGlow;

  /// Whether a swipe from the left edge pops this route.
  ///
  /// A page that owns horizontal drags — a pager moving between steps — turns
  /// this off: the edge strip would otherwise compete with its own swipes, and
  /// the two gestures resolve into whichever recognizer wins the arena.
  final bool edgeBack;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isDark = colors.brightness == Brightness.dark;
    final insets = contentPadding ?? WearScreen.insets(context);

    return EdgeBackGesture(
      enabled: edgeBack && Navigator.of(context).canPop(),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: resizeToAvoidBottomInset,
        body: DecoratedBox(
          decoration: BoxDecoration(
            color: backgroundColor ?? WearTokens.backdrop,
            gradient: (isDark && showGlow)
                ? RadialGradient(
                    center: const Alignment(0, -0.75),
                    radius: 1.1,
                    colors: <Color>[
                      colors.primary.withValues(alpha: 0.10),
                      (backgroundColor ?? WearTokens.backdrop),
                    ],
                  )
                : null,
          ),
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: Padding(
                  padding: insets,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      ?top,
                      Expanded(child: child),
                      /* No gap above the dots: the strip between the last card
                     * and the page indicator read as an empty black bar, and
                     * the dots are small enough to sit right under the content. */
                      ?bottom,
                    ],
                  ),
                ),
              ),
              if (showTimeText)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: MediaQuery.removePadding(
                    context: context,
                    removeTop: true,
                    child: TimeText(controller: timeTextController),
                  ),
                ),
              /*
             * Overlays last so they sit above the body, and outside the inset
             * padding so they can reach the bezel.
             */
              for (final overlay in overlays) Positioned.fill(child: overlay),
            ],
          ),
        ),
      ),
    );
  }
}
