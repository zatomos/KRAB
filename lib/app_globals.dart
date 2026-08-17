import 'dart:async';

import 'package:flutter/material.dart';

/// App-wide keys and launch state shared by the entry point, the launch router
/// and the widget tree. Each isolate has its own copy.

final GlobalKey<ScaffoldMessengerState> scaffoldMessengerKey =
    GlobalKey<ScaffoldMessengerState>();
final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

/// Completes with the navigator once the widget tree's first frame is up.
final Completer<NavigatorState> navigatorReady = Completer<NavigatorState>();

/// Lets a page know when it stops being the one on screen.
final RouteObserver<PageRoute<void>> routeObserver =
    RouteObserver<PageRoute<void>>();

/// True once the foreground boot sequence in `main` has finished.
bool isAppInitialized = false;
