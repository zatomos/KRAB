import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:krab/l10n/l10n.dart';
import 'package:krab/pages/viewer/viewer_actions_menu.dart';
import 'package:material_symbols_icons/symbols.dart';

class _Opened {
  ViewerAction? action;
  bool closed = false;
}

Future<_Opened> _openMenu(
  WidgetTester tester, {
  required bool isOwner,
  required bool canModerate,
}) async {
  final opened = _Opened();
  final buttonKey = GlobalKey();

  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            key: buttonKey,
            onPressed: () async {
              opened.action = await showViewerActionsMenu(
                context,
                buttonKey: buttonKey,
                isOwner: isOwner,
                canModerate: canModerate,
              );
              opened.closed = true;
            },
            child: const Text('menu'),
          ),
        ),
      ),
    ),
  ));

  await tester.tap(find.text('menu'));
  await tester.pumpAndSettle();
  return opened;
}

void main() {
  testWidgets('anyone can save, and that is all a stranger can do',
      (tester) async {
    await _openMenu(tester, isOwner: false, canModerate: false);

    expect(find.byIcon(Symbols.download_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.group_add_rounded), findsNothing,
        reason: 'only the owner may reshare their photo');
    expect(find.byIcon(Symbols.delete_rounded), findsNothing,
        reason: 'a stranger may not delete someone else\'s photo');
  });

  testWidgets('the owner can save, reshare and delete', (tester) async {
    await _openMenu(tester, isOwner: true, canModerate: false);

    expect(find.byIcon(Symbols.download_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.group_add_rounded), findsOneWidget);
    expect(find.byIcon(Symbols.delete_rounded), findsOneWidget);
  });

  testWidgets('a moderator can delete, but not reshare someone else\'s photo',
      (tester) async {
    await _openMenu(tester, isOwner: false, canModerate: true);

    expect(find.byIcon(Symbols.delete_rounded), findsOneWidget,
        reason: 'a moderator may remove a photo from the group they moderate');
    expect(find.byIcon(Symbols.group_add_rounded), findsNothing,
        reason: 'moderating a group does not make the photo theirs to spread');
  });

  testWidgets('reports the action that was chosen', (tester) async {
    final opened = await _openMenu(tester, isOwner: true, canModerate: false);

    await tester.tap(find.byIcon(Symbols.delete_rounded));
    await tester.pumpAndSettle();

    expect(opened.closed, isTrue);
    expect(opened.action, ViewerAction.delete);
  });

  testWidgets('dismissing chooses nothing', (tester) async {
    final opened = await _openMenu(tester, isOwner: true, canModerate: false);

    // Tap the barrier, away from the menu.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(opened.closed, isTrue);
    expect(opened.action, isNull);
  });
}
