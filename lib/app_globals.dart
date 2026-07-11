import 'dart:async';

import 'package:flutter/material.dart';

/// App-wide keys and one-shot launch state shared by the entry point, the
/// notification router and the widget tree. Each isolate has its own copy.

final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Completes with the navigator once the widget tree's first frame is up.
final Completer<NavigatorState> navigatorReady = Completer<NavigatorState>();

/// True once `Supabase.initialize` has completed in this isolate.
bool isSupabaseInitialized = false;

/// True once the foreground boot sequence in `main` has finished.
bool isAppInitialized = false;

/// Local-notification and widget taps captured during launch
String? pendingLocalNotificationPayload;
Uri? pendingWidgetUri;
