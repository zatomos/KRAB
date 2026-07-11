import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:krab/app_globals.dart';
import 'package:krab/firebase_options.dart';
import 'package:krab/services/auth/app_auth.dart';
import 'package:krab/services/debug_notifier.dart';
import 'package:krab/user_preferences.dart';

Completer<bool>? _supabaseInitCompleter;

Future<bool> initializeSupabaseIfNeeded() async {
  // Already initialized
  if (isSupabaseInitialized) return true;

  // Another call is in progress - wait for it
  if (_supabaseInitCompleter != null) {
    debugPrint('Supabase init already in progress, waiting...');
    return _supabaseInitCompleter!.future;
  }

  // Start initialization with lock
  _supabaseInitCompleter = Completer<bool>();

  final url = dotenv.env['SUPABASE_URL'] ?? '';
  final anon = dotenv.env['SUPABASE_ANON_KEY'] ?? '';

  if (url.isEmpty || anon.isEmpty) {
    debugPrint('Supabase config missing, cannot initialize.');
    _supabaseInitCompleter!.complete(false);
    _supabaseInitCompleter = null;
    return false;
  }

  try {
    // Load the shared session before init so the accessToken hook can serve it.
    await AppAuth.instance.load();
    await Supabase.initialize(
      url: url,
      anonKey: anon,
      // Third-party-auth mode: supabase_flutter holds no session; every request
      // asks AppAuth for a valid token.
      accessToken: AppAuth.instance.getValidToken,
    );
    isSupabaseInitialized = true;
    debugPrint('Supabase initialized successfully');
    _supabaseInitCompleter!.complete(true);
    return true;
  } catch (e) {
    debugPrint('Supabase init failed: $e');
    isSupabaseInitialized = false;
    _supabaseInitCompleter!.complete(false);
    _supabaseInitCompleter = null;
    return false;
  }
}

/// Initialize Supabase for a background isolate against the single shared
/// session owned by [AppAuth].
Future<bool> initializeBackgroundSupabase() async {
  if (isSupabaseInitialized) return true;

  final url = UserPreferences.supabaseUrl;
  final anon = UserPreferences.supabaseAnonKey;

  if (url.isEmpty || anon.isEmpty) {
    debugPrint('Background Supabase config missing, cannot initialize.');
    return false;
  }

  try {
    await AppAuth.instance.load();
    await Supabase.initialize(
      url: url,
      anonKey: anon,
      accessToken: AppAuth.instance.getValidToken,
    );
    isSupabaseInitialized = true;
    debugPrint('Background Supabase initialized (shared session)');
    return true;
  } catch (e) {
    debugPrint('Background Supabase init failed: $e');
    isSupabaseInitialized = false;
    return false;
  }
}

/// Common boot sequence for background isolates.
Future<void> bootstrapBackgroundIsolate() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await UserPreferences().initPrefs();
  await DebugNotifier.instance.initialize();
}
