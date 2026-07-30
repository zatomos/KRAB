import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:krab/l10n/app_localizations.dart';
import 'package:krab/services/instance/krab_instance.dart';
import 'package:krab/widgets/instance_status_footer.dart';

KrabInstance _instance(String id) =>
    KrabInstance(id: id, url: 'https://$id.example', anonKey: 'key');

/// Pumps a footer whose inputs can be swapped, so a load can be resolved
/// part-way through the settle delay.
Future<void> _pumpFooter(
  WidgetTester tester, {
  required List<KrabInstance> pending,
  required List<KrabInstance> unavailable,
}) async {
  await tester.pumpWidget(MaterialApp(
    localizationsDelegates: const [
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    home: Scaffold(
      body: InstanceStatusFooter(
        pending: pending,
        unavailable: unavailable,
        failure: (servers) => 'could not load from $servers',
      ),
    ),
  ));
}

final _almost =
    InstanceStatusFooter.settleDelay - const Duration(milliseconds: 1);
const _past = Duration(milliseconds: 2);

void main() {
  group('InstanceStatusFooter', () {
    testWidgets('says nothing while a load is still within the delay', (tester) async {
      await _pumpFooter(tester, pending: [_instance('a')], unavailable: []);

      await tester.pump(_almost);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('appears once a load outlasts the delay', (tester) async {
      await _pumpFooter(tester, pending: [_instance('a')], unavailable: []);

      await tester.pump(_almost + _past);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
    });

    testWidgets('a load that resolves in time never shows it', (tester) async {
      await _pumpFooter(tester, pending: [_instance('a')], unavailable: []);
      await tester.pump(_almost);

      // Everything answered, and answered usefully.
      await _pumpFooter(tester, pending: [], unavailable: []);
      await tester.pump(InstanceStatusFooter.settleDelay * 2);

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('could not load'), findsNothing);
    });

    testWidgets('a quick failure still waits out the delay, then shows',
        (tester) async {
      await _pumpFooter(tester, pending: [], unavailable: [_instance('a')]);

      await tester.pump(_almost);
      expect(find.textContaining('could not load'), findsNothing);

      await tester.pump(_past);
      expect(find.textContaining('a.example'), findsOneWidget);
    });

    testWidgets('turning from pending to failed keeps it up, without a second '
        'delay', (tester) async {
      await _pumpFooter(tester, pending: [_instance('a')], unavailable: []);
      await tester.pump(_almost + _past);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await _pumpFooter(tester, pending: [], unavailable: [_instance('a')]);
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('could not load'), findsOneWidget);
    });
  });
}
