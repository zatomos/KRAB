import 'firebase_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:krab/services/supabase.dart';
import 'package:krab/services/fcm_helper.dart';
import 'package:krab/services/home_widget_updater.dart';
import 'package:krab/services/home_widget_status.dart';
import 'package:krab/services/profile_picture_cache.dart';
import 'package:krab/pages/WelcomePage.dart';
import 'package:krab/pages/LoginPage.dart';
import 'package:krab/pages/CameraPage.dart';
import 'package:krab/pages/GroupImagesPage.dart';
import 'package:krab/themes/GlobalThemeData.dart';
import 'package:krab/widgets/FloatingSnackBar.dart';
import 'package:krab/widgets/UpdateChecker.dart';
import 'package:krab/l10n/l10n.dart';
import 'UserPreferences.dart';

bool isSupabaseInitialized = false;
bool isAppInitialized = false;

final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

RemoteMessage? pendingNotificationMessage;

Future<int> _getWidgetBitmapLimitBytes() async {
  final views = WidgetsBinding.instance.platformDispatcher.views;
  if (views.isEmpty) {
    debugPrint('Failed to get screen size, using default 10 MB limit.');
    return 10 * 1024 * 1024;
  }

  final view = views.first;
  final mq = MediaQueryData.fromView(view);
  final width = mq.size.width * mq.devicePixelRatio;
  final height = mq.size.height * mq.devicePixelRatio;
  final bytes = (width * height * 4 * 1.5).round();

  debugPrint(
    'Computed widget bitmap limit: ${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB '
    '(${width.round()}×${height.round()})',
  );

  return bytes;
}

Future<bool> initializeSupabaseIfNeeded() async {
  if (isSupabaseInitialized) return true;

  final url = dotenv.env['SUPABASE_URL'] ?? '';
  final anon = dotenv.env['SUPABASE_ANON_KEY'] ?? '';

  if (url.isEmpty || anon.isEmpty) {
    debugPrint('Supabase config missing, cannot initialize.');
    return false;
  }

  try {
    await Supabase.initialize(url: url, anonKey: anon);
    isSupabaseInitialized = true;
    debugPrint('Supabase initialized successfully');
    return true;
  } catch (e) {
    debugPrint('Supabase init failed: $e');
    isSupabaseInitialized = false;
    return false;
  }
}

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('Handling background message: ${message.messageId}');
  debugPrint('Background data: ${message.data}');

  if (message.data['type'] != 'new_image') {
    debugPrint('Background message is not about a new image, skipping');
    return;
  }

  try {
    WidgetsFlutterBinding.ensureInitialized();

    await dotenv.load(fileName: ".env");

    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    await UserPreferences().initPrefs();
    final supabaseOk = await initializeSupabaseIfNeeded();
    if (!supabaseOk) {
      debugPrint(
          'Skipping widget update, Supabase not initialized (background)');
      return;
    }

    await updateHomeWidget();

    debugPrint('Background message processed successfully');
  } catch (e, st) {
    debugPrint('Error in background handler: $e');
    debugPrint(st.toString());
  }
}

Future<void> handleNotificationNavigation(RemoteMessage message) async {
  debugPrint('Processing notification navigation: ${message.messageId}');
  debugPrint('Notification data: ${message.data}');

  if (!isSupabaseInitialized) {
    debugPrint('Supabase not initialized → skipping navigation');
    return;
  }

  try {
    final data = message.data;
    final imageId = data['image_id'] ?? '';
    final groupId = data['group_id'] ?? '';

    if (groupId.isEmpty) {
      debugPrint('Group ID is empty, aborting navigation');
      return;
    }

    final groupResponse = await getGroupDetails(groupId);
    if (!groupResponse.success) {
      debugPrint('Error fetching group: ${groupResponse.error}');
      return;
    }

    final group = groupResponse.data;
    if (group == null) {
      debugPrint('Group is null, aborting navigation');
      return;
    }

    int attempts = 0;
    while (navigatorKey.currentState == null && attempts < 20) {
      await Future.delayed(const Duration(milliseconds: 100));
      attempts++;
    }

    if (navigatorKey.currentState == null) {
      debugPrint('Navigator still not ready, aborting navigation');
      return;
    }

    debugPrint('Navigating to GroupImagesPage');
    navigatorKey.currentState!.push(
      MaterialPageRoute(
        builder: (_) => GroupImagesPage(group: group, imageId: imageId),
      ),
    );
  } catch (e, st) {
    debugPrint('Error handling notification navigation: $e');
    debugPrint(st.toString());
  }
}

void main() async {
  try {
    WidgetsFlutterBinding.ensureInitialized();

    // dotenv
    await dotenv.load(fileName: ".env");

    // Firebase
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    // Shared Preferences
    await UserPreferences().initPrefs();

    // Compute and store widget bitmap limit
    final cachedWidgetLimit = await UserPreferences.getWidgetBitmapLimit();
    if (cachedWidgetLimit != 10 * 1024 * 1024) {
      debugPrint('Using cached widget bitmap limit: '
          '${(cachedWidgetLimit / (1024 * 1024)).toStringAsFixed(1)} MB');
    } else {
      final computedWidgetLimit = await _getWidgetBitmapLimitBytes();
      await UserPreferences.setWidgetBitmapLimit(computedWidgetLimit);
      debugPrint('Stored computed widget bitmap limit: '
          '${(computedWidgetLimit / (1024 * 1024)).toStringAsFixed(1)} MB');
    }

    // Supabase
    final supabaseOk = await initializeSupabaseIfNeeded();

    // Home Widget Status
    HomeWidgetStatus.instance.initialize();

    // Background FCM
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // Initial notification (app launched from notification)
    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      debugPrint('App launched from notification: ${initialMessage.messageId}');
      pendingNotificationMessage = initialMessage;
    }

    // FCM permissions and auto-init
    final messaging = FirebaseMessaging.instance;
    final settings = await messaging.requestPermission();
    debugPrint('FCM Authorization status: ${settings.authorizationStatus}');
    await FirebaseMessaging.instance.setAutoInitEnabled(true);

    // Sync FCM token
    if (supabaseOk) {
      await FcmHelper.initializeAndSyncToken();
      final cache = ProfilePictureCache.of(Supabase.instance.client);
      await cache.hydrate();
    } else {
      debugPrint('Skipping FCM/cache init, Supabase not initialized');
    }

    isAppInitialized = true;

    // Foreground FCM handler
    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      try {
        debugPrint(
            "Foreground FCM: ${message.messageId}, data=${message.data}");
        if (message.data['type'] == 'new_image') {
          debugPrint(
              'Foreground new image notification received, updating widget...');
          await updateHomeWidget();
        } else {
          debugPrint('Foreground notification not image-related');
        }

        if (message.notification != null &&
            scaffoldMessengerKey.currentContext != null) {
          showSnackBar(
            scaffoldMessengerKey.currentContext!,
            message.notification!.title ?? '',
            color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
          );
        }
      } catch (e, st) {
        debugPrint('Error handling foreground message: $e');
        debugPrint(st.toString());
        if (scaffoldMessengerKey.currentContext != null) {
          showSnackBar(
            scaffoldMessengerKey.currentContext!,
            'Error updating widget',
            color: Colors.red,
          );
        }
      }
    });

    // 11. On notification tap when app is in background
    FirebaseMessaging.onMessageOpenedApp.listen(handleNotificationNavigation);

    runApp(MyApp(navigatorKey: navigatorKey));
  } catch (e, st) {
    debugPrint('Error starting app: $e');
    debugPrint('Stack trace: $st');
    runApp(MyApp(navigatorKey: navigatorKey));
  }
}

class MyApp extends StatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;

  const MyApp({super.key, required this.navigatorKey});

  @override
  MyAppState createState() => MyAppState();
}

class MyAppState extends State<MyApp> {
  @override
  void initState() {
    super.initState();

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      // Handle pending notification
      if (pendingNotificationMessage != null) {
        debugPrint('Processing pending notification message');
        await handleNotificationNavigation(pendingNotificationMessage!);
        pendingNotificationMessage = null;
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
  Widget build(BuildContext context) {
    SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      systemNavigationBarColor: Colors.black,
      systemNavigationBarIconBrightness: Brightness.light,
    ));

    debugPrint('Building MyApp - isAppInitialized: $isAppInitialized');

    return MaterialApp(
      navigatorKey: widget.navigatorKey,
      scaffoldMessengerKey: scaffoldMessengerKey,
      title: 'KRAB',
      theme: ThemeData(
        actionIconTheme: ActionIconThemeData(
          backButtonIconBuilder: (context) {
            return const Icon(
              Icons.arrow_back_ios_new_rounded,
              fill: 1,
              size: 24,
            );
          },
        ),
        colorScheme: GlobalThemeData.darkColorScheme,
        useMaterial3: true,
        fontFamily: GoogleFonts.rubik(fontWeight: FontWeight.w400).fontFamily,
        iconTheme: const IconThemeData(weight: 650),
      ),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: FutureBuilder(
        future: _determineHomePage(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }

          return UpdateChecker(
            child: snapshot.data ?? const LoginPage(),
          );
        },
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

      if (!isSupabaseInitialized) {
        debugPrint(
            'Supabase not initialized in _determineHomePage → LoginPage');
        return const LoginPage();
      }

      final isLoggedIn = Supabase.instance.client.auth.currentUser != null;
      return isLoggedIn ? const CameraPage() : const LoginPage();
    } catch (e, st) {
      debugPrint('Error determining home page: $e');
      debugPrint(st.toString());
      return const LoginPage();
    }
  }
}
