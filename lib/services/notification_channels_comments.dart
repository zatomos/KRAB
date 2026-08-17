part of 'notification_channels.dart';

Future<void> dispatchCommentNotification(
    KrabInstance instance, Map<String, dynamic> data, String type) async {
  final commentId = data['comment_id'] ?? '';

  String groupId;
  String imageId;
  String commenterId;
  String groupName;
  String commenterUsername;
  String commentText;
  String? uploaderUsername;
  DateTime? createdAt;

  var uploaderIsMe = false;
  var uploaderIsCommenter = false;
  var parentAuthorIsMe = false;
  var parentAuthorIsUploader = false;
  var parentAuthorUsername = '';

  if (commentId.isNotEmpty) {
    final ctx = await instance.api.getCommentNotificationContext(commentId);
    if (!ctx.success || ctx.data == null) return;
    final d = ctx.data!;
    groupId = (d['group_id'] as String?) ?? '';
    imageId = (d['image_id'] as String?) ?? '';
    commenterId = (d['commenter_id'] as String?) ?? '';
    groupName = (d['group_name'] as String?) ?? '';
    commenterUsername = (d['commenter_username'] as String?) ?? '';
    commentText = (d['comment_text'] as String?) ?? '';
    uploaderUsername = d['uploader_username'] as String?;
    createdAt = _eventTime(d['created_at']);

    final uploaderId = (d['uploader_id'] as String?) ?? '';
    final parentAuthorId = (d['parent_author_id'] as String?) ?? '';
    uploaderIsMe = d['uploader_is_me'] == true;
    uploaderIsCommenter = uploaderId.isNotEmpty && uploaderId == commenterId;
    parentAuthorIsMe = d['parent_author_is_me'] == true;
    parentAuthorIsUploader =
        parentAuthorId.isNotEmpty && parentAuthorId == uploaderId;
    parentAuthorUsername = (d['parent_author_username'] as String?) ?? '';
  } else {
    // Legacy plaintext payload. TODO: remove
    groupId = data['group_id'] ?? '';
    imageId = data['image_id'] ?? '';
    commenterId = data['commenter_id'] ?? '';
    final groupResponse = await instance.api.getGroupDetails(groupId);
    groupName = (groupResponse.success && groupResponse.data != null)
        ? groupResponse.data!.name
        : '';
    commenterUsername = (data['commenter_username'] as String?) ?? '';
    commentText = (data['comment_text'] as String?) ?? '';
    uploaderUsername = data['uploader_username'] as String?;
    uploaderIsMe = type == 'new_comment';
    parentAuthorIsMe = type == 'comment_reply';
  }

  if (groupId.isEmpty || groupName.isEmpty) return;
  if (await UserPreferences.isGroupMuted(instance.id, groupId)) return;
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
