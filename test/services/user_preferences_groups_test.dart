import 'package:flutter_test/flutter_test.dart';
import 'package:krab/user_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await UserPreferences().initPrefs();
  });

  test('a favourite is remembered per instance', () async {
    await UserPreferences.addFavoriteGroup('inst_1', 'g1');

    expect(await UserPreferences.isGroupFavorite('inst_1', 'g1'), isTrue);
    expect(await UserPreferences.isGroupFavorite('inst_2', 'g1'), isFalse,
        reason: 'the same group id on another server is a different group');
  });

  test('favouritesOn returns bare ids the picker can match', () async {
    await UserPreferences.addFavoriteGroup('inst_1', 'g1');
    await UserPreferences.addFavoriteGroup('inst_2', 'g2');

    expect(await UserPreferences.favoriteGroupsOn('inst_1'), ['g1'],
        reason: 'the send dialog compares these against this instance\'s '
            'group ids, so they must not carry the instance prefix');
  });

  test('muting is per instance too', () async {
    await UserPreferences.setGroupMuted('inst_1', 'g1', true);

    expect(await UserPreferences.isGroupMuted('inst_1', 'g1'), isTrue);
    expect(await UserPreferences.isGroupMuted('inst_2', 'g1'), isFalse);
  });
}
