import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:home_widget/home_widget.dart';

import 'package:krab/app_globals.dart';
import 'package:krab/services/instance/instances.dart';
import 'package:krab/services/instance/instance_bootstrap.dart';
import 'package:krab/services/notification_channels.dart';
import 'package:krab/models/group.dart';
import 'package:krab/pages/groups_page.dart';
import 'package:krab/pages/image_feed_page.dart';

/// Where a tap from outside the app should land.
sealed class _Destination {
  const _Destination();
}

/// Whatever the app already had on screen, with everything above it popped.
class _Home extends _Destination {
  const _Home();
}

class _Gallery extends _Destination {
  const _Gallery({this.group, this.imageId, this.openComments = false});

  final Group? group;
  final String? imageId;
  final bool openComments;
}

const _commentTypes = {'new_comment', 'group_comment', 'comment_reply'};

class LaunchRouter {
  LaunchRouter._();

  static final LaunchRouter instance = LaunchRouter._();

  StreamSubscription<Uri?>? _widgetTaps;

  Future<void> _tail = Future.value();
  Future<void> get settled => _tail;

  /// Captures what opened the app and subscribes to later taps.
  Future<void> initialize() async {
    await initCommentNotifications(onTap: handleNotificationPayload);
    _widgetTaps ??= HomeWidget.widgetClicked.listen(handleWidgetUri);

    final payload = await getLocalNotificationLaunchPayload();
    if (payload != null) unawaited(handleNotificationPayload(payload));

    final uri = await HomeWidget.initiallyLaunchedFromHomeWidget();
    if (uri != null) unawaited(handleWidgetUri(uri));
  }

  /// Handle a tap on a home-screen widget. The URI is emitted by the native
  /// widget providers via the home_widget plugin:
  ///   krab://open?imageId=ID     open the all-groups gallery on that image,
  ///                              named as `instanceId/imageId`
  ///   krab://open?action=camera  bring the camera to the front
  Future<void> handleWidgetUri(Uri? uri) async {
    if (uri == null) return;
    debugPrint('Handling widget launch: $uri');
    await _enqueue(() async => _resolveWidgetUri(uri));
  }

  /// Handle a tap on a local notification.
  Future<void> handleNotificationPayload(String payload) async {
    debugPrint('Handling notification tap');
    await _enqueue(() async => _resolveNotificationPayload(payload));
  }

  Future<void> _enqueue(Future<_Destination?> Function() resolve) {
    final queued = _tail.then((_) async {
      try {
        final nav = await _awaitNavigator();
        if (nav == null) return;
        final destination = await resolve();
        if (destination != null) _navigate(nav, destination);
      } catch (e, st) {
        debugPrint('Error handling launch link: $e\n$st');
      }
    });
    _tail = queued;
    return queued;
  }

  /// Waits for the navigator to mount and returns it, or null if it never comes
  /// up
  Future<NavigatorState?> _awaitNavigator() async {
    try {
      return await navigatorReady.future.timeout(const Duration(seconds: 5));
    } on TimeoutException {
      return navigatorKey.currentState;
    }
  }

  Future<_Destination?> _resolveWidgetUri(Uri uri) async {
    // Only act on an authenticated session; otherwise the app just opens
    if (!hasInstance || !anySignedIn) return null;

    if (uri.queryParameters['action'] == 'camera') return const _Home();

    final imageId = uri.queryParameters['imageId'];
    if (imageId == null || imageId.isEmpty) return null;
    return _Gallery(imageId: imageId);
  }

  Future<_Destination?> _resolveNotificationPayload(String payload) async {
    final data = jsonDecode(payload) as Map<String, dynamic>;
    final type = data['type'] as String? ?? '';
    final groupId = data['group_id'] as String? ?? '';
    final imageId = data['image_id'] as String? ?? '';

    // The notification says which instance it came from, open on that server
    final instance =
        instanceForPayload(data.map((k, v) => MapEntry(k, '${v ?? ''}')));

    // Nothing here belongs to a single group: a reaction isn't tied to one at
    // all, and a photo delivered to the user through several groups at once has
    // no one group to open. dispatchImageNotification leaves group_id empty to
    // say so. Both open the all-groups gallery, on the image.
    if (type == 'new_reaction' || (type == 'new_image' && groupId.isEmpty)) {
      if (imageId.isEmpty) return null;
      return _Gallery(
        imageId: instance == null ? imageId : '${instance.id}/$imageId',
      );
    }

    if (groupId.isEmpty || instance == null) return null;
    final groupResponse = await instance.api.getGroupDetails(groupId);
    if (!groupResponse.success || groupResponse.data == null) return null;

    return _Gallery(
      group: groupResponse.data!,
      imageId: imageId,
      openComments: _commentTypes.contains(type),
    );
  }

  void _navigate(NavigatorState nav, _Destination destination) {
    nav.popUntil((route) => route.isFirst);
    switch (destination) {
      case _Home():
        return;
      case _Gallery(:final group, :final imageId, :final openComments):
        nav.push(MaterialPageRoute(
          settings: const RouteSettings(name: GroupsPage.routeName),
          builder: (_) => const GroupsPage(),
        ));
        nav.push(MaterialPageRoute(
          builder: (_) => ImageFeedPage(
            group: group,
            imageId: imageId,
            openComments: openComments,
          ),
        ));
    }
  }
}
