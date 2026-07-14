import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:krab/app_globals.dart';
import 'package:krab/services/api/supabase.dart';
import 'package:krab/services/auth/app_auth.dart';
import 'package:krab/models/group.dart';
import 'package:krab/pages/groups_page.dart';
import 'package:krab/pages/image_feed_page.dart';

/// Waits for the navigator to mount and returns it, or null if it never comes up
Future<NavigatorState?> _awaitNavigator() async {
  try {
    return await navigatorReady.future.timeout(const Duration(seconds: 5));
  } on TimeoutException {
    return navigatorKey.currentState;
  }
}

/// Open a gallery for a tap that came from outside the app.
void _openGalleryOnGroupList(
  NavigatorState nav, {
  Group? group,
  String? imageId,
}) {
  nav.popUntil((route) => route.isFirst);
  nav.push(MaterialPageRoute(
    settings: const RouteSettings(name: GroupsPage.routeName),
    builder: (_) => const GroupsPage(),
  ));
  nav.push(MaterialPageRoute(
    builder: (_) => ImageFeedPage(group: group, imageId: imageId),
  ));
}

/// Handle a tap on a home-screen widget. The URI is emitted by the native
/// widget providers via the home_widget plugin:
///   krab://open?imageId=ID     open the all-groups gallery on that image
///   krab://open?action=camera  bring the camera to the front
Future<void> handleWidgetLaunch(Uri? uri) async {
  if (uri == null) return;
  debugPrint('Handling widget launch: $uri');
  try {
    final nav = await _awaitNavigator();
    if (nav == null) return;

    // Only act on an authenticated session; otherwise the app just opens
    if (!isSupabaseInitialized || !AppAuth.instance.isLoggedIn) {
      return;
    }

    if (uri.queryParameters['action'] == 'camera') {
      nav.popUntil((route) => route.isFirst);
      return;
    }

    final imageId = uri.queryParameters['imageId'];
    if (imageId != null && imageId.isNotEmpty) {
      _openGalleryOnGroupList(nav, imageId: imageId);
    }
  } catch (e, st) {
    debugPrint('Error handling widget launch: $e\n$st');
  }
}

Future<void> handleLocalNotificationTap(String payload) async {
  try {
    final data = jsonDecode(payload) as Map<String, dynamic>;
    final type = data['type'] as String? ?? '';
    final groupId = data['group_id'] as String? ?? '';
    final imageId = data['image_id'] as String? ?? '';

    final nav = await _awaitNavigator();
    if (nav == null) return;

    // Nothing here belongs to a single group: a reaction isn't tied to one at
    // all, and a photo delivered to the user through several groups at once has
    // no one group to open. dispatchImageNotification leaves group_id empty to
    // say so. Both open the all-groups gallery, on the image.
    if (type == 'new_reaction' || (type == 'new_image' && groupId.isEmpty)) {
      if (imageId.isEmpty) return;
      _openGalleryOnGroupList(nav, imageId: imageId);
      return;
    }

    if (groupId.isEmpty) return;
    final groupResponse = await getGroupDetails(groupId);
    if (!groupResponse.success || groupResponse.data == null) return;

    _openGalleryOnGroupList(
      nav,
      group: groupResponse.data!,
      imageId: imageId,
    );
  } catch (e) {
    debugPrint('Error handling local notification tap: $e');
  }
}
