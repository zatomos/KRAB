import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:krab/themes/GlobalThemeData.dart';
import 'package:krab/UserPreferences.dart';
import 'LoginPage.dart';

class WelcomePage extends StatelessWidget {
  const WelcomePage({super.key});

  Future<void> _continue(BuildContext context) async {
    await UserPreferences.notFirstLaunch();
    debugPrint(UserPreferences.isFirstLaunch.toString());
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => const LoginPage()),
    );
  }

  // ask for permission to run in the background
  Future<void> _requestBackgroundPermission() async {
    if (await Permission.ignoreBatteryOptimizations.isPermanentlyDenied) {
      await openAppSettings();
    }
    if (await Permission.ignoreBatteryOptimizations.isDenied) {
      await Permission.ignoreBatteryOptimizations.request();
    }
  }

  @override
  Widget build(BuildContext context) {
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
              "Welcome to KRAB!",
              style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.bold,
                  color: GlobalThemeData.darkColorScheme.primary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 15),
            const Text(
              "To stay connected, add our widget to your home screen.",
              style: TextStyle(fontSize: 18),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 30),
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.all(Radius.circular(20)),
                border: Border.all(
                  color: GlobalThemeData.darkColorScheme.primary,
                  width: 1,
                ),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children:[
                  const Text(
                    "To ensure that the widget updates properly, it is recommended to allow the app to run in the background.",
                    style: TextStyle(fontSize: 18),
                    textAlign: TextAlign.left,
                  ),
                  const SizedBox(height: 15),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.battery_5_bar_rounded),
                    label: const Text("Allow background activity",
                        style: TextStyle(fontSize: 18)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: GlobalThemeData.darkColorScheme.surfaceBright,
                      padding:
                      const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                    ),
                    onPressed: () => _requestBackgroundPermission(),
                  ),
                ]
                ),
              ),

            const SizedBox(height: 30),
            ElevatedButton.icon(
              icon: const Icon(Icons.check),
              label:
                  const Text("Let's go!", style: TextStyle(fontSize: 18)),
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
