import 'package:flutter/widgets.dart';

/// Rebuilds on [listenable] only while [active] is true.
///
/// A page the pager has swiped away from keeps its [State] — that is what stops
/// a transcript being refolded every time it is passed over — but it has no
/// reason to rebuild when the session notifies. That distinction did not used
/// to matter: notifications were rare. It matters now that a snapshot is folded
/// in under the loading mask, because that notifies once per frame for as long
/// as the history takes to land. With every kept-alive page listening, one
/// visible page's worth of change cost eight rebuilds a frame — the transcript,
/// the session browser, the four inside the config page, the settings page and
/// the interjection list — and three of those pages were not even on screen.
/// That is what stuttered on hardware fast enough to render any one of them
/// comfortably.
///
/// Coming back into view takes one deliberate rebuild, because whatever
/// happened while the page was away was never applied to it.
class ActiveListenableBuilder extends StatefulWidget {
  const ActiveListenableBuilder({
    super.key,
    required this.active,
    required this.listenable,
    required this.builder,
  });

  /// Whether this subtree is on screen and should follow [listenable].
  final bool active;

  final Listenable listenable;
  final WidgetBuilder builder;

  @override
  State<ActiveListenableBuilder> createState() =>
      _ActiveListenableBuilderState();
}

class _ActiveListenableBuilderState extends State<ActiveListenableBuilder> {
  bool _subscribed = false;

  @override
  void initState() {
    super.initState();
    _sync();
  }

  @override
  void didUpdateWidget(covariant ActiveListenableBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.listenable != widget.listenable) {
      if (_subscribed) {
        oldWidget.listenable.removeListener(_onChanged);
        _subscribed = false;
      }
      _sync();
      return;
    }
    if (oldWidget.active != widget.active) {
      _sync();
    }
  }

  void _sync() {
    final wanted = widget.active;
    if (wanted && !_subscribed) {
      widget.listenable.addListener(_onChanged);
      _subscribed = true;
      /*
       * Everything that arrived while this page was off screen was skipped on
       * purpose, so take one fresh build now that it is back. Deferred to the
       * frame's end because this can run during a build pass.
       */
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.active) {
          setState(() {});
        }
      });
    } else if (!wanted && _subscribed) {
      widget.listenable.removeListener(_onChanged);
      _subscribed = false;
    }
  }

  @override
  void dispose() {
    if (_subscribed) {
      widget.listenable.removeListener(_onChanged);
    }
    super.dispose();
  }

  void _onChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context);
}
