import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:krab/app_globals.dart';
import 'package:krab/widgets/floating_snack_bar.dart';

/// Mounts a messenger the global helper can post to, on a screen of the given
/// width.
Future<void> _pumpMessenger(WidgetTester tester, {double width = 360}) async {
  tester.view.physicalSize = Size(width, 640);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MaterialApp(
    scaffoldMessengerKey: scaffoldMessengerKey,
    home: const Scaffold(body: SizedBox.shrink()),
  ));
}

/// The pair the photo-sent snackbar shows: one filled, one plain.
List<SnackAction> _viewAndUndo() => [
      SnackAction(label: 'View', onPressed: () {}, prominent: true),
      SnackAction(label: 'Undo', onPressed: () {}),
    ];

/// Let a snackbar time out, so its close timer isn't left pending.
Future<void> _waitOut(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 5));
  await tester.pumpAndSettle();
}

void main() {
  group('showSnackBar', () {
    testWidgets('one action uses the built-in action slot', (tester) async {
      await _pumpMessenger(tester);

      var tapped = false;
      showSnackBar('Photo sent', actions: [
        SnackAction(label: 'Undo', onPressed: () => tapped = true),
      ]);
      await tester.pumpAndSettle();

      expect(find.byType(SnackBarAction), findsOneWidget);

      await tester.tap(find.text('Undo'));
      expect(tapped, isTrue);
      await _waitOut(tester);
    });

    testWidgets('several actions all show and are tappable', (tester) async {
      await _pumpMessenger(tester);

      var viewed = false;
      var undone = false;
      showSnackBar('Photo sent', actions: [
        SnackAction(label: 'View', onPressed: () => viewed = true),
        SnackAction(label: 'Undo', onPressed: () => undone = true),
      ]);
      await tester.pumpAndSettle();

      expect(find.text('View'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);

      await tester.tap(find.text('View'));
      await tester.pump();
      expect(viewed, isTrue);
      expect(undone, isFalse);
      // Tapping an action closes the snackbar.
      await tester.pumpAndSettle();
      expect(find.text('Photo sent'), findsNothing);
    });

    testWidgets('a prominent action is filled, the others are plain',
        (tester) async {
      await _pumpMessenger(tester);

      showSnackBar('Photo sent', actions: _viewAndUndo());
      await tester.pumpAndSettle();

      Color? fillOf(String label) => tester
          .widget<TextButton>(find.ancestor(
            of: find.text(label),
            matching: find.byType(TextButton),
          ))
          .style
          ?.backgroundColor
          ?.resolve({});

      expect(fillOf('View'), Colors.white);
      expect(fillOf('Undo'), isNull);
      await _waitOut(tester);
    });

    testWidgets('a one-line message stays as tall as a plain snackbar',
        (tester) async {
      await _pumpMessenger(tester);

      showSnackBar('Sent');
      await tester.pumpAndSettle();
      final plain = tester.getSize(find.byType(SnackBar)).height;
      await _waitOut(tester);

      showSnackBar('Sent', actions: _viewAndUndo());
      await tester.pumpAndSettle();

      expect(tester.getSize(find.byType(SnackBar)).height, plain);
      await _waitOut(tester);
    });

    testWidgets('a long message on a narrow screen stays readable',
        (tester) async {
      const width = 240.0;
      await _pumpMessenger(tester, width: width);

      const message =
          'Photo sent, but server-alpha, server-beta and server-gamma refused it';
      showSnackBar(message, actions: _viewAndUndo());
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);

      // The buttons don't run off the edge
      for (final label in ['View', 'Undo']) {
        final rect = tester.getRect(find.text(label));
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(width));
      }
      // and they don't squeeze the message into a column of single letters
      // either.
      expect(tester.getSize(find.text(message)).width,
          greaterThan(width * 0.25));
      await _waitOut(tester);
    });
  });
}
