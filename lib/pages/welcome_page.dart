import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:krab/l10n/l10n.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/user_preferences.dart';
import 'package:krab/pages/login_page.dart';
import 'package:krab/widgets/soft_button.dart';
import 'package:krab/services/home_widget_status.dart';

class WelcomePage extends StatefulWidget {
  const WelcomePage({super.key});

  @override
  State<WelcomePage> createState() => _WelcomePageState();
}

class _WelcomePageState extends State<WelcomePage> {
  bool _hasWidget = false;
  bool? _permissionGranted;

  @override
  void initState() {
    super.initState();
    debugPrint("🏠 WelcomePage.initState()");
    _initializeState();

    // Trust the callback - set widget as installed when callback fires
    HomeWidgetStatus.instance.setWidgetInstalledListener(() {
      debugPrint("🎯 Widget installed callback fired!");
      debugPrint("🎯 mounted: $mounted");
      debugPrint("🎯 Current _hasWidget: $_hasWidget");

      if (!mounted) {
        debugPrint("🎯 Not mounted, skipping setState");
        return;
      }

      debugPrint("🎯 Calling setState to set _hasWidget = true");
      setState(() => _hasWidget = true);
      debugPrint("🎯 setState completed, _hasWidget now: $_hasWidget");
    });

    debugPrint("🏠 Listener registered");
  }

  Future<void> _initializeState() async {
    final perm = await Permission.ignoreBatteryOptimizations.isGranted;
    final widgetInstalled = await HomeWidgetStatus.instance.hasKrabWidget();

    if (!mounted) return;
    setState(() {
      _permissionGranted = perm;
      _hasWidget = widgetInstalled;
    });
  }

  Future<void> _continue(BuildContext context) async {
    await UserPreferences.notFirstLaunch();
    if (!context.mounted) return;

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const LoginPage()),
    );
  }

  Future<void> _requestBackgroundPermission() async {
    if (await Permission.ignoreBatteryOptimizations.isPermanentlyDenied) {
      await openAppSettings();
    } else {
      await Permission.ignoreBatteryOptimizations.request();
    }

    _initializeState();
  }

  @override
  Widget build(BuildContext context) {
    final permissionGranted = _permissionGranted ?? false;

    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Image.asset(
              'logo/krab_logo.png',
              width: 100,
              height: 100,
            ),
            const SizedBox(height: 20),
            Text(
              context.l10n.welcome_title,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: GlobalThemeData.darkColorScheme.primary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 15),
            Text(
              context.l10n.welcome_subtitle,
              style: const TextStyle(fontSize: 18),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 30),
            _buildSettingsCard(context, permissionGranted),
            const SizedBox(height: 30),
            SoftButton(
              icon: Icons.check_rounded,
              label: context.l10n.go_button,
              color: GlobalThemeData.darkColorScheme.primary,
              onPressed: () => _continue(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSettingsCard(BuildContext context, bool permissionGranted) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.all(Radius.circular(20)),
        border: Border.all(
          color: GlobalThemeData.darkColorScheme.primary,
          width: 1,
        ),
      ),
      child: Column(
        children: [
          Text(
            context.l10n.background_widget_description,
            style: const TextStyle(fontSize: 18),
            textAlign: TextAlign.left,
          ),
          const SizedBox(height: 15),

          // Battery permission button
          SoftButton(
            icon:
                permissionGranted ? Icons.check_circle : Icons.warning_rounded,
            label: context.l10n.background_widget_allow,
            color: permissionGranted ? Colors.green : Colors.red,
            onPressed: _requestBackgroundPermission,
          ),

          const SizedBox(height: 10),

          // Add widget button
          SoftButton(
            onPressed: () {
              HomeWidgetStatus.instance.pickWidgetConfig(context);
            },
            label: context.l10n.add_krab_widget,
            icon: _hasWidget ? Icons.check_circle : Icons.add_box,
            color: _hasWidget
                ? Colors.green
                : GlobalThemeData.darkColorScheme.primary,
          ),
        ],
      ),
    );
  }
}
