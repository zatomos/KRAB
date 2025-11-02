import 'dart:io';

import 'firebase_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:home_widget/home_widget.dart';
import 'package:path_provider/path_provider.dart';

import 'package:krab/services/supabase.dart';
import 'package:krab/services/fcm_helper.dart';
import 'package:krab/pages/WelcomePage.dart';
import 'package:krab/pages/LoginPage.dart';
import 'package:krab/pages/DBConfigPage.dart';
import 'package:krab/pages/CameraPage.dart';
import 'package:krab/pages/GroupImagesPage.dart';
import 'package:krab/themes/GlobalThemeData.dart';
import 'package:krab/widgets/FloatingSnackBar.dart';
import 'package:krab/filesaver.dart';
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

/// Updates the home widget with the latest image
Future<void> updateHomeWidget() async {
  try {
    debugPrint("Starting home widget update...");

    // Get the ID of the latest image
    final response = await getLatestImage();
    final imageId = response.data;
    if (imageId == null) {
      debugPrint("Latest image ID is null, aborting widget update.");
      return;
    }
    debugPrint("Got latest image ID: $imageId");

    // Get image bytes
    final imageResponse = await getImage(imageId);
    final Uint8List? imageBytes = imageResponse.data;
    if (imageBytes == null) {
      debugPrint("Image bytes are null, aborting widget update.");
      return;
    }
    debugPrint("Retrieved image bytes successfully: ${imageBytes.length} bytes");

    // Get image description and sender
    final imageDescriptionResponse = await getImageDetails(imageId);
    final imageDescription = imageDescriptionResponse.data?['description'];
    final imageSenderID = imageDescriptionResponse.data?['uploaded_by'];
    final imageSenderResponse = await getUsername(imageSenderID);
    final imageSender = imageSenderResponse.data;
    debugPrint("Got image description: $imageDescription");
    debugPrint("Got image sender: $imageSender");

    final Directory tempDir = await getTemporaryDirectory();
    final String imagePath = '${tempDir.path}/krab_widget_current.jpg';

    // Write new image bytes to the file
    final File imageFile = File(imagePath);
    await imageFile.writeAsBytes(imageBytes, flush: true);
    debugPrint("Saved new image to: $imagePath");

    // Delay
    await Future.delayed(const Duration(milliseconds: 100));

    // Verify file was written successfully
    if (!await imageFile.exists()) {
      debugPrint("ERROR: Image file was not created successfully");
      return;
    }
    final fileSize = await imageFile.length();
    debugPrint("Verified file exists with size: $fileSize bytes");

    // Save the new widget data
    await HomeWidget.saveWidgetData<String>('recentImageUrl', imageFile.path);
    await HomeWidget.saveWidgetData<String>('recentImageDescription', imageDescription ?? '');
    await HomeWidget.saveWidgetData<String>('recentImageSender', imageSender ?? '');

    // Delay
    await Future.delayed(const Duration(milliseconds: 300));

    // Update widget
    try {
      final updated1 = await HomeWidget.updateWidget(name: 'HomeScreenWidget');
      final updated2 = await HomeWidget.updateWidget(name: 'HomeScreenWidgetWithText');
      debugPrint('Widget update results - HomeScreenWidget: $updated1, HomeScreenWidgetWithText: $updated2');
    } catch (e) {
      debugPrint('Error calling HomeWidget.updateWidget: $e');
    }

    debugPrint('Widget updated successfully with image: $imagePath');

    // Clean up old images
    try {
      final files = tempDir.listSync()
          .whereType<File>()
          .where((f) => f.path.contains('krab_image_') && !f.path.contains('krab_widget_current'))
          .toList();

      for (var file in files) {
        try {
          await file.delete();
        } catch (e) {
          debugPrint("Error deleting old image: $e");
        }
      }
    } catch (e) {
      debugPrint("Error cleaning old images: $e");
    }

    // Save the image to the gallery if auto-save is enabled
    final autoSave = await UserPreferences.getAutoImageSave();
    if (autoSave) {
      debugPrint('Saving image to gallery...');
      final uploadedByResponse = await getUsername(imageSenderID);
      final uploadedBy = uploadedByResponse.data;
      if (uploadedBy != null) {
        final createdAt = DateTime.now().toIso8601String();
        await downloadImage(imageBytes, uploadedBy, createdAt);
      } else {
        debugPrint('Uploaded by value is null, skipping gallery save.');
      }
    }
  } catch (e, stackTrace) {
    debugPrint('Error updating home widget: $e');
    debugPrint('Stack trace: $stackTrace');
  }
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

    // Initialize Shared Preferences FIRST and WAIT for it
    await UserPreferences().initPrefs();

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
        colorScheme: GlobalThemeData.darkColorScheme,
        useMaterial3: true,
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
          return snapshot.data ?? const DBConfigPage();
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