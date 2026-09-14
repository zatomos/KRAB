part of 'notification_channels.dart';

typedef CommentTarget = ({String imageId, String groupId});

/// Shows the notification for a comment push, unless its thread is already on
/// screen, and reports what the comment was about so the open app can update.
Future<CommentTarget?> dispatchCommentNotification(
    KrabInstance instance, Map<String, dynamic> data, String type) async {
  final commentId = data['comment_id'] ?? '';
  if (commentId.isEmpty) return null;

  // The push carries only the id: everything shown is read back from the
  // instance, so the payload itself never holds anyone's words.
  final ctx = await instance.api.getCommentNotificationContext(commentId);
  if (!ctx.success || ctx.data == null) return null;
  final d = ctx.data!;

  final groupId = (d['group_id'] as String?) ?? '';
  final imageId = (d['image_id'] as String?) ?? '';
  final commenterId = (d['commenter_id'] as String?) ?? '';
  final groupName = (d['group_name'] as String?) ?? '';
  final commentText = (d['comment_text'] as String?) ?? '';
  final uploaderUsername = d['uploader_username'] as String?;
  final createdAt = _eventTime(d['created_at']);
  var commenterUsername = (d['commenter_username'] as String?) ?? '';

  final uploaderId = (d['uploader_id'] as String?) ?? '';
  final parentAuthorId = (d['parent_author_id'] as String?) ?? '';
  final uploaderIsMe = d['uploader_is_me'] == true;
  final uploaderIsCommenter =
      uploaderId.isNotEmpty && uploaderId == commenterId;
  final parentAuthorIsMe = d['parent_author_is_me'] == true;
  final parentAuthorIsUploader =
      parentAuthorId.isNotEmpty && parentAuthorId == uploaderId;
  final parentAuthorUsername = (d['parent_author_username'] as String?) ?? '';

  if (groupId.isEmpty || groupName.isEmpty) return null;

  // Everything below only decides whether to raise a notification.
  final target = (imageId: imageId, groupId: groupId);

  if (await UserPreferences.isGroupMuted(instance.id, groupId)) return target;

  // The comments sheet is open on this very thread
  if (ViewingState.instance.isShowingComments(
      instanceId: instance.id, imageId: imageId, groupId: groupId)) {
    debugPrint('Push: comment thread is on screen, not notifying');
    return target;
  }

  if (commenterUsername.isEmpty) commenterUsername = 'Someone';

  final media = await _notificationMedia(instance, commenterId, imageId);
  await showCommentNotification(
    instance: instance,
    groupId: groupId,
    groupName: groupName,
    commentId: commentId,
    commenterId: commenterId,
    commenterUsername: commenterUsername,
    commentText: commentText,
    createdAt: createdAt,
    imageId: imageId,
    type: type,
    commenterAvatarBytes: media.avatar,
    uploaderUsername: uploaderUsername,
    uploaderIsMe: uploaderIsMe,
    uploaderIsCommenter: uploaderIsCommenter,
    parentAuthorUsername: parentAuthorUsername,
    parentAuthorIsMe: parentAuthorIsMe,
    parentAuthorIsUploader: parentAuthorIsUploader,
    imageBytes: media.image,
  );
  return target;
}

String commentThreadTitle({
  required bool uploaderIsMe,
  required String uploaderUsername,
}) {
  final l10n = _l10n();
  if (uploaderIsMe) return l10n.notification_your_image;
  return uploaderUsername.isNotEmpty
      ? l10n.notification_someone_image(uploaderUsername)
      : l10n.comments;
}

Future<void> showCommentNotification({
  required KrabInstance instance,
  required String groupId,
  required String groupName,
  required String commenterUsername,
  required String commentText,
  required String imageId,
  required String type,
  String commentId = '',
  String commenterId = '',
  DateTime? createdAt,
  Uint8List? commenterAvatarBytes,
  String? uploaderUsername,
  bool uploaderIsMe = false,
  bool uploaderIsCommenter = false,
  String parentAuthorUsername = '',
  bool parentAuthorIsMe = false,
  bool parentAuthorIsUploader = false,
  Uint8List? imageBytes,
}) =>
    CommentThreads.instance.serialized(() => _showCommentNotification(
          instance: instance,
          groupId: groupId,
          groupName: groupName,
          commenterUsername: commenterUsername,
          commentText: commentText,
          imageId: imageId,
          type: type,
          commentId: commentId,
          commenterId: commenterId,
          createdAt: createdAt,
          commenterAvatarBytes: commenterAvatarBytes,
          uploaderUsername: uploaderUsername,
          uploaderIsMe: uploaderIsMe,
          uploaderIsCommenter: uploaderIsCommenter,
          parentAuthorUsername: parentAuthorUsername,
          parentAuthorIsMe: parentAuthorIsMe,
          parentAuthorIsUploader: parentAuthorIsUploader,
          imageBytes: imageBytes,
        ));

Future<void> _showCommentNotification({
  required KrabInstance instance,
  required String groupId,
  required String groupName,
  required String commenterUsername,
  required String commentText,
  required String imageId,
  required String type,
  String commentId = '',
  String commenterId = '',
  DateTime? createdAt,
  Uint8List? commenterAvatarBytes,
  String? uploaderUsername,
  bool uploaderIsMe = false,
  bool uploaderIsCommenter = false,
  String parentAuthorUsername = '',
  bool parentAuthorIsMe = false,
  bool parentAuthorIsUploader = false,
  Uint8List? imageBytes,
}) async {
  await _ensureChannels();

  // Every comment on one image in one group reads as one conversation.
  final threaded = imageId.isNotEmpty;
  final id = threaded
      ? commentThreadNotificationId(groupId: groupId, imageId: imageId)
      : unidentifiedNotificationId('comment');

  final arriving = ThreadMessage(
    authorId: commenterId,
    authorUsername: commenterUsername,
    text: commentText,
    at: createdAt ?? DateTime.now(),
  );

  final earlier = threaded ? await _liveCommentThread(id) : null;
  final thread = (earlier ??
          CommentThread(
            instanceId: instance.id,
            groupId: groupId,
            groupName: groupName,
            imageId: imageId,
            messages: const [],
            shownAt: DateTime.now(),
            uploaderUsername: uploaderUsername ?? '',
            uploaderIsMe: uploaderIsMe,
          ))
      .withMessage(arriving);

  if (threaded) await CommentThreads.instance.record(id, thread);

  final l10n = _l10n();

  final body = parentAuthorIsMe
      ? l10n.replied_to_you_notification(commentText)
      : (parentAuthorUsername.isNotEmpty
          ? l10n.replied_to_someone_notification(
              parentAuthorUsername, commentText)
          : l10n.commented_notification(commentText));

  final messages = thread.messages;
  final lines = [
    for (final message in messages) '${message.authorUsername}: ${message.text}'
  ];

  await _flnp.show(
    id: id,
    title: commenterUsername,
    body: body,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        KrabChannel.comments.id,
        KrabChannel.comments.text.name,
        channelDescription: KrabChannel.comments.text.description,
        icon: _icon,
        subText: '$groupName · '
            '${commentThreadTitle(uploaderIsMe: uploaderIsMe, uploaderUsername: uploaderUsername ?? '')}',
        importance: Importance.high,
        priority: Priority.high,
        category: AndroidNotificationCategory.social,
        groupKey: commentBundleKey(instance.id),
        when: _whenMillis(messages.last.at),
        number: messages.length,
        largeIcon: _largeIcon(imageBytes, commenterAvatarBytes),
        styleInformation: messages.length == 1
            ? BigTextStyleInformation(commentText)
            : InboxStyleInformation(
                lines,
                contentTitle: commenterUsername,
                summaryText: l10n.notification_comment_count(messages.length),
              ),
      ),
    ),
    payload: jsonEncode({
      'type': type,
      'instance_url': instance.url,
      'image_id': imageId,
      'group_id': groupId,
      'comment_id': commentId,
    }),
  );

  await _refreshCommentBundle(instance, alsoLive: {id});
}

/// Take an image's comment notifications off the screen because the user has
/// opened its comments.
///
/// [groupId] confines this to the one group's thread, which is all a gallery
/// opened inside that group shows; the threads the same image has under other
/// groups stay, since the user has not seen those. Left null -- the cross-group
/// feed, whose sheet gathers every group's comments -- every thread about the
/// image goes.
Future<void> dismissCommentNotificationsOnOpen(
  KrabInstance instance,
  String imageId, {
  String? groupId,
}) async {
  if (imageId.isEmpty) return;
  await _ensureChannels();

  final ids = await commentNotificationIdsToDismiss(imageId, groupId: groupId);
  if (ids.isEmpty) return;

  for (final id in ids) {
    await _flnp.cancel(id: id);
  }
  await CommentThreads.instance.forget(ids);

  await _refreshCommentBundle(instance);
}

/// Which comment notifications an opened comments sheet accounts for.
///
/// Named a group, that is the one thread for this image in that group, and
/// nothing else: the image's threads under other groups have not been read.
/// Named none, it is every thread about the image, which is what the
/// cross-group sheet puts in front of the user.
@visibleForTesting
Future<List<int>> commentNotificationIdsToDismiss(
  String imageId, {
  String? groupId,
}) async {
  if (imageId.isEmpty) return const [];
  if (groupId != null && groupId.isNotEmpty) {
    return [commentThreadNotificationId(groupId: groupId, imageId: imageId)];
  }
  return CommentThreads.instance.idsForImage(imageId);
}

/// The thread under this id, or null when nothing of it is on screen any more.
Future<CommentThread?> _liveCommentThread(int id) async {
  final recorded = await CommentThreads.instance.read(id);
  if (recorded == null) return null;

  final live = await _activeNotificationIds();
  // Unknown: trust the record
  if (live != null && !live.contains(id)) {
    await CommentThreads.instance.forget([id]);
    return null;
  }
  return recorded;
}
