import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:krab/l10n/l10n.dart';
import 'package:krab/services/time_formatting.dart';

/// Creates a minimal localized widget tree and hands back a BuildContext whose
/// l10n resolves to the English strings.
Future<BuildContext> _localizedContext(WidgetTester tester) async {
  late BuildContext captured;
  await tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) {
          captured = context;
          return const SizedBox();
        },
      ),
    ),
  );
  return captured;
}

DateTime _ago(Duration d) => DateTime.now().subtract(d);

void main() {
  group('timeAgoShort', () {
    testWidgets('under a minute reads "Just now"', (tester) async {
      final ctx = await _localizedContext(tester);
      expect(timeAgoShort(ctx, _ago(const Duration(seconds: 30))), 'Just now');
    });

    testWidgets('minutes band', (tester) async {
      final ctx = await _localizedContext(tester);
      expect(timeAgoShort(ctx, _ago(const Duration(minutes: 1))), '1m');
      expect(timeAgoShort(ctx, _ago(const Duration(minutes: 59))), '59m');
    });

    testWidgets('crosses from minutes to hours after 60 min', (tester) async {
      final ctx = await _localizedContext(tester);
      expect(timeAgoShort(ctx, _ago(const Duration(minutes: 61))), '1h');
    });

    testWidgets('hours band up to its edge', (tester) async {
      final ctx = await _localizedContext(tester);
      expect(timeAgoShort(ctx, _ago(const Duration(hours: 23))), '23h');
    });

    testWidgets('crosses from hours to days after 24 h', (tester) async {
      final ctx = await _localizedContext(tester);
      expect(timeAgoShort(ctx, _ago(const Duration(hours: 25))), '1d');
    });

    testWidgets('days band up to its edge', (tester) async {
      final ctx = await _localizedContext(tester);
      expect(timeAgoShort(ctx, _ago(const Duration(days: 6))), '6d');
    });

    testWidgets('crosses from days to weeks at 7 days', (tester) async {
      final ctx = await _localizedContext(tester);
      // 7 days -> floor(7 / 7) == 1 week.
      expect(timeAgoShort(ctx, _ago(const Duration(days: 7))), '1w');
    });

    testWidgets('weeks band floors the division', (tester) async {
      final ctx = await _localizedContext(tester);
      // 20 days -> floor(20 / 7) == 2 weeks.
      expect(timeAgoShort(ctx, _ago(const Duration(days: 20))), '2w');
      // 29 days is still under the 30-day month cutoff -> floor(29/7) == 4.
      expect(timeAgoShort(ctx, _ago(const Duration(days: 29))), '4w');
    });

    testWidgets('crosses from weeks to months at 30 days', (tester) async {
      final ctx = await _localizedContext(tester);
      // 30 days -> floor(30 / 30) == 1 month.
      expect(timeAgoShort(ctx, _ago(const Duration(days: 30))), '1mo');
      // 70 days -> floor(70 / 30) == 2 months.
      expect(timeAgoShort(ctx, _ago(const Duration(days: 70))), '2mo');
    });
  });

  group('timeAgoLong', () {
    testWidgets('keeps "Just now" un-suffixed', (tester) async {
      final ctx = await _localizedContext(tester);
      expect(timeAgoLong(ctx, _ago(const Duration(seconds: 30))), 'Just now');
    });

    testWidgets('suffixes every other band with " ago"', (tester) async {
      final ctx = await _localizedContext(tester);
      expect(timeAgoLong(ctx, _ago(const Duration(minutes: 5))), '5m ago');
      expect(timeAgoLong(ctx, _ago(const Duration(hours: 3))), '3h ago');
      expect(timeAgoLong(ctx, _ago(const Duration(days: 2))), '2d ago');
      expect(timeAgoLong(ctx, _ago(const Duration(days: 20))), '2w ago');
      expect(timeAgoLong(ctx, _ago(const Duration(days: 70))), '2mo ago');
    });
  });
}
