import 'package:flutter_test/flutter_test.dart';
import 'package:krab/services/update_service.dart';

/// The update check picks the newest release by this comparison, so getting it
/// wrong either offers a downgrade or never offers an update at all.
void main() {
  final service = UpdateService();

  int cmp(String a, String b) => service.compareVersions(a, b);

  test('orders release numbers', () {
    expect(cmp('1.0.0', '1.0.1'), lessThan(0));
    expect(cmp('1.0.1', '1.0.0'), greaterThan(0));
    expect(cmp('1.2.0', '1.10.0'), lessThan(0),
        reason: '10 is a bigger minor than 2, not a smaller string');
    expect(cmp('2.0.0', '1.9.9'), greaterThan(0));
  });

  test('equal versions compare equal', () {
    expect(cmp('1.2.3', '1.2.3'), 0);
  });

  test('a missing component counts as zero', () {
    expect(cmp('1.2', '1.2.0'), 0);
    expect(cmp('1', '1.0.1'), lessThan(0));
  });

  test('a prerelease is older than the release it leads to', () {
    expect(cmp('1.0.0-beta', '1.0.0'), lessThan(0));
    expect(cmp('1.0.0-rc', '1.0.0'), lessThan(0));
    expect(cmp('1.0.0', '1.0.0-rc'), greaterThan(0));
  });

  test('prerelease stages are ordered', () {
    expect(cmp('1.0.0-alpha', '1.0.0-beta'), lessThan(0));
    expect(cmp('1.0.0-beta', '1.0.0-rc'), lessThan(0));
    expect(cmp('1.0.0-debug', '1.0.0-alpha'), lessThan(0));
  });

  test('numbers within a stage are ordered', () {
    expect(cmp('1.0.0-beta.1', '1.0.0-beta.2'), lessThan(0));
    expect(cmp('1.0.0-beta.10', '1.0.0-beta.2'), greaterThan(0));
  });

  test('release numbers outrank the stage', () {
    // A stable 1.0.0 is still older than a beta of 1.1.0.
    expect(cmp('1.0.0', '1.1.0-beta'), lessThan(0));
  });

  test('sorting a list puts the newest last, which is what the check installs',
      () {
    final versions = [
      '1.0.0',
      '1.0.0-beta.2',
      '0.9.9',
      '1.1.0',
      '1.0.0-rc.1',
      '1.0.1',
    ]..sort(cmp);

    expect(versions, [
      '0.9.9',
      '1.0.0-beta.2',
      '1.0.0-rc.1',
      '1.0.0',
      '1.0.1',
      '1.1.0',
    ]);
  });
}
