import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:krab/l10n/app_localizations.dart';
import 'package:krab/widgets/dialogs/edit_avatar_dialog.dart';

/// Holds what the chooser resolved to, once it closes.
class _Result {
  AvatarAction? action;
  bool closed = false;
}

/// Opens the avatar chooser over a bare app and returns a handle on its result.
Future<_Result> _openChooser(WidgetTester tester,
    {required bool hasImage}) async {
  final result = _Result();

  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          result.action = await showEditAvatarDialog(
            context,
            title: 'Avatar',
            hasImage: hasImage,
          );
          result.closed = true;
        },
        child: const Text('open'),
      ),
    ),
  ));

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  expect(find.byType(AlertDialog), findsOneWidget);
  return result;
}

void main() {
  testWidgets('with no image yet, offers to add one and cannot delete',
      (tester) async {
    await _openChooser(tester, hasImage: false);

    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.byIcon(Icons.delete_forever), findsNothing,
        reason: 'there is nothing to delete');
  });

  testWidgets('with an image, offers to replace or delete it', (tester) async {
    await _openChooser(tester, hasImage: true);

    expect(find.byIcon(Icons.edit), findsOneWidget);
    expect(find.byIcon(Icons.delete_forever), findsOneWidget);
    expect(find.byIcon(Icons.add), findsNothing);
  });

  testWidgets('choosing delete reports delete', (tester) async {
    final result = await _openChooser(tester, hasImage: true);

    await tester.tap(find.byIcon(Icons.delete_forever));
    await tester.pumpAndSettle();

    expect(result.closed, isTrue);
    expect(result.action, AvatarAction.delete);
  });

  testWidgets('choosing edit reports edit', (tester) async {
    final result = await _openChooser(tester, hasImage: true);

    await tester.tap(find.byIcon(Icons.edit));
    await tester.pumpAndSettle();

    expect(result.closed, isTrue);
    expect(result.action, AvatarAction.edit);
  });

  testWidgets('cancelling reports nothing, so the caller leaves it alone',
      (tester) async {
    final result = await _openChooser(tester, hasImage: true);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(result.closed, isTrue);
    expect(result.action, isNull);
  });
}
