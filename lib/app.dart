import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:krab/app_globals.dart';
import 'package:krab/services/instance/instances.dart';
import 'package:krab/services/instance/instance_registry.dart';
import 'package:krab/services/home_widget_status.dart';
import 'package:krab/services/home_widget_updater.dart';
import 'package:krab/services/launch_router.dart';
import 'package:krab/services/upload_outbox.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/update_checker.dart';
import 'package:krab/l10n/l10n.dart';
import 'package:krab/pages/instance_setup_page.dart';
import 'package:krab/pages/welcome_page.dart';
import 'package:krab/pages/servers_page.dart';
import 'package:krab/pages/camera_page.dart';
import 'package:krab/user_preferences.dart';

class MyApp extends StatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;

  const MyApp({super.key, required this.navigatorKey});

  @override
  MyAppState createState() => MyAppState();
}

class MyAppState extends State<MyApp> with WidgetsBindingObserver {
  DateTime? _lastWidgetRefresh;
  // Decided once at startup. Recomputing per rebuild would re-show the loading
  // spinner and could reset the navigation stack.
  late final Future<Widget> _homePageFuture = _determineHomePage();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // The navigator is mounted now; wake any handler waiting on a cold-start
      // tap. Guarded so a hot restart's second first-frame doesn't re-complete.
      if (!navigatorReady.isCompleted && navigatorKey.currentState != null) {
        navigatorReady.complete(navigatorKey.currentState!);
      }

      // Handle pending local notification (app launched from local notification
      // tap)
      if (pendingLocalNotificationPayload != null) {
        debugPrint('Processing pending local notification');
        await handleLocalNotificationTap(pendingLocalNotificationPayload!);
        pendingLocalNotificationPayload = null;
      }

      // Handle pending widget tap
      if (pendingWidgetUri != null) {
        debugPrint('Processing pending widget launch');
        await handleWidgetLaunch(pendingWidgetUri);
        pendingWidgetUri = null;
      }

      // Show widget prompt if not first launch
      if (!UserPreferences.isFirstLaunch &&
          navigatorKey.currentContext != null) {
        HomeWidgetStatus.instance
            .showWidgetPromptIfNeeded(navigatorKey.currentContext!);
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (!hasInstance) return;

    // Warm the token of every connected instance, so the first post-resume
    // request doesn't have to wait on a refresh. On-demand refresh still
    // covers everything else via the accessToken hook.
    for (final instance in InstanceRegistry.instance.all) {
      instance.auth.getValidToken();
    }

    // Coming back to the app is the most likely moment for a connection to have
    // returned, so try the photos that were queued without one.
    UploadOutbox.instance.flush();

    // Tapping a widget that says "signed out" lands here
    unawaited(refreshWidgetAuthState());

    final now = DateTime.now();
    final canRefresh = _lastWidgetRefresh == null ||
        now.difference(_lastWidgetRefresh!) >= const Duration(minutes: 5);

    if (canRefresh) {
      _lastWidgetRefresh = now;
      updateHomeWidget();
    }
  }

  @override
  Widget build(BuildContext context) {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

    debugPrint('Building MyApp - isAppInitialized: $isAppInitialized');

    return ValueListenableBuilder<ThemeMode>(
      valueListenable: UserPreferences.themeMode,
      builder: (context, themeMode, _) => MaterialApp(
        navigatorKey: widget.navigatorKey,
        navigatorObservers: [routeObserver],
        scaffoldMessengerKey: scaffoldMessengerKey,
        title: 'KRAB',
        theme: GlobalThemeData.light,
        darkTheme: GlobalThemeData.dark,
        themeMode: themeMode,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
          value: systemBarsFor(Theme.of(context).brightness),
          child: SafeArea(top: false, child: child!),
        ),
        home: FutureBuilder(
          future: _homePageFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Scaffold(
                body: Center(child: CircularProgressIndicator()),
              );
            }

            return UpdateChecker(
              child: snapshot.data ?? signInScreen(),
            );
          },
        ),
      ),
    );
  }

  Future<Widget> _determineHomePage() async {
    try {
      if (!isAppInitialized) {
        debugPrint('Waiting for app initialization...');
        await Future.delayed(const Duration(milliseconds: 500));
      }

      if (UserPreferences.isFirstLaunch) {
        return const WelcomePage();
      }

      // Nothing works until we know which instance to talk to
      if (!hasInstance) {
        return const InstanceSetupPage();
      }

      return anySignedIn ? const CameraPage() : signInScreen();
    } catch (e, st) {
      debugPrint('Error determining home page: $e');
      debugPrint(st.toString());
      return signInScreen();
    }
  }
}
