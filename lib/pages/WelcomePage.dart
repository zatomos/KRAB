import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/themes/GlobalThemeData.dart';
import 'package:krab/UserPreferences.dart';
import 'package:krab/pages/DBConfigPage.dart';

class WelcomePage extends StatefulWidget {
  const WelcomePage({super.key});

  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> {
  bool? _permissionGranted; // null = loading/unknown

  @override
  void initState() {
    super.initState();
    _checkBackgroundPermission();
  }

  Future<void> _checkBackgroundPermission() async {
    final granted = await Permission.ignoreBatteryOptimizations.isGranted;
    setState(() {
      _permissionGranted = granted;
    });
  }

  Future<void> _continue(BuildContext context) async {
    await UserPreferences.notFirstLaunch();
    debugPrint(UserPreferences.isFirstLaunch.toString());
    if (!mounted) return;
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const DBConfigPage()),
    );
  }

  // ask for permission to run in the background
  Future<void> _requestBackgroundPermission() async {
    // If permanently denied, open settings
    if (await Permission.ignoreBatteryOptimizations.isPermanentlyDenied) {
      await openAppSettings();
    } else if (await Permission.ignoreBatteryOptimizations.isDenied) {
      await Permission.ignoreBatteryOptimizations.request();
    }
    // Re-check
    await _checkBackgroundPermission();
  }

  @override
  Widget build(BuildContext context) {
    final permissionGranted = _permissionGranted ?? false;

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(Icons.widgets,
                size: 80, color: GlobalThemeData.darkColorScheme.secondary),
            const SizedBox(height: 20),
            Text(
              context.l10n.welcome_title,
              style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: GlobalThemeData.darkColorScheme.primary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 15),
            Text(
              context.l10n.welcome_subtitle,
              style: const TextStyle(fontSize: 18),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 30),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                borderRadius: const BorderRadius.all(Radius.circular(20)),
                border: Border.all(
                  color: GlobalThemeData.darkColorScheme.primary,
                  width: 1,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    context.l10n.background_widget_description,
                    style: const TextStyle(fontSize: 18),
                    textAlign: TextAlign.left,
                  ),
                  const SizedBox(height: 15),
                  ElevatedButton.icon(
                    icon: Icon(
                      permissionGranted ? Icons.check : Icons.warning,
                      color: permissionGranted ? Colors.green : Colors.red,
                    ),
                    label: Text(
                      context.l10n.background_widget_allow,
                      style: const TextStyle(fontSize: 18),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          GlobalThemeData.darkColorScheme.surfaceBright,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 12),
                    ),
                    onPressed: _requestBackgroundPermission,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 30),
            ElevatedButton.icon(
              icon: const Icon(Icons.check),
              label: Text(context.l10n.go_button,
                  style: const TextStyle(fontSize: 18)),
              style: ElevatedButton.styleFrom(
                backgroundColor: GlobalThemeData.darkColorScheme.surfaceBright,
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              ),
              onPressed: () => _continue(context),
            ),
          ],
        ),
      ),
    );
  }
}
