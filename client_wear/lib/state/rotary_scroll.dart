import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The platform channel the crown arrives on.
///
/// Owned here rather than by the app: the crown's scrolling and its switch are
/// two directions of one conversation, and splitting them across files is how
/// the two ends drift apart.
const MethodChannel _channel = MethodChannel('com.dsh.client_wear/rotary');

/// The page the rotary crown drives.
///
/// One page is on screen at a time and each keeps its own scroll controller, so
/// the page that becomes active claims the crown and gives it back on the way
/// out. Without a claim the crown would have to guess, and a watch whose crown
/// scrolls the wrong list is worse than one whose crown does nothing.
///
/// The claim is made from `build` rather than from a lifecycle callback: it is
/// idempotent, and the one builder that drives it — `ActiveListenableBuilder` —
/// only rebuilds the page that is actually on screen, which is exactly the set
/// that should be claiming.
class RotaryScroll {
  RotaryScroll._();

  /// Starts listening for the crown.
  ///
  /// Called before the first frame: the crown can be turned while the app is
  /// still painting its first list, and a handler installed later would drop
  /// those turns.
  static void attach() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'scroll') {
        final delta = call.arguments;
        if (delta is num) {
          scrollBy(delta.toDouble());
        }
      }
    });
  }

  /// Tells the platform whether a turn should tick.
  ///
  /// Sent rather than read back: the switch belongs to the app's settings, and
  /// the platform has no business parsing them to find it.
  static Future<void> setVibrate(bool enabled) async {
    await _channel.invokeMethod('setVibrate', enabled);
  }

  /// Claims, innermost last.
  ///
  /// A stack rather than a single slot because pages are pushed over one
  /// another: a picker opens on top of the session list, and when it closes the
  /// list underneath has to take the crown back without being rebuilt. Releasing
  /// the top claim is what uncovers the one below.
  static final List<ScrollController> _stack = <ScrollController>[];

  /// Hands the crown to [controller], above whatever held it.
  static void claim(ScrollController controller) {
    _stack.removeWhere((held) => identical(held, controller));
    _stack.add(controller);
  }

  /// Releases the crown, if [controller] holds it.
  ///
  /// Removing by identity rather than popping matters when a page is disposed
  /// out of order — a swept-away route can leave before the one above it — and
  /// the claim simply is not there to remove in that case.
  static void release(ScrollController controller) {
    _stack.removeWhere((held) => identical(held, controller));
  }

  static ScrollController? get _claimed =>
      _stack.isEmpty ? null : _stack.last;

  /// Moves the claimed list by [delta] crown units, and ticks if it moved.
  ///
  /// The platform is not asked to tick on its own: it sees the crown turn but
  /// cannot tell whether anything is there to move, so a page with a list that
  /// does not scroll — or none at all — buzzed under the finger with nothing
  /// happening. The tick is requested from here instead, where the movement is
  /// known to have happened.
  static void scrollBy(double delta) {
    final controller = _claimed;
    if (controller == null || !controller.hasClients) {
      return;
    }
    final position = controller.position;
    if (!position.hasViewportDimension) {
      return;
    }
    final target = (position.pixels + delta * pixelsPerUnit)
        .clamp(position.minScrollExtent, position.maxScrollExtent);

    /*
     * The list is against the end this turn pushes toward: the crown is turning
     * and the list is not. A tick here would answer a movement that never
     * happened, which is why reaching the top or the bottom goes silent.
     *
     * The slack covers the fraction of a pixel a settled position can sit short
     * of the extent; without it, turning into an end would keep ticking for
     * hundredths of a pixel. The accumulated movement is dropped rather than
     * kept, so turning into an end does not bank a tick that fires the instant
     * the crown is turned back.
     */
    if ((target - position.pixels).abs() < _endSlack) {
      _accumulated = 0;
      return;
    }

    /* Straight to the new offset, not animated: the crown is already the
     * animation, and easing every detent would lag a finger behind itself. */
    controller.jumpTo(target);

    _accumulated += delta;
    if (_accumulated.abs() < tickThreshold) {
      return;
    }

    /*
     * Two ticks closer together than this merge into one continuous buzz, which
     * is both unlike a detent and hard on the motor — the effect itself runs for
     * 30ms, so anything under that cannot even be felt as two. The movement is
     * kept rather than dropped while waiting, so a fast turn ticks again as soon
     * as the gap has passed instead of losing what was turned.
     */
    final now = _clock.elapsed;
    final last = _lastTick;
    if (last != null && now - last < tickInterval) {
      return;
    }
    _lastTick = now;
    _accumulated = 0;
    unawaited(_channel.invokeMethod<void>('tick'));
  }

  /// The shortest gap between two ticks.
  static const Duration tickInterval = Duration(milliseconds: 40);

  /// Time since the app started, for pacing the tick.
  ///
  /// A stopwatch rather than the wall clock: it is monotonic, so a clock
  /// adjustment cannot make the next tick wait longer than it should or fire
  /// early.
  static final Stopwatch _clock = Stopwatch()..start();

  /// When the last tick was asked for, or null before the first.
  static Duration? _lastTick;

  /// Sub-pixel slack for the end-of-list test.
  static const double _endSlack = 0.5;

  /// Crown units between two ticks.
  ///
  /// The stock widget ticks after roughly 24px of movement, and this axis
  /// reports on that same order, so the same number gives the same cadence:
  /// two or three detents between ticks rather than a buzz on every event.
  static const double tickThreshold = 24;

  /// Movement since the last tick.
  static double _accumulated = 0;

  /// List pixels one crown unit moves.
  ///
  /// The crown counts in the units the list scrolls in: the stock widget
  /// accumulates the same axis straight into a pixel offset and ticks at 24. A
  /// conversion of one is kept named rather than inlined so the two sides have
  /// one place to disagree in, should a watch ever report otherwise.
  static const double pixelsPerUnit = 1;
}
