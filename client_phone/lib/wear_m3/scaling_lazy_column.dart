import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// Builds one entry of a [ScalingLazyColumn].
///
/// [centerDistance] is 0 when the entry sits exactly on the anchor line and 1
/// when it sits at the far edge of the viewport, so a builder can reveal more
/// detail as an entry approaches the centre.
typedef WearItemBuilder =
    Widget Function(BuildContext context, int index, double centerDistance);

/// A Wear-style scrolling column: entries scale down and fade towards the
/// edges, the viewport fades out at both ends, and a scroll that comes to rest
/// snaps the nearest entry onto the anchor line.
///
/// This is a hand-rolled stand-in for Wear Compose's `ScalingLazyColumn`,
/// because Flutter has no first-party Wear component set.
///
/// The transform is purely visual: entries keep their layout height, so
/// measurement stays stable and no feedback loop can form between scrolling
/// and scaling.
class ScalingLazyColumn extends StatefulWidget {
  const ScalingLazyColumn({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.controller,
    this.padding,
    this.anchor = 0.5,
    /*
     * Off by default on this build.
     *
     * The scale-and-fade was drawn for a round 233dp panel, where shrinking an
     * entry as it leaves the anchor line is what tells the eye the list
     * continues past the bezel. On a full-sized rectangular screen it buys
     * nothing the visible edge does not already say, and it costs a transform
     * and an opacity layer per row on every frame. The widget keeps the option
     * — a caller that wants the watch treatment can still ask for it — but no
     * page in this build turns it on.
     */
    this.scalingEnabled = false,
    /*
     * On: the ends are padded by half a viewport so content sits across the
     * middle of the panel. Position only — nothing is clipped or narrowed, and
     * a list taller than the panel simply scrolls.
     */
    this.centerFirstAndLastItem = false,
    this.topSpacer = 0,
    /*
     * Off by default: this column always lives inside a WearScaffold, which
     * has already applied the round-screen insets. Applying them here as well
     * doubled the side margin to 32 dp and left every card floating well inside
     * the bezel instead of sitting against it.
     */
    this.applyScreenInsets = false,
    this.physics,
    this.onCenterItemChanged,
    this.itemSpacing = WearTokens.itemSpacing,
  }) : assert(
         anchor >= 0 && anchor <= 1,
         'anchor is a fraction of the viewport',
       );

  final int itemCount;
  final WearItemBuilder itemBuilder;

  /// Shared with a [PositionIndicator] so the scroll thumb tracks the list.
  final ScrollController? controller;

  /// Padding added on top of the screen insets. The vertical centring padding
  /// is added internally and is not part of this value.
  final EdgeInsets? padding;

  /// Fraction of the viewport height treated as the "centre" line.
  final double anchor;

  final bool scalingEnabled;

  /// Height of a blank run inserted before the first entry.
  ///
  /// It is a real list row, so it scrolls away with the content: the list opens
  /// with its first item clear of the clock, and once the user has scrolled
  /// past it the space is gone. A fixed padding would hold that gap open for
  /// the whole session.
  final double topSpacer;

  /// Adds just enough vertical padding for the first and last entry to reach
  /// [anchor]. Without it the ends of the list can never be centred, which is
  /// the default Wear behaviour.
  final bool centerFirstAndLastItem;

  /// Applies round-screen safe area insets from [WearScreen].
  final bool applyScreenInsets;

  final ScrollPhysics? physics;

  /// Called with the index closest to [anchor] whenever that index changes.
  final ValueChanged<int>? onCenterItemChanged;

  final double itemSpacing;

  @override
  State<ScalingLazyColumn> createState() => _ScalingLazyColumnState();
}

class _ScalingLazyColumnState extends State<ScalingLazyColumn> {
  late final ScrollController _controller;
  late final bool _ownsController;
  final GlobalKey _viewportKey = GlobalKey(
    debugLabel: 'ScalingLazyColumn.viewport',
  );
  final Map<int, _ScalingItemState> _items = <int, _ScalingItemState>{};

  bool _syncScheduled = false;
  int? _centerIndex;

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? ScrollController();
    _controller.addListener(_handleScroll);
    _scheduleSync();
  }

  @override
  void didUpdateWidget(covariant ScalingLazyColumn oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      _controller.removeListener(_handleScroll);
      if (_ownsController) {
        _controller.dispose();
      }
      _controller = widget.controller ?? ScrollController();
      _ownsController = widget.controller == null;
      _controller.addListener(_handleScroll);
    }
    _scheduleSync();
  }

  @override
  void dispose() {
    _controller.removeListener(_handleScroll);
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  RenderBox? _viewportBox() {
    final object = _viewportKey.currentContext?.findRenderObject();
    if (object is! RenderBox || !object.attached || !object.hasSize) {
      return null;
    }
    return object;
  }

  void _attach(int index, _ScalingItemState item) {
    _items[index] = item;
    _scheduleSync();
  }

  void _detach(int index, _ScalingItemState item) {
    if (identical(_items[index], item)) {
      _items.remove(index);
    }
  }

  /// Schedules one measurement pass after the current frame settles, which is
  /// the earliest moment the render objects expose their final geometry.
  void _scheduleSync() {
    if (_syncScheduled) {
      return;
    }
    _syncScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncScheduled = false;
      if (!mounted) {
        return;
      }
      _syncItems();
    });
  }

  void _handleScroll() => _syncItems();

  void _syncItems() {
    final viewport = _viewportBox();
    if (viewport == null) {
      return;
    }
    final anchorY = viewport.size.height * widget.anchor;
    final halfHeight = math.max(viewport.size.height / 2, 1.0);

    int? nearestIndex;
    var nearestDistance = double.infinity;

    for (final entry in _items.entries) {
      final center = entry.value.centerIn(viewport);
      if (center == null) {
        continue;
      }
      final offset = center - anchorY;

      if (entry.value.isUnscaled) {
        /* An entry tagged by the caller as fixed: it keeps full size and full
         * opacity wherever it sits. */
        entry.value.updateDistance(0.0);
      } else {
        entry.value.updateDistance((offset.abs() / halfHeight).clamp(0.0, 1.0));
      }

      if (offset.abs() < nearestDistance) {
        nearestDistance = offset.abs();
        nearestIndex = entry.key;
      }
    }

    if (nearestIndex != null && nearestIndex != _centerIndex) {
      _centerIndex = nearestIndex;
      widget.onCenterItemChanged?.call(nearestIndex);
    }
  }

  bool _handleNotification(ScrollNotification notification) {
    if (notification.depth != 0) {
      return false;
    }
    /*
     * Transforms are kept in step while a fling or a programmatic scroll is in
     * flight, because the controller listener can be coalesced. Nothing is
     * scheduled on settle: the list used to snap its nearest entry onto the
     * anchor line, which fought the user's own scroll position.
     */
    if (notification is ScrollEndNotification ||
        (notification is ScrollUpdateNotification &&
            notification.dragDetails == null)) {
      _syncItems();
    }
    return false;
  }

  double _distanceOf(int index) => _items[index]?.distance ?? 0.0;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportHeight = constraints.maxHeight.isFinite
            ? constraints.maxHeight
            : MediaQuery.sizeOf(context).height;

        final base =
            widget.padding ??
            (widget.applyScreenInsets
                ? WearScreen.insets(context)
                : EdgeInsets.zero);
        final centering =
            widget.centerFirstAndLastItem &&
                widget.scalingEnabled &&
                viewportHeight.isFinite
            ? EdgeInsets.only(
                top: viewportHeight * widget.anchor,
                bottom: viewportHeight * (1 - widget.anchor),
              )
            : EdgeInsets.zero;
        final effectivePadding = base + centering;

        /* The blank run is a real row, so every index below is offset by one. */
        final hasSpacer = widget.topSpacer > 0;

        Widget list = ListView.builder(
          key: _viewportKey,
          controller: _controller,
          padding: effectivePadding,
          physics: widget.physics ?? const ClampingScrollPhysics(),
          itemCount: widget.itemCount + (hasSpacer ? 1 : 0),
          itemExtent: null,
          addAutomaticKeepAlives: false,
          itemBuilder: (context, index) {
            if (hasSpacer && index == 0) {
              return SizedBox(height: widget.topSpacer);
            }
            final itemIndex = hasSpacer ? index - 1 : index;
            final entry = widget.itemBuilder(
              context,
              itemIndex,
              _distanceOf(itemIndex),
            );
            return Padding(
              padding: EdgeInsets.only(
                bottom: itemIndex == widget.itemCount - 1
                    ? 0
                    : widget.itemSpacing,
              ),
              child: _ScalingItem(
                /*
                 * No key. A ValueKey(index) told Flutter the widget at position
                 * i was unchanged whenever the index stayed the same, so a page
                 * whose builder produced new content at the same position — a
                 * message expanding, a block unfolding — was never rebuilt.
                 */
                index: itemIndex,
                scalingEnabled: widget.scalingEnabled,
                onAttached: _attach,
                onDetached: _detach,
                child: entry,
              ),
            );
          },
        );

        /*
         * No ShaderMask here, deliberately.
         *
         * The column used to wrap itself in one to fade the ends out, and it
         * was the most expensive thing on the page: a ShaderMask renders its
         * child into an offscreen layer and then composites it back through a
         * gradient, every frame, over a list as tall as the transcript. On a
         * transcript that repaints as records fold in, that compositing is what
         * the frame budget went on.
         *
         * Each entry already fades itself as it leaves the anchor — see the
         * opacity in [_ScalingItemState] — so the mask was drawing a second,
         * stronger version of an effect that was already there.
         */
        return NotificationListener<ScrollNotification>(
          onNotification: _handleNotification,
          child: list,
        );
      },
    );
  }
}

/// Marks an entry as exempt from the scroll scale.
///
/// Used for a message the user has expanded: once a reply is unfolded to be
/// read, shrinking it as it drifts from the anchor would fight the very thing
/// that was just asked for.
class UnscaledItem extends StatelessWidget {
  const UnscaledItem({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}

/// One entry of a [ScalingLazyColumn], owning the animated transform values.
class _ScalingItem extends StatefulWidget {
  const _ScalingItem({
    required this.index,
    required this.scalingEnabled,
    required this.onAttached,
    required this.onDetached,
    required this.child,
  });

  final int index;
  final bool scalingEnabled;

  final void Function(int index, _ScalingItemState item) onAttached;
  final void Function(int index, _ScalingItemState item) onDetached;
  final Widget child;

  @override
  State<_ScalingItem> createState() => _ScalingItemState();
}

class _ScalingItemState extends State<_ScalingItem> {
  final ValueNotifier<double> _distance = ValueNotifier<double>(0);

  double get distance => _distance.value;

  @override
  void initState() {
    super.initState();
    widget.onAttached(widget.index, this);
  }

  @override
  void didUpdateWidget(covariant _ScalingItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      widget.onDetached(oldWidget.index, this);
      widget.onAttached(widget.index, this);
    }
  }

  @override
  void dispose() {
    widget.onDetached(widget.index, this);
    _distance.dispose();
    super.dispose();
  }

  /// Threshold below which a new distance is not worth a rebuild.
  void updateDistance(double value) {
    if ((_distance.value - value).abs() < 0.002) {
      return;
    }
    _distance.value = value;
  }

  /// Vertical centre of this entry in [viewport]'s coordinate space, or null
  /// when the entry is not laid out (entries scrolled out of the cache are
  /// detached and simply skipped).
  double? centerIn(RenderBox viewport) {
    final object = context.findRenderObject();
    if (object is! RenderBox || !object.attached || !object.hasSize) {
      return null;
    }
    if (!viewport.attached || !viewport.hasSize) {
      return null;
    }
    try {
      return object
          .localToGlobal(Offset(0, object.size.height / 2), ancestor: viewport)
          .dy;
    } on Object {
      return null;
    }
  }

  /// True when this entry was tagged by [UnscaledItem].
  bool get isUnscaled => widget.child is UnscaledItem;

  @override
  Widget build(BuildContext context) {
    final child = widget.child;
    if (!widget.scalingEnabled) {
      return child;
    }
    return ValueListenableBuilder<double>(
      valueListenable: _distance,
      builder: (context, distance, inner) {
        /*
         * Both values come from MR's scroll effect: the entry nearest the
         * anchor is full size and fully opaque, and one a half-viewport away is
         * at 0.82 and 0.45. Scaling is deliberately shallow — a bigger factor
         * makes the list look like it is being squeezed as it scrolls.
         */
        final scale = lerpDouble(
          WearTokens.minItemScale,
          WearTokens.maxItemScale,
          1.0 - distance,
        )!;
        final opacity = lerpDouble(
          WearTokens.minItemOpacity,
          1.0,
          1.0 - distance,
        )!;

        /*
         * The entry under the reader's eye is the common case, and at distance
         * zero both wrappers are no-ops that still cost a layer each. Skipping
         * them leaves the centre entry painted directly, which is most of what
         * is on screen at any moment.
         */
        if (scale >= 0.999 && opacity >= 0.999) {
          return inner ?? const SizedBox.shrink();
        }

        return Opacity(
          opacity: opacity,
          child: Transform.scale(
            scale: scale,
            filterQuality: FilterQuality.low,
            child: inner,
          ),
        );
      },
      child: child,
    );
  }
}
