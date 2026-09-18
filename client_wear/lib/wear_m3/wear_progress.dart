import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// A circular progress indicator drawn for a small round screen: a soft track
/// with a round-capped arc on top, and an indeterminate mode that sweeps a
/// quarter arc around the ring.
class WearCircularProgress extends StatefulWidget {
  const WearCircularProgress({
    super.key,
    this.value,
    this.size = WearTokens.progressDefaultSize,
    this.strokeWidth = WearTokens.progressStrokeWidth,
    this.color,
    this.trackColor,
    this.semanticLabel,
    this.showTrack = true,
  });

  /// 0..1 for a determinate ring, null for an indeterminate sweep.
  final double? value;

  final double size;
  final double strokeWidth;
  final Color? color;
  final Color? trackColor;
  final String? semanticLabel;
  final bool showTrack;

  @override
  State<WearCircularProgress> createState() => _WearCircularProgressState();
}

class _WearCircularProgressState extends State<WearCircularProgress>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  @override
  void initState() {
    super.initState();
    if (widget.value == null) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant WearCircularProgress oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value == null && !_controller.isAnimating) {
      _controller.repeat();
    } else if (widget.value != null && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final determinate = widget.value != null;
    final semanticsValue = widget.semanticLabel;

    Widget ring = AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => CustomPaint(
        size: Size.square(widget.size),
        painter: _RingPainter(
          progress: determinate ? widget.value!.clamp(0.0, 1.0) : null,
          turn: _controller.value,
          color: widget.color ?? colors.primary,
          trackColor: widget.trackColor ?? colors.surfaceContainerHighest,
          strokeWidth: widget.strokeWidth,
          showTrack: widget.showTrack,
        ),
      ),
    );

    if (determinate) {
      ring = Semantics(
        label: semanticsValue ?? 'Progress',
        value: '${(widget.value!.clamp(0.0, 1.0) * 100).round()}%',
        child: ring,
      );
    } else {
      ring = Semantics(label: semanticsValue ?? 'Loading', child: ring);
    }

    return SizedBox.square(dimension: widget.size, child: ring);
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.progress,
    required this.turn,
    required this.color,
    required this.trackColor,
    required this.strokeWidth,
    required this.showTrack,
  });

  final double? progress;
  final double turn;
  final Color color;
  final Color trackColor;
  final double strokeWidth;
  final bool showTrack;

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = (math.min(size.width, size.height) - strokeWidth) / 2;
    if (radius <= 0) {
      return;
    }

    final track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = trackColor;

    final arc = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..color = color;

    if (showTrack) {
      canvas.drawCircle(center, radius, track);
    }

    if (progress != null) {
      if (progress! <= 0) {
        return;
      }
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        2 * math.pi * progress!,
        false,
        arc,
      );
      return;
    }

    // Indeterminate: a growing and shrinking quarter-ish sweep, the same
    // rhythm as the Wear Compose indicator.
    final sweep = math.pi * (0.18 + 0.55 * _eased(turn));
    final start = 2 * math.pi * turn - math.pi / 2;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      start,
      sweep,
      false,
      arc,
    );
  }

  /// Ping-pongs the sweep length across one animation cycle.
  static double _eased(double t) => 1 - (2 * (t - 0.5)).abs();

  @override
  bool shouldRepaint(covariant _RingPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.turn != turn ||
      oldDelegate.color != color ||
      oldDelegate.trackColor != trackColor ||
      oldDelegate.strokeWidth != strokeWidth ||
      oldDelegate.showTrack != showTrack;
}
