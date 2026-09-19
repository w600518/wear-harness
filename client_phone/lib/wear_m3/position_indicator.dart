import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// The Wear scroll bar: a softly rounded thumb on the right bezel whose length
/// tracks how much of the list is visible and whose position tracks the
/// current offset.
///
/// It fades out shortly after scrolling stops so the small round screen is not
/// permanently cluttered, and it hides itself entirely when the list fits.
class PositionIndicator extends StatefulWidget {
  const PositionIndicator({
    super.key,
    required this.controller,
    this.fadeWhenIdle = true,
    this.idleDelay = const Duration(milliseconds: 1200),
    this.color,
    this.sideMargin = WearTokens.indicatorSideMargin,
    this.thickness = WearTokens.indicatorThickness,
    /*
     * Straight by default on this build.
     *
     * The arc follows the bezel because a vertical bar on a circular panel only
     * touches the edge at its middle and floats inside it everywhere else — a
     * straight bar there reads as content, not as chrome. A rectangular screen
     * has no such problem, and the curved path is also the more expensive of the
     * two: it is rebuilt from a line segment every two logical pixels on each
     * paint. The watch build keeps the arc; this one draws one line.
     */
    this.straight = true,
  });

  final ScrollController controller;

  /// Fades the indicator out once scrolling stops.
  final bool fadeWhenIdle;
  final Duration idleDelay;
  final Color? color;
  final double sideMargin;
  final double thickness;

  /// Draws the bar straight down the right side instead of along the bezel arc.
  final bool straight;

  @override
  State<PositionIndicator> createState() => _PositionIndicatorState();
}

class _PositionIndicatorState extends State<PositionIndicator> {
  Timer? _idleTimer;
  bool _active = false;

  @override
  void initState() {
    super.initState();
    _active = !widget.fadeWhenIdle;
    widget.controller.addListener(_onScroll);
    // A scroll position only reports its viewport dimension after the first
    // layout, so the very first evaluation has to wait for the frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        setState(() {});
      }
    });
  }

  @override
  void didUpdateWidget(covariant PositionIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onScroll);
      widget.controller.addListener(_onScroll);
    }
    if (oldWidget.fadeWhenIdle != widget.fadeWhenIdle) {
      _active = !widget.fadeWhenIdle;
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onScroll);
    _idleTimer?.cancel();
    super.dispose();
  }

  void _onScroll() {
    if (!widget.fadeWhenIdle) {
      return;
    }
    if (!_active) {
      setState(() => _active = true);
    }
    _idleTimer?.cancel();
    _idleTimer = Timer(widget.idleDelay, () {
      if (mounted) {
        setState(() => _active = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    /*
     * White, not the accent. On this watch the apps that already look right
     * (Wear QQ's conversation list among them) draw the bar in plain white on
     * the black field, which keeps it legible at four pixels wide without
     * competing with the content for attention.
     */
    final thumbColor = widget.color ?? colors.onSurface;

    /*
     * Fills whatever box it is given, rather than positioning itself: callers
     * place it with a Positioned inside their own Stack, and returning another
     * Positioned from here would nest two of them under one parent, which
     * Flutter rejects as competing ancestors.
     *
     * The whole panel is needed rather than a bar-shaped strip on the right,
     * because the thumb follows the bezel arc and so the painter needs the
     * screen's centre and radius.
     */
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final metrics = _metrics();
          if (metrics == null) {
            return const SizedBox.shrink();
          }
          return AnimatedOpacity(
            opacity: _active ? 1 : 0,
            duration: WearTokens.durationFast,
            curve: WearTokens.motionStandard,
            child: CustomPaint(
              painter: _PositionIndicatorPainter(
                thumbFraction: metrics.thumbFraction,
                offsetFraction: metrics.offsetFraction,
                viewportHeight: metrics.viewportHeight,
                thumbColor: thumbColor,
                trackColor: colors.onSurface.withValues(
                  alpha: WearTokens.indicatorInactiveOpacity,
                ),
                thickness: widget.thickness,
                sideMargin: widget.sideMargin,
                straight: widget.straight,
                /*
                 * Panel geometry, not this widget's box. The indicator lives
                 * in the scaffold's overlay layer, which is stretched to the
                 * whole panel, so its origin is the panel origin — passing the
                 * content inset here would shift the arc and flatten its
                 * curve.
                 */
                screenSize: MediaQuery.sizeOf(context),
                origin: Offset.zero,
              ),
              child: const SizedBox.expand(),
            ),
          );
        },
      ),
    );
  }

  _IndicatorMetrics? _metrics() {
    if (!widget.controller.hasClients) {
      return null;
    }
    final position = widget.controller.position;
    /*
     * `viewportDimension` is only readable once a layout pass has measured the
     * viewport, and a controller reports clients before that happens — the
     * window a list rebuilding on every frame passes straight through. Asking
     * whether the dimension is known yet is the difference between a bar that
     * appears a frame late and a null-check crash.
     */
    if (!position.hasViewportDimension) {
      return null;
    }
    final viewport = position.viewportDimension;
    if (!viewport.isFinite || viewport <= 0) {
      return null;
    }
    final content = position.maxScrollExtent + viewport;
    if (content <= viewport + 0.5) {
      // The list already fits; a scroll bar would be noise.
      return null;
    }
    return _IndicatorMetrics(
      thumbFraction: (viewport / content).clamp(0.08, 1.0),
      offsetFraction: position.maxScrollExtent <= 0
          ? 0.0
          : (position.pixels / position.maxScrollExtent).clamp(0.0, 1.0),
      viewportHeight: viewport,
    );
  }
}

class _IndicatorMetrics {
  const _IndicatorMetrics({
    required this.thumbFraction,
    required this.offsetFraction,
    required this.viewportHeight,
  });

  final double thumbFraction;
  final double offsetFraction;

  /// Height of the list viewport, used to place the thumb on the panel.
  final double viewportHeight;
}

/// Paints the thumb as an arc hugging the bezel instead of a straight bar.
///
/// A round panel's usable width shrinks towards the top and bottom, so a
/// vertical bar on the right is only touching the edge across the middle and
/// floats inside it everywhere else. Following the circle keeps the bar at a
/// constant distance from the bezel the whole way down.
class _PositionIndicatorPainter extends CustomPainter {
  _PositionIndicatorPainter({
    required this.thumbFraction,
    required this.offsetFraction,
    required this.viewportHeight,
    required this.thumbColor,
    required this.trackColor,
    required this.thickness,
    required this.sideMargin,
    required this.screenSize,
    required this.origin,
    required this.straight,
  });

  final double thumbFraction;
  final double offsetFraction;
  final double viewportHeight;
  final Color thumbColor;
  final Color trackColor;
  final double thickness;
  final double sideMargin;

  /// Size of the whole panel.
  final Size screenSize;

  /// Where this painter's box starts inside the panel.
  final Offset origin;

  /// Draws a straight bar rather than an arc along the bezel.
  final bool straight;

  /// Right-hand edge of the bezel at a given height in *this* box's space.
  ///
  /// Everything is converted to panel coordinates before the circle maths and
  /// converted back afterwards, so the bar lands where the hardware bezel is
  /// rather than where the content inset happens to end.
  double _edgeX(double localY) {
    final radius = (screenSize.shortestSide / 2) - sideMargin - (thickness / 2);
    if (radius <= 0) {
      return screenSize.width / 2 - origin.dx;
    }
    final centreX = screenSize.width / 2;
    final dy = (origin.dy + localY) - (screenSize.height / 2);
    if (dy.abs() >= radius) {
      return centreX - origin.dx;
    }
    return centreX + math.sqrt((radius * radius) - (dy * dy)) - origin.dx;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.height <= 0 || size.width <= 0) {
      return;
    }

    /*
     * The bar lives in the middle of the panel rather than spanning the right
     * edge. Wear's apps keep it that way: on a round screen a full-height bar
     * competes with the bezel for attention and is hardest to read exactly
     * where the panel is narrowest.
     */
    final trackHeight = size.height * WearTokens.indicatorTrackFraction;
    final trackTop = (size.height - trackHeight) / 2;

    final thumbHeight = (trackHeight * thumbFraction).clamp(
      WearTokens.indicatorMinLength,
      trackHeight,
    );
    final travel = trackHeight - thumbHeight;
    final thumbTop = trackTop + (travel * offsetFraction);

    final trackPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round
      ..color = trackColor
      ..isAntiAlias = true;
    final thumbPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness
      ..strokeCap = StrokeCap.round
      ..color = thumbColor.withValues(
        alpha: WearTokens.indicatorActiveOpacity,
      )
      ..isAntiAlias = true;

    if (straight) {
      /*
       * One vertical line each for the track and the thumb, inset from the
       * right edge. No path is built and the panel's centre and radius are not
       * consulted: on a rectangular screen the edge is where the box ends.
       */
      final x = size.width - sideMargin - (thickness / 2);
      canvas.drawLine(
        Offset(x, trackTop),
        Offset(x, trackTop + trackHeight),
        trackPaint,
      );
      canvas.drawLine(
        Offset(x, thumbTop),
        Offset(x, thumbTop + thumbHeight),
        thumbPaint,
      );
      return;
    }

    /* Track: the same arc over the same span, barely visible. */
    canvas.drawPath(
      _arcBetween(size, trackTop, trackTop + trackHeight),
      trackPaint,
    );

    canvas.drawPath(
      _arcBetween(size, thumbTop, thumbTop + thumbHeight),
      thumbPaint,
    );
  }

  /// Builds the bezel-hugging path between two heights in this box's space.
  Path _arcBetween(Size size, double from, double to) {
    final path = Path();
    for (var y = from; y <= to; y += 2.0) {
      final x = _edgeX(y);
      if (y == from) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.lineTo(_edgeX(to), to);
    return path;
  }

  @override
  bool shouldRepaint(covariant _PositionIndicatorPainter oldDelegate) =>
      oldDelegate.thumbFraction != thumbFraction ||
      oldDelegate.offsetFraction != offsetFraction ||
      oldDelegate.viewportHeight != viewportHeight ||
      oldDelegate.thumbColor != thumbColor ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.thickness != thickness ||
      oldDelegate.sideMargin != sideMargin ||
      oldDelegate.screenSize != screenSize ||
      oldDelegate.origin != origin ||
      oldDelegate.straight != straight;
}
