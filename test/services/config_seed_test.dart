import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:krab/user_preferences.dart';

/// The seeding in initPrefs is the bridge that lets a later blank build not
/// strand existing users: a build that still ships a .env default must persist
/// it to prefs, once, without disturbing a user who already chose an instance.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> init() => UserPreferences().initPrefs();

  test('a .env default is seeded into prefs on first launch', () async {
    SharedPreferences.setMockInitialValues({}); // existing user: no config pref
    dotenv.loadFromString(envString: '''
SUPABASE_URL=https://baked.example
SUPABASE_ANON_KEY=baked-anon
''');

    await init();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('supabaseUrl'), 'https://baked.example',
        reason: 'the .env default should be persisted so a blank build finds it');
    expect(prefs.getString('supabaseAnonKey'), 'baked-anon');
    expect(UserPreferences.hasSupabaseConfig, isTrue);
  });

  test('a user-chosen instance is never overwritten by the .env default',
      () async {
    SharedPreferences.setMockInitialValues({
      'supabaseUrl': 'https://chosen.example',
      'supabaseAnonKey': 'chosen-anon',
    });
    dotenv.loadFromString(envString: '''
SUPABASE_URL=https://baked.example
SUPABASE_ANON_KEY=baked-anon
''');

    await init();

    expect(UserPreferences.supabaseUrl, 'https://chosen.example');
    expect(UserPreferences.supabaseAnonKey, 'chosen-anon');
  });

  test('a blank build with no prefs stays unconfigured (shows connect screen)',
      () async {
    SharedPreferences.setMockInitialValues({});
    dotenv.loadFromString(envString: '# blank'); // no defaults

    await init();

    expect(UserPreferences.hasSupabaseConfig, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('supabaseUrl'), isNull,
        reason: 'nothing to seed, so nothing is written');
  });

  test("empty-quote .env values ('') are treated as empty, not configured",
      () async {
    // flutter_dotenv keeps the quotes on an empty value, so SUPABASE_URL=''
    // arrives as the literal "''". It must not read as a usable instance.
    SharedPreferences.setMockInitialValues({});
    dotenv.loadFromString(envString: "SUPABASE_URL=''\nSUPABASE_ANON_KEY=''");

    await init();

    expect(UserPreferences.supabaseUrl, isEmpty);
    expect(UserPreferences.hasSupabaseConfig, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('supabaseUrl'), isNull,
        reason: 'garbage must not be seeded');
  });

  test("a bad \"''\" already seeded into prefs is recovered", () async {
    // An earlier build seeded the literal "''" before this was fixed; the app
    // must not now consider itself configured.
    SharedPreferences.setMockInitialValues({
      'supabaseUrl': "''",
      'supabaseAnonKey': "''",
    });
    dotenv.loadFromString(envString: '# blank');

    await init();

    expect(UserPreferences.hasSupabaseConfig, isFalse);
  });
}
