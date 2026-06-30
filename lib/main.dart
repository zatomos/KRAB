import 'dart:async';
import 'dart:convert';
import 'firebase_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:home_widget/home_widget.dart';

import 'package:krab/services/api/supabase.dart';
import 'package:krab/services/background_session.dart';
import 'package:krab/services/fcm_helper.dart';
import 'package:krab/services/feed_events.dart';
import 'package:krab/services/home_widget_updater.dart';
import 'package:krab/services/home_widget_status.dart';
import 'package:krab/services/notification_channels.dart';
import 'package:krab/services/update_service.dart';
import 'package:workmanager/workmanager.dart';
import 'package:krab/services/profile_picture_cache.dart';
import 'package:krab/services/debug_notifier.dart';
import 'package:krab/pages/welcome_page.dart';
import 'package:krab/pages/login_page.dart';
import 'package:krab/pages/camera_page.dart';
import 'package:krab/pages/image_feed_page.dart';
import 'package:krab/themes/global_theme_data.dart';
import 'package:krab/widgets/floating_snack_bar.dart';
import 'package:krab/widgets/dialogs/reauth_prompt.dart';
import 'package:krab/widgets/update_checker.dart';
import 'package:krab/l10n/l10n.dart';
import 'user_preferences.dart';

bool isSupabaseInitialized = false;
bool isAppInitialized = false;
Completer<bool>? _supabaseInitCompleter;

final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

RemoteMessage? pendingNotificationMessage;
String? pendingLocalNotificationPayload;
Uri? pendingWidgetUri;

/// Handle a tap on a home-screen widget. The URI is emitted by the native
/// widget providers via the home_widget plugin:
///   krab://open?imageId=ID     open the all-groups gallery on that image
///   krab://open?action=camera  bring the camera to the front
Future<void> handleWidgetLaunch(Uri? uri) async {
  if (uri == null) return;
  debugPrint('Handling widget launch: $uri');
  try {
    int attempts = 0;
    while (navigatorKey.currentState == null && attempts < 20) {
      await Future.delayed(const Duration(milliseconds: 100));
      attempts++;
    }
    final nav = navigatorKey.currentState;
    if (nav == null) return;

    // Only act on an authenticated session; otherwise the app just opens
    if (!isSupabaseInitialized ||
        Supabase.instance.client.auth.currentUser == null) {
      return;
    }

    if (uri.queryParameters['action'] == 'camera') {
      nav.popUntil((route) => route.isFirst);
      return;
    }

    final imageId = uri.queryParameters['imageId'];
    if (imageId != null && imageId.isNotEmpty) {
      nav.push(
        MaterialPageRoute(
          builder: (_) => ImageFeedPage(imageId: imageId),
        ),
      );
    }
  } catch (e, st) {
    debugPrint('Error handling widget launch: $e\n$st');
  }
}

Future<void> _handleLocalNotificationTap(String payload) async {
  try {
    final data = jsonDecode(payload) as Map<String, dynamic>;
    final type = data['type'] as String? ?? '';
    final groupId = data['group_id'] as String? ?? '';
    final imageId = data['image_id'] as String? ?? '';

    int attempts = 0;
    while (navigatorKey.currentState == null && attempts < 20) {
      await Future.delayed(const Duration(milliseconds: 100));
      attempts++;
    }
    final nav = navigatorKey.currentState;
    if (nav == null) return;

    // Reactions aren't tied to a group: open the all-groups gallery on the image.
    if (type == 'new_reaction') {
      if (imageId.isEmpty) return;
      nav.push(
        MaterialPageRoute(builder: (_) => ImageFeedPage(imageId: imageId)),
      );
      return;
    }

    if (groupId.isEmpty) return;
    final groupResponse = await getGroupDetails(groupId);
    if (!groupResponse.success || groupResponse.data == null) return;

    nav.push(
      MaterialPageRoute(
        builder: (_) => ImageFeedPage(
          group: groupResponse.data!,
          imageId: imageId,
        ),
      ),
    );
  } catch (e) {
    debugPrint('Error handling local notification tap: $e');
  }
}

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
    await Supabase.initialize(
      url: url,
      anonKey: anon,
      authOptions: const FlutterAuthClientOptions(
        authFlowType: AuthFlowType.implicit,
      ),
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

/// Initialize Supabase for a background isolate
Future<bool> initializeBackgroundSupabase(LocalStorage storage) async {
  if (isSupabaseInitialized) return true;

  final url = UserPreferences.supabaseUrl;
  final anon = UserPreferences.supabaseAnonKey;

  if (url.isEmpty || anon.isEmpty) {
    debugPrint('Background Supabase config missing, cannot initialize.');
    return false;
  }

  try {
    await Supabase.initialize(
      url: url,
      anonKey: anon,
      authOptions: FlutterAuthClientOptions(
        authFlowType: AuthFlowType.implicit,
        localStorage: storage,
      ),
    );
    isSupabaseInitialized = true;
    debugPrint('Background Supabase initialized (isolated session)');
    return true;
  } catch (e) {
    debugPrint('Background Supabase init failed: $e');
    isSupabaseInitialized = false;
    return false;
  }
}

/// Common boot sequence for background isolates
Future<void> _bootstrapBackgroundIsolate() async {
  WidgetsFlutterBinding.ensureInitialized();
  await dotenv.load(fileName: ".env");
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await UserPreferences().initPrefs();
  await DebugNotifier.instance.initialize();
}

@pragma('vm:entry-point')
void workmanagerCallbackDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    try {
      await _bootstrapBackgroundIsolate();

      // Piggyback a throttled app-update check on this wakeup
      await UpdateService.maybeCheckAndNotifyUpdate();

      // This isolate owns its own background session and refreshes it itself
      final supabaseOk = await initializeBackgroundSupabase(
          BackgroundSession.workmanagerStorage);
      if (!supabaseOk) {
        debugPrint('WorkManager: Supabase init failed, skipping widget update');
        return Future.value(false);
      }
      if (!await BackgroundSession.recoverOrClear(
          BackgroundSession.workmanagerStorage)) {
        return Future.value(true);
      }

      await updateHomeWidget();
      return Future.value(true);
    } catch (e, st) {
      debugPrint('WorkManager task failed: $e\n$st');
      return Future.value(false);
    }
  });
}

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  debugPrint('Handling background message: ${message.messageId}');
  debugPrint('Background data: ${message.data}');

  final type = message.data['type'];
  if (type != 'new_image' &&
      type != 'new_comment' &&
      type != 'group_comment' &&
      type != 'comment_reply' &&
      type != 'new_reaction' &&
      type != 'image_deleted') {
    debugPrint('Background message type "$type" not handled, skipping');
    return;
  }

  try {
    await _bootstrapBackgroundIsolate();
    await DebugNotifier.instance.notifyBackgroundTaskStarted();

    final supabaseOk =
        await initializeBackgroundSupabase(BackgroundSession.fcmStorage);
    if (!supabaseOk) {
      debugPrint('Supabase not initialized (background)');
      await DebugNotifier.instance
          .notifySupabaseInitFailed('Background: Supabase init failed');
      return;
    }

    if (!await BackgroundSession.recoverOrClear(BackgroundSession.fcmStorage)) {
      await DebugNotifier.instance.notifyBackgroundTaskFailed(
          'Background session expired, reopen the app to re-authenticate');
      return;
    }

    if (type == 'new_image') {
      await dispatchImageNotification(message.data);
      await updateHomeWidget();
    } else if (type == 'image_deleted') {
      // The image is gone, clear any standing notification for it and refresh
      // the widget so it drops out
      await cancelImageNotification(message.data['image_id'] ?? '');
      await updateHomeWidget();
    } else if (type == 'new_reaction') {
      await dispatchReactionNotification(message.data);
    } else {
      await dispatchCommentNotification(message.data, type);
    }

    debugPrint('Background message processed successfully');
    await DebugNotifier.instance.notifyBackgroundTaskCompleted();
  } catch (e, st) {
    debugPrint('Error in background handler: $e');
    debugPrint(st.toString());
    await DebugNotifier.instance.notifyBackgroundTaskFailed('$e');
  }
}

Future<void> handleNotificationNavigation(RemoteMessage message) async {
  debugPrint('Processing notification navigation: ${message.messageId}');
  debugPrint('Notification data: ${message.data}');

  if (!isSupabaseInitialized) {
    debugPrint('Supabase not initialized, skipping navigation');
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

    debugPrint('Navigating to ImageFeedPage');
    navigatorKey.currentState!.push(
      MaterialPageRoute(
        builder: (_) => ImageFeedPage(group: group, imageId: imageId),
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

    // Initialize Debug Notifier
    await DebugNotifier.instance.initialize();

    // Initialize local notification tap handler
    await initCommentNotifications(
      onTap: (payload) => _handleLocalNotificationTap(payload),
    );
    final localLaunchPayload = await getLocalNotificationLaunchPayload();
    if (localLaunchPayload != null) {
      pendingLocalNotificationPayload = localLaunchPayload;
    }

    // Supabase
    final supabaseOk = await initializeSupabaseIfNeeded();

    // Home Widget Status
    HomeWidgetStatus.instance.initialize();

    // WorkManager periodic widget refresh
    await Workmanager().initialize(workmanagerCallbackDispatcher);
    await scheduleWidgetRefresh(UserPreferences.widgetRefreshIntervalMinutes);

    // Background FCM
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

    // Initial notification (app launched from notification)
    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      debugPrint('App launched from notification: ${initialMessage.messageId}');
      pendingNotificationMessage = initialMessage;
    }

    // Home-screen widget taps
    final initialWidgetUri = await HomeWidget.initiallyLaunchedFromHomeWidget();
    if (initialWidgetUri != null) {
      debugPrint('App launched from widget: $initialWidgetUri');
      pendingWidgetUri = initialWidgetUri;
    }
    HomeWidget.widgetClicked.listen(handleWidgetLaunch);

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

      // Cache groups so the widget configure screen can offer a group filter
      await cacheUserGroupsForWidget();

      // Monitor auth state changes
      Supabase.instance.client.auth.onAuthStateChange.listen((data) async {
        final event = data.event;
        debugPrint('Auth state changed: $event');

        switch (event) {
          case AuthChangeEvent.signedOut:
            if (DebugNotifier.instance.isIntentionalLogout) {
              await DebugNotifier.instance
                  .notifyAuthSignedOut(unexpected: false);
            } else {
              await DebugNotifier.instance.notifyAuthSignedOut();
              navigatorKey.currentState?.pushAndRemoveUntil(
                MaterialPageRoute(builder: (_) => const LoginPage()),
                (route) => false,
              );
            }
            break;
          case AuthChangeEvent.tokenRefreshed:
            await DebugNotifier.instance.notifyAuthTokenRefreshed();
            break;
          case AuthChangeEvent.signedIn:
            await DebugNotifier.instance.notifyAuthStateChanged(event.name);
            // The cold-start widget refresh (app resume) can fire before the
            // session is restored, failing with "User not authenticated". Now
            // that we're authenticated, refresh so the widget actually fills in
            unawaited(updateHomeWidget());
            break;
          default:
            await DebugNotifier.instance.notifyAuthStateChanged(event.name);
        }
      });
    } else {
      debugPrint('Skipping FCM/cache init, Supabase not initialized');
    }

    isAppInitialized = true;

    // Foreground FCM handler
    FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
      try {
        debugPrint(
            "Foreground FCM: ${message.messageId}, data=${message.data}");
        final msgType = message.data['type'];
        if (msgType == 'new_image') {
          await dispatchImageNotification(message.data);
          await updateHomeWidget();
          // Let an open feed surface a new photos pill without a refresh.
          FeedEvents.instance.notifyNewImage(NewImageEvent(
            imageId: message.data['image_id'] ?? '',
            groupId: message.data['group_id'],
          ));
        } else if (msgType == 'new_comment' ||
            msgType == 'group_comment' ||
            msgType == 'comment_reply') {
          await dispatchCommentNotification(message.data, msgType);
        } else if (msgType == 'new_reaction') {
          await dispatchReactionNotification(message.data);
        } else if (msgType == 'image_deleted') {
          await cancelImageNotification(message.data['image_id'] ?? '');
          await updateHomeWidget();
        }

        if (message.notification != null &&
            scaffoldMessengerKey.currentContext != null) {
          showSnackBar(
            message.notification!.title ?? '',
            color: GlobalThemeData.darkColorScheme.onSurfaceVariant,
          );
        }
      } catch (e, st) {
        debugPrint('Error handling foreground message: $e');
        debugPrint(st.toString());
        if (scaffoldMessengerKey.currentContext != null) {
          showSnackBar(
            'Error updating widget',
            color: Colors.red,
          );
        }
      }
    });

    // On notification tap when app is in background
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
      // Handle pending FCM notification (app launched from FCM tap)
      if (pendingNotificationMessage != null) {
        debugPrint('Processing pending notification message');
        await handleNotificationNavigation(pendingNotificationMessage!);
        pendingNotificationMessage = null;
      }

      // Handle pending local notification (app launched from local notification tap)
      if (pendingLocalNotificationPayload != null) {
        debugPrint('Processing pending local notification');
        await _handleLocalNotificationTap(pendingLocalNotificationPayload!);
        pendingLocalNotificationPayload = null;
      }

      // Handle pending widget tap
      if (pendingWidgetUri != null) {
        debugPrint('Processing pending widget launch');
        await handleWidgetLaunch(pendingWidgetUri);
        pendingWidgetUri = null;
      }

      // One-time prompt to establish the background session for users who were
      // already logged in before it existed
      if (isSupabaseInitialized && navigatorKey.currentContext != null) {
        await showReauthPromptIfNeeded(navigatorKey.currentContext!);
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
    if (!isSupabaseInitialized) return;

    // Re-establish the background session if it was dropped while we were away
    final ctx = navigatorKey.currentContext;
    if (ctx != null) {
      showReauthPromptIfNeeded(ctx);
    }

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
      builder: (context, child) => SafeArea(top: false, child: child!),
      home: FutureBuilder(
        future: _homePageFuture,
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
            'Supabase not initialized in determineHomePage, showing LoginPage');
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
