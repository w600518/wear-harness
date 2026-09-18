import 'dart:async';

import 'package:flutter/material.dart';

import 'tokens.dart';

/// The Wear clock pinned to the top of a round screen.
///
/// The minute is refreshed on a timer aligned to the wall clock rather than a
/// fixed interval, and the widget dims and lifts slightly while a linked list
/// is scrolling so it never competes with the content underneath it.
class TimeText extends StatefulWidget {
  const TimeText({
    super.key,
    this.controller,
    this.alignment = Alignment.topCenter,
    this.padding = EdgeInsets.zero,
    this.use24HourFormat,
    this.color,
    this.scrollFade = true,
    this.textStyle,
  });

  /// Optional list controller. When provided the clock reacts to scrolling.
  final ScrollController? controller;

  final Alignment alignment;
  final EdgeInsets padding;

  /// Overrides the platform 24 hour preference, mostly for tests.
  final bool? use24HourFormat;

  final Color? color;
  final bool scrollFade;
  final TextStyle? textStyle;

  /// `H:mm` on a 24 hour platform and `h:mm` otherwise, exactly the two shapes
  /// Wear OS uses. No AM/PM marker, the watch face already carries the context.
  static String formatTime(DateTime time, {required bool use24HourFormat}) {
    final minute = time.minute.toString().padLeft(2, '0');
    if (use24HourFormat) {
      return '${time.hour}:$minute';
    }
    final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
    return '$hour:$minute';
  }

  @override
  State<TimeText> createState() => _TimeTextState();
}

class _TimeTextState extends State<TimeText> {
  Timer? _minuteTimer;
  Timer? _scrollTimer;
  late DateTime _now = DateTime.now();
  bool _scrolling = false;

  @override
  void initState() {
    super.initState();
    _scheduleMinuteTick();
    widget.controller?.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(covariant TimeText oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?.removeListener(_onScroll);
      widget.controller?.addListener(_onScroll);
    }
  }

  @override
  void dispose() {
    _minuteTimer?.cancel();
    _scrollTimer?.cancel();
    widget.controller?.removeListener(_onScroll);
    super.dispose();
  }

  /// Wakes up just after the next minute boundary.
  void _scheduleMinuteTick() {
    _minuteTimer?.cancel();
    final now = DateTime.now();
    final nextMinute = DateTime(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute,
    ).add(const Duration(minutes: 1));
    final delay = nextMinute.difference(now) + const Duration(milliseconds: 40);
    _minuteTimer = Timer(delay, () {
      if (!mounted) {
        return;
      }
      setState(() => _now = DateTime.now());
      _scheduleMinuteTick();
    });
  }

  void _onScroll() {
    if (!widget.scrollFade) {
      return;
    }
    if (!_scrolling) {
      setState(() => _scrolling = true);
    }
    _scrollTimer?.cancel();
    _scrollTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted) {
        setState(() => _scrolling = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final use24 = widget.use24HourFormat ?? media.alwaysUse24HourFormat;
    final colors = Theme.of(context).colorScheme;
    final style = (widget.textStyle ?? Theme.of(context).textTheme.titleMedium!)
        .copyWith(
          color: widget.color ?? colors.onSurfaceVariant,
          fontWeight: FontWeight.w600,
          fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
        );

    return Align(
      alignment: widget.alignment,
      child: Padding(
        padding: widget.padding.add(
          /*
           * Two pixels, not eight. The clock is an overlay and the first card
           * starts at the very top of the list, so every pixel of gap here
           * pushes the time further down onto that card's text.
           */
          const EdgeInsets.only(top: 2),
        ),
        child: AnimatedOpacity(
          opacity: _scrolling ? 0.35 : 1,
          duration: WearTokens.durationFast,
          curve: WearTokens.motionStandard,
          child: AnimatedSlide(
            offset: _scrolling ? const Offset(0, -0.08) : Offset.zero,
            duration: WearTokens.durationFast,
            curve: WearTokens.motionStandard,
            child: Text(
              TimeText.formatTime(_now, use24HourFormat: use24),
              style: style,
              textAlign: TextAlign.center,
              semanticsLabel: 'Current time',
            ),
          ),
        ),
      ),
    );
  }
}
