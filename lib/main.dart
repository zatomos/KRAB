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
import 'package:krab/services/profile_picture_cache.dart';
import 'package:krab/pages/WelcomePage.dart';
import 'package:krab/pages/LoginPage.dart';
import 'package:krab/pages/DBConfigPage.dart';
import 'package:krab/pages/CameraPage.dart';
import 'package:krab/pages/GroupImagesPage.dart';
import 'package:krab/themes/GlobalThemeData.dart';
import 'package:krab/widgets/FloatingSnackBar.dart';
import 'package:krab/widgets/UpdateChecker.dart';
import 'package:krab/l10n/l10n.dart';
import 'UserPreferences.dart';

// Flag to track initialization
bool isSupabaseInitialized = false;
bool isAppInitialized = false;

// Context
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
GlobalKey<ScaffoldMessengerState>();
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

// Store pending notification for navigation after app is ready
RemoteMessage? pendingNotificationMessage;

/// Compute bitmap size limit
/// screen width * height * 4 bytes per pixel * 1.5
Future<int> _getWidgetBitmapLimitBytes() async {
  final views = WidgetsBinding.instance.platformDispatcher.views;

  final view = views.first;
  final mq = MediaQueryData.fromView(view);
  final width = mq.size.width * mq.devicePixelRatio;
  final height = mq.size.height * mq.devicePixelRatio;
  final bytes = (width * height * 4 * 1.5).round();

  if (views.isEmpty || bytes <= 0) {
    debugPrint('Failed to get screen size, using default 10 MB limit.');
    return 10 * 1024 * 1024;
  }

  debugPrint(
    'Computed widget bitmap limit: ${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB '
        '(${width.round()}×${height.round()})',
  );

  return bytes;
}

/// Initialize Supabase if not already initialized
Future<bool> initializeSupabaseIfNeeded() async {
  if (isSupabaseInitialized) return true;

  final url = UserPreferences.supabaseUrl;
  final anon = UserPreferences.supabaseAnonKey;

  if (url.isEmpty || anon.isEmpty) {
    debugPrint('Supabase config missing, cannot initialize.');
    return false;
  }

  try {
    await Supabase.initialize(url: url, anonKey: anon);
    isSupabaseInitialized = true;
    return true;
  } catch (e) {
    debugPrint('Supabase init failed: $e');
    isSupabaseInitialized = false;
    return false;
  }
}

/// Background handler for Firebase push notifications
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('Handling background message: ${message.messageId}');

  // Check if the message is about a new image
  if (message.data['type'] != 'new_image') {
    debugPrint('Message is not about a new image, skipping');
    return;
  }

  try {
    // Initialize Firebase first
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    await UserPreferences().initPrefs();
    final supabaseOk = await initializeSupabaseIfNeeded();
    if (!supabaseOk) {
      debugPrint('Skipping widget update, Supabase not initialized');
      return;
    }

    // Update widget
    await updateHomeWidget();

    debugPrint('Background message processed successfully');
  } catch (e) {
    debugPrint('Error in background handler: $e');
  }
}

/// Handle notification navigation
Future<void> handleNotificationNavigation(RemoteMessage message) async {
  debugPrint('Processing notification navigation: ${message.messageId}');
  debugPrint('Notification data: ${message.data}');

  try {
    // Fetch data
    final data = message.data;
    final imageId = data['image_id'] ?? '';
    final groupId = data['group_id'] ?? '';

    if (groupId.isEmpty) {
      debugPrint('Group ID is empty, aborting navigation');
      return;
    }

    // Get group
    final groupResponse = await getGroupDetails(groupId);
    if (groupResponse.success == false) {
      debugPrint('Error fetching group: ${groupResponse.error}');
      return;
    }
    final group = groupResponse.data;

    if (group == null) {
      debugPrint('Group is null, aborting navigation');
      return;
    }

    // Wait for navigator to be ready
    int attempts = 0;
    while (navigatorKey.currentState == null && attempts < 20) {
      await Future.delayed(const Duration(milliseconds: 100));
      attempts++;
    }

    if (navigatorKey.currentState == null) {
      debugPrint('Navigator still not ready after waiting, storing for later');
      return;
    }

    // Navigate to group page
    debugPrint('Navigating to GroupImagesPage');
    navigatorKey.currentState!.push(
      MaterialPageRoute(
        builder: (_) => GroupImagesPage(group: group, imageId: imageId),
      ),
    );
  } catch (e, stackTrace) {
    debugPrint('Error handling notification navigation: $e');
    debugPrint('Stack trace: $stackTrace');
  }
}

void main() async {
  try {
    WidgetsFlutterBinding.ensureInitialized();

    // Initialize Shared Preferences
    await UserPreferences().initPrefs();

    // Compute and store widget bitmap limit
    final cachedWidgetLimit = await UserPreferences.getWidgetBitmapLimit();
    if (cachedWidgetLimit != 10 * 1024 * 1024) {
      debugPrint('Using cached widget bitmap limit: '
          '${(cachedWidgetLimit / (1024 * 1024)).toStringAsFixed(1)} MB');
    }
    else {
      final computedWidgetLimit = await _getWidgetBitmapLimitBytes();
      await UserPreferences.setWidgetBitmapLimit(computedWidgetLimit);
      debugPrint('Stored computed widget bitmap limit: '
          '${(computedWidgetLimit / (1024 * 1024)).toStringAsFixed(1)} MB');
    }

    // Initialize Supabase with safety check
    final supabaseOk = await initializeSupabaseIfNeeded();

    // Initialize Firebase
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    // Check for notification that launched the app
    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      debugPrint('App launched from notification: ${initialMessage.messageId}');
      pendingNotificationMessage = initialMessage;
    }

    // Request permission for notifications
    FirebaseMessaging messaging = FirebaseMessaging.instance;
    NotificationSettings settings = await messaging.requestPermission();
    debugPrint('FCM Authorization status: ${settings.authorizationStatus}');

    // Enable auto-initialization of FCM
    await FirebaseMessaging.instance.setAutoInitEnabled(true);

    // Register background message handler
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    // Initialize FCM token storage and listener
    if (supabaseOk) {
      await FcmHelper.initializeAndSyncToken();
    } else {
      debugPrint('Skipping FCM initialization, Supabase not initialized');
    }

    // Initialize URL cache
    final cache = ProfilePictureCache.of(Supabase.instance.client);
    await cache.hydrate();

    // Load dotenv
    await dotenv.load(fileName: ".env");

    // Mark initialization as complete
    isAppInitialized = true;

    // Handle foreground messages
    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      try {
        debugPrint("${message.notification?.title}");
        if (message.data['type'] == 'new_image') {
          debugPrint('New image notification received');
          await updateHomeWidget();
        } else {
          debugPrint('Non-image notification received');
        }

        if (message.notification != null) {
          showSnackBar(
            scaffoldMessengerKey.currentContext!,
            message.notification!.title!,
            color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
          );
        }
      } catch (e) {
        debugPrint('Error handling foreground message: $e');
        showSnackBar(
          scaffoldMessengerKey.currentContext!,
          'Error updating widget',
          color: Colors.red,
        );
      }
    });

    // Handle notification clicks when app is in background
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) async {
      await handleNotificationNavigation(message);
    });

    runApp(MyApp(navigatorKey: navigatorKey));
  } catch (e, stackTrace) {
    debugPrint('Error starting app: $e');
    debugPrint('Stack trace: $stackTrace');
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

    // Handle pending notification
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (pendingNotificationMessage != null) {
        debugPrint('Processing pending notification message');
        handleNotificationNavigation(pendingNotificationMessage!);
        pendingNotificationMessage = null;
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
    debugPrint('Current supabaseUrl: ${UserPreferences.supabaseUrl}');
    debugPrint('Current supabaseAnonKey: ${UserPreferences.supabaseAnonKey}');

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
        iconTheme: const IconThemeData(
            weight: 650),
      ),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: FutureBuilder(
        future: _determineHomePage(),
        builder: (context, snapshot) {
          // Loading indicator
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              body: Center(
                child: CircularProgressIndicator(),
              ),
            );
          }

          // Return home page
          return UpdateChecker(
            child: snapshot.data ?? const DBConfigPage(),
          );
        },
      ),
    );
  }

  Future<Widget> _determineHomePage() async {
    try {
      // Ensure initialization is complete
      if (!isAppInitialized) {
        debugPrint('Waiting for app initialization...');
        await Future.delayed(const Duration(milliseconds: 500));
      }

      final hasConfig = UserPreferences.supabaseUrl.isNotEmpty &&
          UserPreferences.supabaseAnonKey.isNotEmpty;

      if (!hasConfig) {
        return UserPreferences.isFirstLaunch
            ? const WelcomePage()
            : const DBConfigPage();
      }

      // Check if user is logged in
      final isLoggedIn = Supabase.instance.client.auth.currentUser != null;

      return isLoggedIn ? const CameraPage() : const LoginPage();
    } catch (e) {
      debugPrint('Error determining home page: $e');
      return const DBConfigPage();
    }
  }
}