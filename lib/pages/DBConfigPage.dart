import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/services/fcm_helper.dart';
import 'package:krab/themes/GlobalThemeData.dart';
import 'package:krab/widgets/FloatingSnackBar.dart';
import 'package:krab/widgets/RoundedInputField.dart';
import 'package:krab/UserPreferences.dart';
import 'LoginPage.dart';

class DBConfigPage extends StatefulWidget {
  const DBConfigPage({super.key});

  @override
  State<DBConfigPage> createState() => _DBConfigPageState();
}

class _DBConfigPageState extends State<DBConfigPage> {
  bool isSupabaseInitialized = false;
  final _supabaseUrlController = TextEditingController();
  final _supabaseAnonKeyController = TextEditingController();

  Future<void> initializeSupabase(String url, String anon) async {
    if (isSupabaseInitialized) return;
    bool ok = false;

    try {
      await Supabase.initialize(url: url, anonKey: anon);
      ok = true;
      isSupabaseInitialized = true;
      await UserPreferences.setSupabaseConfig(url, anon);

      // Check if we can reach the Supabase API
      final client = Supabase.instance.client;
      final healthCheck = await client.from('Users').select('id').limit(1);

      debugPrint('Supabase connection verified: ${healthCheck.runtimeType}');
      showSnackBar(context, context.l10n.supabase_connection_success,
          color: Colors.green);

      // Initialize FCM and sync token
      await FcmHelper.initializeAndSyncToken();

    } catch (e) {
      ok = false;
      isSupabaseInitialized = false;
      await UserPreferences.setSupabaseConfig('', '');
      showSnackBar(context, context.l10n.supabase_connection_error,
          color: Colors.red);
      debugPrint('Supabase connection failed: $e');
    }

    await Future.delayed(const Duration(seconds: 1));

    if (!mounted) return;
    if (ok) {
      Navigator.pushReplacement(
          context, MaterialPageRoute(builder: (_) => const LoginPage()));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(body: LayoutBuilder(builder: (context, constraints) {
      return SingleChildScrollView(
          child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight,
              ),
              child: IntrinsicHeight(
                child: Padding(
                  padding: const EdgeInsets.all(20.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(Icons.storage,
                          size: 80,
                          color: GlobalThemeData.darkColorScheme.secondary),
                      const SizedBox(height: 20),
                      Text(
                        context.l10n.supabase_title,
                        style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                            color: GlobalThemeData.darkColorScheme.primary),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 15),
                      Text(
                        context.l10n.supabase_subtitle,
                        style: const TextStyle(fontSize: 18),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 30),
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          borderRadius:
                              const BorderRadius.all(Radius.circular(20)),
                          border: Border.all(
                            color: GlobalThemeData.darkColorScheme.primary,
                            width: 1,
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            RoundedInputField(
                              controller: _supabaseUrlController,
                              hintText: context.l10n.supabase_url,
                              icon: const Icon(Icons.link),
                            ),
                            RoundedInputField(
                              controller: _supabaseAnonKeyController,
                              hintText: context.l10n.supabase_key,
                              icon: const Icon(Icons.vpn_key),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 30),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.cloud_done_rounded),
                        label: Text(context.l10n.connect,
                            style: const TextStyle(fontSize: 18)),
                        style: ElevatedButton.styleFrom(
                          backgroundColor:
                              GlobalThemeData.darkColorScheme.surfaceBright,
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 12),
                        ),
                        onPressed: () => initializeSupabase(
                          _supabaseUrlController.text.trim(),
                          _supabaseAnonKeyController.text.trim(),
                        ),
                      ),
                    ],
                  ),
                ),
              )));
    }));
  }
}
