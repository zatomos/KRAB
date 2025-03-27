import 'dart:io';
import 'firebase_options.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:home_widget/home_widget.dart';
import 'package:path_provider/path_provider.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'package:krab/services/supabase.dart';
import 'package:krab/pages/LoginPage.dart';
import 'package:krab/pages/CameraPage.dart';
import 'package:krab/pages/WelcomePage.dart';
import 'package:krab/pages/GroupPage.dart';
import 'package:krab/themes/GlobalThemeData.dart';
import 'package:krab/widgets/FloatingSnackBar.dart';
import 'package:krab/filesaver.dart';
import 'UserPreferences.dart';

// Flag to track initialization
bool isSupabaseInitialized = false;

// Context
final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

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
    debugPrint(
        "Retrieved image bytes successfully: ${imageBytes.length} bytes");

    // Get image description and sender
    final imageDescriptionResponse = await getImageDetails(imageId);
    final imageDescription = imageDescriptionResponse.data?['description'];
    final imageSenderID = imageDescriptionResponse.data?['uploaded_by'];
    final imageSenderResponse = await getUsername(imageSenderID);
    final imageSender = imageSenderResponse.data;
    debugPrint("Got image description: $imageDescription");
    debugPrint("Got image sender: $imageSender");

    // Use the temporary directory
    final Directory tempDir = await getTemporaryDirectory();
    final String imagePath = '${tempDir.path}/krab_image.jpg';

    // Check if the old image exists and delete it
    final File imageFile = File(imagePath);
    if (await imageFile.exists()) {
      debugPrint("Deleting old image file");
      await imageFile.delete();
    }

    // Write new image bytes to the file
    await imageFile.writeAsBytes(imageBytes);
    debugPrint("Saved new image to: $imagePath");

    // Clear any old widget data first
    await HomeWidget.saveWidgetData<String>('recentImageUrl', null);
    await HomeWidget.saveWidgetData<String>('recentImageDescription', null);
    await HomeWidget.saveWidgetData<String>('recentImageSender', null);

    // Small delay to ensure previous data is cleared
    await Future.delayed(const Duration(milliseconds: 100));

    // Save the new widget data and update the widget
    await HomeWidget.saveWidgetData<String>('recentImageUrl', imageFile.path);
    await HomeWidget.saveWidgetData<String>(
        'recentImageDescription', imageDescription);
    await HomeWidget.saveWidgetData<String>('recentImageSender', imageSender);
    await HomeWidget.updateWidget(name: 'HomeScreenWidget');
    await HomeWidget.updateWidget(name: 'HomeScreenWidgetWithText');

    debugPrint('Widget updated successfully with image: $imagePath');

    // Save the image to the gallery if auto-save is enabled
    final autoSave = await UserPreferences.getAutoImageSave();
    if (autoSave) {
      debugPrint('Saving image to gallery...');
      final uploadedByResponse = await getUsername(imageId);
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
Future<void> initializeSupabaseIfNeeded() async {
  if (!isSupabaseInitialized) {
    await Supabase.initialize(
      url: dotenv.env['SUPABASE_URL']!,
      anonKey: dotenv.env['SUPABASE_ANON_KEY']!,
    );
    isSupabaseInitialized = true;
    debugPrint('Supabase initialized');
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

    // Initialize Supabase
    await dotenv.load(fileName: ".env");
    await initializeSupabaseIfNeeded();

    // Update widget
    await updateHomeWidget();

    debugPrint('Background message processed successfully');
  } catch (e) {
    debugPrint('Error in background handler: $e');
  }
}

void main() async {
  try {
    WidgetsFlutterBinding.ensureInitialized();

    // Load .env file
    await dotenv.load(fileName: ".env");

    // Initialize Shared Preferences
    await UserPreferences().initPrefs();

    // Initialize Supabase with safety check
    await initializeSupabaseIfNeeded();

    // Initialize Firebase
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );

    // Request permission for notifications
    FirebaseMessaging messaging = FirebaseMessaging.instance;
    NotificationSettings settings = await messaging.requestPermission();
    debugPrint('FCM Authorization status: ${settings.authorizationStatus}');

    // Enable auto-initialization of FCM
    await FirebaseMessaging.instance.setAutoInitEnabled(true);

    // Register background message handler
    FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

    // Initialize FCM token storage and listener
    await _initializeFCM();

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

    // Handle notification clicks
    FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) async {
      debugPrint('Notification clicked: ${message.messageId}');
      debugPrint('Notification data: ${message.data}');

      // Fetch data
      final data = message.data;
      final imageId = data['image_id'] ?? '';
      final groupId = data['group_id'] ?? '';

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

      // Navigate to group page
      navigatorKey.currentState!.push(
        MaterialPageRoute(
          builder: (_) => GroupPage(group: group, imageId: imageId),
        ),
      );
    });

    runApp(MyApp(navigatorKey: navigatorKey));
  } catch (e) {
    debugPrint('Error starting app: $e');
  }
}

/// Ensures FCM token is stored and refreshed
Future<void> _initializeFCM() async {
  try {
    final fcmToken = await FirebaseMessaging.instance.getToken();
    debugPrint('FCM Token: $fcmToken');

    if (fcmToken != null) {
      final user = Supabase.instance.client.auth.currentUser;
      if (user != null) {
        await _setFcmToken(fcmToken);
      } else {
        debugPrint("No logged-in user, skipping FCM token update.");
      }
    }

    FirebaseMessaging.instance.onTokenRefresh.listen((event) async {
      debugPrint('FCM Token refreshed: $event');
      final user = Supabase.instance.client.auth.currentUser;
      if (user != null) {
        await _setFcmToken(event);
      }
    });
  } catch (e) {
    debugPrint('Error initializing FCM: $e');
  }
}

/// Stores the FCM token in Supabase
Future<void> _setFcmToken(String fcmToken) async {
  final user = Supabase.instance.client.auth.currentUser;
  if (user == null) {
    debugPrint("No logged-in user, skipping FCM token update.");
    return;
  }

  await Supabase.instance.client.from('users').upsert({
    'id': user.id,
    'fcm_token': fcmToken,
  });
}

class MyApp extends StatefulWidget {
  final GlobalKey<NavigatorState> navigatorKey;

  const MyApp({super.key, required this.navigatorKey});

  @override
  MyAppState createState() => MyAppState();
}

class MyAppState extends State<MyApp> {
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

    final user = Supabase.instance.client.auth.currentUser;

    return MaterialApp(
      navigatorKey: widget.navigatorKey,
      scaffoldMessengerKey: scaffoldMessengerKey,
      title: 'KRAB',
      theme: ThemeData(
        colorScheme: GlobalThemeData.darkColorScheme,
        useMaterial3: true,
      ),
      home: UserPreferences.isFirstLaunch
          ? const WelcomePage()
          : (user == null ? const LoginPage() : const CameraPage()),
    );
  }
}
