import 'dart:math' as math;

import 'package:client_wear/main.dart';
import 'package:client_wear/state/relay_session.dart';
import 'package:client_wear/wear_m3/wear_m3.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Shrinks the test window to a round-ish watch panel so viewport maths run
/// against realistic numbers instead of the 800x600 test default.
void useWatchSurface(WidgetTester tester, {Size size = const Size(384, 384)}) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
}

Widget host(Widget child) => MaterialApp(
      theme: WearTheme.dark(),
      home: Scaffold(body: child),
    );

/// Distances between an entry's centre and the viewport centre, for every
/// entry the list currently builds.
List<double> opacitiesInside(WidgetTester tester, Finder of) => tester
    .widgetList<Opacity>(find.descendant(of: of, matching: find.byType(Opacity)))
    .map((Opacity widget) => widget.opacity)
    .toList(growable: false);

void main() {
  group('theme and tokens', () {
    test('the dark scheme is dark first and uses a true black backdrop', () {
      final scheme = WearTheme.darkScheme();
      expect(scheme.brightness, Brightness.dark);
      expect(scheme.surface, WearTokens.backdrop);
      expect(scheme.primary, isNot(equals(WearTheme.lightScheme().primary)));
    });

    testWidgets('WearScreen detects a round panel from the media query',
        (WidgetTester tester) async {
      useWatchSurface(tester);
      late bool round;
      await tester.pumpWidget(host(Builder(builder: (context) {
        round = WearScreen.isRound(context);
        return const SizedBox.shrink();
      })));
      expect(round, isTrue);
      expect(WearTokens.touchTarget, 48);
      expect(WearTokens.radiusCard, 24);
    });
  });

  group('TimeText', () {
    test('formats both platform clock conventions', () {
      expect(
        TimeText.formatTime(DateTime(2024, 1, 1, 9, 5), use24HourFormat: true),
        '9:05',
      );
      expect(
        TimeText.formatTime(DateTime(2024, 1, 1, 15, 7), use24HourFormat: true),
        '15:07',
      );
      expect(
        TimeText.formatTime(DateTime(2024, 1, 1, 15, 7), use24HourFormat: false),
        '3:07',
      );
      expect(
        TimeText.formatTime(DateTime(2024, 1, 1, 0, 0), use24HourFormat: false),
        '12:00',
      );
      expect(
        TimeText.formatTime(DateTime(2024, 1, 1, 12, 30), use24HourFormat: false),
        '12:30',
      );
    });

    testWidgets('renders a clock and dims while its list scrolls',
        (WidgetTester tester) async {
      useWatchSurface(tester);
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(host(Column(
        children: <Widget>[
          TimeText(controller: controller, use24HourFormat: true),
          Expanded(
            child: ListView.builder(
              controller: controller,
              itemCount: 40,
              itemBuilder: (context, index) =>
                  SizedBox(height: 48, child: Text('row $index')),
            ),
          ),
        ],
      )));
      await tester.pump();

      expect(find.textContaining(':'), findsOneWidget);
      final before = tester.widget<AnimatedOpacity>(
        find.descendant(
          of: find.byType(TimeText),
          matching: find.byType(AnimatedOpacity),
        ),
      );
      expect(before.opacity, 1.0);

      controller.jumpTo(120);
      await tester.pump();
      final during = tester.widget<AnimatedOpacity>(
        find.descendant(
          of: find.byType(TimeText),
          matching: find.byType(AnimatedOpacity),
        ),
      );
      expect(during.opacity, lessThan(1.0));

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('ScalingLazyColumn', () {
    testWidgets('scales and fades entries away from the anchor',
        (WidgetTester tester) async {
      useWatchSurface(tester);
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(host(ScalingLazyColumn(
        controller: controller,
        centerFirstAndLastItem: false,
        itemCount: 30,
        itemBuilder: (context, index, centerDistance) =>
            SizedBox(height: 40, child: Text('entry $index')),
      )));
      await tester.pump();
      // The first frame measures; the second one paints the transforms the
      // measurement produced.
      await tester.pump();

      final list = find.byType(ScalingLazyColumn);
      final opacities = opacitiesInside(tester, list);
      expect(opacities.length, greaterThan(2));
      final brightest = opacities.reduce(math.max);
      final dimmest = opacities.reduce(math.min);
      // Entries lay out from the top rather than being centred, so the
      // brightest one sits near — not exactly on — the anchor line.
      expect(brightest, greaterThan(0.9));
      expect(dimmest, lessThan(0.9));
      expect(dimmest, greaterThanOrEqualTo(WearTokens.minItemOpacity - 0.01));

      /*
       * Entries shrink a little as they leave the anchor, matching the
       * reference reader on this watch: full size on the anchor line, 0.82 at
       * the edge. A deeper factor was what made the list look squeezed.
       */
      final scales = tester
          .widgetList<Transform>(
            find.descendant(of: list, matching: find.byType(Transform)),
          )
          .map((Transform transform) => transform.transform.storage[0])
          .toList(growable: false);
      expect(scales, isNotEmpty);
      expect(scales.reduce(math.max), lessThanOrEqualTo(WearTokens.maxItemScale + 0.01));
      expect(scales.reduce(math.min), lessThan(1.0));
      expect(scales.reduce(math.min),
          greaterThanOrEqualTo(WearTokens.minItemScale - 0.01));

      // Entries that are offscreen are not built, but the ones that are must
      // span more than a single row.
      var visible = 0;
      for (var i = 0; i < 30; i++) {
        if (find.text('entry $i').evaluate().isNotEmpty) {
          visible++;
        }
      }
      expect(visible, greaterThan(2));

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('leaves a settled scroll where the user left it',
        (WidgetTester tester) async {
      useWatchSurface(tester);
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(host(ScalingLazyColumn(
        controller: controller,
        itemCount: 30,
        itemBuilder: (context, index, centerDistance) =>
            SizedBox(height: 40, child: Text('entry $index')),
      )));
      await tester.pump();

      /* An offset that is deliberately not a whole number of entries: the list
       * must not pull it onto the anchor line once the scroll settles. */
      const parked = 137.0;
      controller.jumpTo(parked);
      for (var frame = 0; frame < 24; frame++) {
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(controller.offset, closeTo(parked, 1.0),
          reason: 'a settled scroll must not be re-centred by the list');

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('reports the entry closest to the anchor',
        (WidgetTester tester) async {
      useWatchSurface(tester);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final reported = <int>[];

      await tester.pumpWidget(host(ScalingLazyColumn(
        controller: controller,
        centerFirstAndLastItem: false,
        itemCount: 30,
        onCenterItemChanged: reported.add,
        itemBuilder: (context, index, centerDistance) =>
            SizedBox(height: 40, child: Text('entry $index')),
      )));
      await tester.pump();
      expect(reported, isNotEmpty);

      final first = reported.last;
      controller.jumpTo(400);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(reported.last, greaterThan(first));

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('card, chip and buttons respond to a pointer', () {
    testWidgets('WearCard reports taps and marks selection',
        (WidgetTester tester) async {
      useWatchSurface(tester);
      var taps = 0;
      await tester.pumpWidget(host(ScalingLazyColumn(
        itemCount: 1,
        itemBuilder: (context, index, centerDistance) => WearCard(
          title: '会话列表',
          subtitle: '点击测试',
          leading: const Icon(Icons.list_rounded),
          selected: true,
          onTap: () => taps++,
        ),
      )));
      await tester.pump();

      await tester.tap(find.text('会话列表'));
      await tester.pump();
      expect(taps, 1);

      final material = tester.widget<Material>(
        find.descendant(of: find.byType(WearCard), matching: find.byType(Material)).first,
      );
      expect(material.color, WearTheme.darkScheme().primaryContainer);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('WearChip toggles and keeps a 48dp touch target',
        (WidgetTester tester) async {
      useWatchSurface(tester);
      var selected = 0;
      await tester.pumpWidget(host(Center(
        child: WearChip(
          label: '会话',
          icon: Icons.forum_rounded,
          selected: true,
          onTap: () => selected++,
        ),
      )));
      await tester.pump();

      await tester.tap(find.text('会话'));
      await tester.pump();
      expect(selected, 1);

      final size = tester.getSize(find.byType(WearChip));
      expect(size.height, greaterThanOrEqualTo(WearTokens.chipHeight));
      expect(size.width, greaterThanOrEqualTo(WearTokens.touchTarget));
    });

    testWidgets('WearIconButton is a 48dp circle and stops when disabled',
        (WidgetTester tester) async {
      useWatchSurface(tester);
      var taps = 0;
      await tester.pumpWidget(host(Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            WearIconButton(
              icon: Icons.play_arrow_rounded,
              tooltip: '开始',
              onPressed: () => taps++,
            ),
            WearIconButton(
              icon: Icons.stop_rounded,
              onPressed: null,
            ),
          ],
        ),
      )));
      await tester.pump();

      final size = tester.getSize(find.byType(WearIconButton).first);
      expect(size.width, WearTokens.iconButtonSize);
      expect(size.height, WearTokens.iconButtonSize);

      await tester.tap(find.byIcon(Icons.play_arrow_rounded));
      await tester.pump();
      expect(taps, 1);

      await tester.tap(find.byIcon(Icons.stop_rounded));
      await tester.pump();
      expect(taps, 1, reason: 'a disabled button must not fire');

      expect(find.byType(Tooltip), findsOneWidget);
    });
  });

  group('progress and indicator', () {
    testWidgets('WearCircularProgress paints both modes',
        (WidgetTester tester) async {
      useWatchSurface(tester);
      await tester.pumpWidget(host(const Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            WearCircularProgress(value: 0.5),
            WearCircularProgress(),
          ],
        ),
      )));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(WearCircularProgress), findsNWidgets(2));
      expect(find.byType(CustomPaint), findsWidgets);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('PositionIndicator appears only when the list scrolls',
        (WidgetTester tester) async {
      useWatchSurface(tester);
      final controller = ScrollController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(host(Stack(
        children: <Widget>[
          ScalingLazyColumn(
            controller: controller,
            itemCount: 30,
            itemBuilder: (context, index, centerDistance) =>
                SizedBox(height: 40, child: Text('entry $index')),
          ),
          Positioned.fill(child: PositionIndicator(controller: controller)),
        ],
      )));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(PositionIndicator), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(PositionIndicator),
          matching: find.byType(CustomPaint),
        ),
        findsWidgets,
      );

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('app shell', () {
    testWidgets('boots on a watch sized surface and scrolls without error',
        (WidgetTester tester) async {
      useWatchSurface(tester);
      await tester.pumpWidget(DshRelayApp(settings: SettingsStore()));
      await tester.pump();

      /* The home surface is a four page pager. It lands on the composer, which
       * asks for a session before any has been chosen. Pages carry no title of
       * their own — the dots are the only position cue. */
      expect(find.byType(PageView), findsOneWidget);
      expect(find.byType(WearPageIndicator), findsOneWidget);
      expect(find.byType(TimeText), findsOneWidget);
      expect(find.text('还没有选择会话'), findsOneWidget);
      expect(find.text('首页'), findsNothing);

      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('swiping moves between the four cards',
        (WidgetTester tester) async {
      useWatchSurface(tester);
      await tester.pumpWidget(DshRelayApp(settings: SettingsStore()));
      await tester.pump();

      final indicator = find.byType(WearPageIndicator);
      expect(indicator, findsOneWidget);

      /// Reads the selected dot straight out of the indicator's semantics.
      String atPage() => tester
          .widget<Semantics>(find
              .descendant(of: indicator, matching: find.byType(Semantics))
              .first)
          .properties
          .label!;

      expect(atPage(), contains('首页'));

      await tester.drag(find.byType(PageView), const Offset(-320, 0));
      await tester.pumpAndSettle();
      expect(atPage(), contains('配置'));

      await tester.drag(find.byType(PageView), const Offset(-320, 0));
      await tester.pumpAndSettle();
      expect(atPage(), contains('设置'));
      expect(tester.takeException(), isNull);

      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}
