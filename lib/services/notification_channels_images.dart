part of 'notification_channels.dart';

/// Add a copy to the ones a merged notification already stands for.
String mergeCoveredImageIds(String existing, String arriving) {
  final ids = <String>[];
  for (final id in [...existing.split(','), arriving]) {
    final trimmed = id.trim();
    if (trimmed.isNotEmpty && !ids.contains(trimmed)) ids.add(trimmed);
  }
  return ids.join(',');
}

/// Fold a newly delivered set of group names into the ones already named by a
/// notification on screen.
String mergeGroupsDisplay(String existing, String arriving) {
  final names = <String>[];
  for (final name in [...existing.split(', '), ...arriving.split(', ')]) {
    final trimmed = name.trim();
    if (trimmed.isNotEmpty && !names.contains(trimmed)) names.add(trimmed);
  }
  return names.join(', ');
}

({String groupsDisplay, String imageIds, String? tapGroupId})
    mergeImageNotification({
  required ShownImageNotification? earlier,
  required String arrivingGroups,
  required String arrivingImageId,
  required String? tapGroupId,
}) {
  if (earlier == null) {
    return (
      groupsDisplay: arrivingGroups,
      imageIds: arrivingImageId,
      tapGroupId: tapGroupId,
    );
  }

  final groups = mergeGroupsDisplay(earlier.groupsDisplay, arrivingGroups);
  final ids = mergeCoveredImageIds(earlier.imageIds, arrivingImageId);

  final widened = groups != arrivingGroups ||
      ids != arrivingImageId ||
      earlier.tapGroupId != (tapGroupId ?? '');

  return (
    groupsDisplay: groups,
    imageIds: ids,
    tapGroupId: widened ? null : tapGroupId,
  );
}

Future<void> dispatchImageNotification(
    KrabInstance instance, Map<String, dynamic> data) async {
  final groupId = data['group_id'] ?? '';
  final imageId = data['image_id'] ?? '';

  if (groupId.isEmpty || imageId.isEmpty) {
    debugPrint('Notify: missing group_id/image_id, dropping');
    return;
  }

  final ctx = await instance.api.getImageNotificationContext(imageId);
  if (!ctx.success || ctx.data == null) {
    debugPrint(
        'Notify: no context for image $imageId (${ctx.error}), dropping');
    return;
  }

  // Every group the image is in that the user can see.
  final rawGroups = (ctx.data!['groups'] as List?) ?? const [];
  final groups = rawGroups
      .whereType<Map>()
      .map((g) => (
            id: (g['id'] as String?) ?? '',
            name: (g['name'] as String?) ?? '',
          ))
      .where((g) => g.id.isNotEmpty && g.name.isNotEmpty)
      .toList();
  if (groups.isEmpty) {
    debugPrint('Notify: image $imageId is in no group you can see, dropping');
    return;
  }

  final batch = ((data['group_ids'] as String?) ?? '')
      .split(',')
      .where((s) => s.isNotEmpty)
      .toSet();
  var delivered = batch.isEmpty
      ? groups
      : groups.where((g) => batch.contains(g.id)).toList();
  if (delivered.isEmpty) delivered = groups;

  // Drop muted groups; only suppress the notification if every group is muted.
  final unmuted = <({String id, String name})>[];
  for (final g in delivered) {
    if (!await UserPreferences.isGroupMuted(instance.id, g.id)) unmuted.add(g);
  }
  if (unmuted.isEmpty) {
    debugPrint('Notify: every group for image $imageId is muted, dropping');
    return;
  }

  final bundle =
      unmuted.firstWhere((g) => g.id == groupId, orElse: () => unmuted.first);
  final groupsDisplay = unmuted.map((g) => g.name).join(', ');

  final senderId = (ctx.data!['sender_id'] as String?) ?? '';
  var senderUsername = (ctx.data!['sender_username'] as String?) ?? '';
  if (senderUsername.isEmpty) senderUsername = 'Someone';
  final imageDescription = (ctx.data!['description'] as String?) ?? '';

  final media = await _notificationMedia(instance, senderId, imageId);
  await showImageNotification(
    instance: instance,
    groupId: bundle.id,
    groupName: bundle.name,
    groupsDisplay: groupsDisplay,
    batchKey: imageBatchKey(delivered.map((g) => g.id)),
    shareId: (ctx.data!['share_id'] as String?) ?? '',
    tapGroupId: unmuted.length == 1 ? bundle.id : null,
    senderUsername: senderUsername,
    imageId: imageId,
    imageDescription: imageDescription,
    createdAt: _eventTime(ctx.data!['created_at']),
    senderAvatarBytes: media.avatar,
    imageBytes: media.image,
  );
}

Future<void> showImageNotification({
  required KrabInstance instance,
  required String groupId,
  required String groupName,
  required String senderUsername,
  required String imageId,
  String? groupsDisplay,

  /// The group a tap should open. Null when the photo reached the user through
  /// more than one group, in which case the tap opens the cross-group feed.
  String? tapGroupId,
  String batchKey = '',
  String? shareId,
  String imageDescription = '',
  DateTime? createdAt,
  Uint8List? senderAvatarBytes,
  Uint8List? imageBytes,
}) =>
    ShownImageNotifications.instance.serialized(() => _showImageNotification(
          instance: instance,
          groupId: groupId,
          groupName: groupName,
          senderUsername: senderUsername,
          imageId: imageId,
          groupsDisplay: groupsDisplay,
          tapGroupId: tapGroupId,
          batchKey: batchKey,
          shareId: shareId,
          imageDescription: imageDescription,
          createdAt: createdAt,
          senderAvatarBytes: senderAvatarBytes,
          imageBytes: imageBytes,
        ));

Future<void> _showImageNotification({
  required KrabInstance instance,
  required String groupId,
  required String groupName,
  required String senderUsername,
  required String imageId,
  String? groupsDisplay,
  String? tapGroupId,
  String batchKey = '',
  String? shareId,
  String imageDescription = '',
  DateTime? createdAt,
  Uint8List? senderAvatarBytes,
  Uint8List? imageBytes,
}) async {
  await _ensureChannels();

  final id = imageNotificationId(imageId, batchKey: batchKey, shareId: shareId);

  // Lists every group the image was sent to.
  var subText = (groupsDisplay != null && groupsDisplay.isNotEmpty)
      ? groupsDisplay
      : groupName;

  // Every copy this notification now stands for.
  var covered = imageId;

  if (shareId != null && shareId.isNotEmpty) {
    final merged = mergeImageNotification(
      earlier: await _shownImageNotification(id),
      arrivingGroups: subText,
      arrivingImageId: imageId,
      tapGroupId: tapGroupId,
    );
    subText = merged.groupsDisplay;
    covered = merged.imageIds;
    tapGroupId = merged.tapGroupId;
  }

  final eventAt = createdAt ?? DateTime.now();

  await ShownImageNotifications.instance.record(
    id,
    ShownImageNotification(
      groupsDisplay: subText,
      imageIds: covered,
      tapGroupId: tapGroupId ?? '',
      shownAt: DateTime.now(),
      instanceId: instance.id,
      groupId: groupId,
      groupName: groupName,
      senderUsername: senderUsername,
      eventAt: eventAt,
    ),
  );

  await _postImageNotification(
    instance: instance,
    id: id,
    groupId: groupId,
    groupName: groupName,
    senderUsername: senderUsername,
    subText: subText,
    covered: covered,
    tapGroupId: tapGroupId,
    imageId: imageId,
    imageDescription: imageDescription,
    shareId: shareId,
    eventAt: eventAt,
    senderAvatarBytes: senderAvatarBytes,
    imageBytes: imageBytes,
  );

  await _refreshImageBundle(instance, alsoLive: {id});
}

/// Put one image notification on screen, or replace whatever is under id.
Future<void> _postImageNotification({
  required KrabInstance instance,
  required int id,
  required String groupId,
  required String groupName,
  required String senderUsername,
  required String subText,
  required String covered,
  required String? tapGroupId,
  required String imageId,
  required String imageDescription,
  required String? shareId,
  required DateTime eventAt,
  Uint8List? senderAvatarBytes,
  Uint8List? imageBytes,
  bool silent = false,
}) async {
  final compositeBytes = _buildImageLargeIcon(imageBytes, senderAvatarBytes);
  final pfpBytes = _circlePng(senderAvatarBytes);

  String? bigPicturePath;
  if (imageBytes != null) {
    try {
      final dir = await getTemporaryDirectory();
      await _pruneOldNotifImages(dir);
      final f = File('${dir.path}/notif_img_$imageId.jpg');
      await f.writeAsBytes(imageBytes);
      bigPicturePath = f.path;
    } catch (e) {
      debugPrint('notif: failed to cache image: $e');
    }
  }

  final styleInformation = bigPicturePath != null
      ? BigPictureStyleInformation(FilePathAndroidBitmap(bigPicturePath),
          largeIcon: pfpBytes != null ? ByteArrayAndroidBitmap(pfpBytes) : null,
          contentTitle: senderUsername,
          summaryText: imageDescription.isNotEmpty
              ? imageDescription
              : _l10n().no_description)
      : null;

  await _flnp.show(
    id: id,
    title: senderUsername,
    body: _l10n().new_image_notification,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        KrabChannel.photos.id,
        KrabChannel.photos.text.name,
        channelDescription: KrabChannel.photos.text.description,
        icon: _icon,
        subText: subText,
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.social,
        groupKey: imageBundleKey(instance.id),
        when: _whenMillis(eventAt),
        onlyAlertOnce: silent,
        largeIcon: compositeBytes != null
            ? ByteArrayAndroidBitmap(compositeBytes)
            : (pfpBytes != null ? ByteArrayAndroidBitmap(pfpBytes) : null),
        styleInformation: styleInformation,
      ),
    ),
    payload: jsonEncode({
      'type': 'new_image',
      'instance_url': instance.url,
      'image_id': imageId,
      'group_id': tapGroupId ?? '',
      'share_id': shareId ?? '',
      'groups_display': subText,
      'image_ids': covered,
    }),
  );
}

/// Carry an edited description into the notifications already showing this
/// image.
Future<void> updateImageNotificationDescription(
  KrabInstance instance,
  String imageId, {
  String? shareId,
}) async {
  if (imageId.isEmpty) return;
  await _ensureChannels();

  final candidates = <int>{
    imageNotificationId(imageId),
    if (shareId != null && shareId.isNotEmpty)
      imageNotificationId(imageId, shareId: shareId),
    ...await ShownImageNotifications.instance.idsCovering(imageId),
  };

  final live = await _activeNotificationIds();
  if (live == null) {
    debugPrint('notif: cannot tell what is on screen, leaving it as it is');
    return;
  }

  final showing = candidates.where(live.contains).toList();
  if (showing.isEmpty) return;

  final ctx = await instance.api.getImageNotificationContext(imageId);
  if (!ctx.success || ctx.data == null) {
    debugPrint('notif: no context for reworded image $imageId (${ctx.error})');
    return;
  }

  var senderUsername = (ctx.data!['sender_username'] as String?) ?? '';
  if (senderUsername.isEmpty) senderUsername = 'Someone';
  final description = (ctx.data!['description'] as String?) ?? '';
  final senderId = (ctx.data!['sender_id'] as String?) ?? '';
  final contextShareId = (ctx.data!['share_id'] as String?) ?? shareId ?? '';
  final createdAt = _eventTime(ctx.data!['created_at']);

  final groups = ((ctx.data!['groups'] as List?) ?? const [])
      .whereType<Map>()
      .map((g) => (
            id: (g['id'] as String?) ?? '',
            name: (g['name'] as String?) ?? '',
          ))
      .where((g) => g.id.isNotEmpty && g.name.isNotEmpty)
      .toList();

  final media = await _notificationMedia(instance, senderId, imageId);

  for (final id in showing) {
    final record = await ShownImageNotifications.instance.read(id);
    if (record == null) continue;

    final bundle = record.groupId.isNotEmpty
        ? (id: record.groupId, name: record.groupName)
        : groups
                .where((g) => g.id == record.tapGroupId)
                .map((g) => (id: g.id, name: g.name))
                .firstOrNull ??
            (groups.isNotEmpty
                ? (id: groups.first.id, name: groups.first.name)
                : null);
    if (bundle == null) {
      debugPrint('notif: no group to repost $id under, leaving it as it is');
      continue;
    }

    await _postImageNotification(
      instance: instance,
      id: id,
      groupId: bundle.id,
      groupName: bundle.name,
      senderUsername: senderUsername,
      subText: record.groupsDisplay,
      covered: record.imageIds,
      tapGroupId: record.tapGroupId.isEmpty ? null : record.tapGroupId,
      imageId: imageId,
      imageDescription: description,
      shareId: contextShareId,
      eventAt: createdAt ?? record.eventAt,
      senderAvatarBytes: media.avatar,
      imageBytes: media.image,
      silent: true,
    );
  }
}

/// What an image notification still on screen is saying, if any.
Future<ShownImageNotification?> _shownImageNotification(int id) async {
  final recorded = await ShownImageNotifications.instance.read(id);
  if (recorded == null) return null;

  final live = await _activeNotificationIds();
  // Unknown: trust the record.
  if (live != null && !live.contains(id)) {
    await ShownImageNotifications.instance.forget([id]);
    return null;
  }
  return recorded;
}

/// Dismiss a deleted image's notifications and drop its cached big-picture file.
Future<void> cancelImageNotification(
  KrabInstance instance,
  String imageId, {
  String? shareId,
}) async {
  await _ensureChannels();

  final photoIds = <int>{
    imageNotificationId(imageId),
    if (shareId != null && shareId.isNotEmpty)
      imageNotificationId(imageId, shareId: shareId),
    ...await ShownImageNotifications.instance.idsCovering(imageId),
  };
  final threadIds = await CommentThreads.instance.idsForImage(imageId);
  final reactionId = reactionNotificationId(imageId);

  // The bundles these were sitting in, read before the records go, so their
  // summaries can be brought back in line afterwards.
  final bundles = <({String groupId, String groupName})>{};
  final photos = await ShownImageNotifications.instance.readAll();
  for (final id in photoIds) {
    final record = photos[id];
    if (record != null && record.groupId.isNotEmpty) {
      bundles.add((groupId: record.groupId, groupName: record.groupName));
    }
  }
  final threads = await CommentThreads.instance.readAll();
  for (final id in threadIds) {
    final thread = threads[id];
    if (thread != null && thread.groupId.isNotEmpty) {
      bundles.add((groupId: thread.groupId, groupName: thread.groupName));
    }
  }

  for (final id in {...photoIds, ...threadIds, reactionId}) {
    await _flnp.cancel(id: id);
  }
  await ShownImageNotifications.instance.forget(photoIds);
  await CommentThreads.instance.forget(threadIds);
  await ReactionTallies.instance.forget([reactionId]);

  await _refreshImageBundle(instance);
  await _refreshCommentBundle(instance);
  await _refreshReactionsBundle(instance);

  try {
    final dir = await getTemporaryDirectory();
    final f = File('${dir.path}/notif_img_$imageId.jpg');
    if (await f.exists()) await f.delete();
  } catch (_) {}
}
