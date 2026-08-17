part of 'notification_channels.dart';

Future<void> dispatchReactionNotification(
    KrabInstance instance, Map<String, dynamic> data,
    [String type = 'new_reaction']) async {
  final imageId = data['image_id'] ?? '';
  final reactorId = data['reactor_id'] ?? '';
  final emoji = data['emoji'] ?? '';

  if (imageId.isEmpty) return;

  final ctx =
      await instance.api.getReactionNotificationContext(imageId, reactorId);
  if (!ctx.success || ctx.data == null) return;
  final d = ctx.data!;

  var reactorUsername = (d['reactor_username'] as String?) ?? '';
  if (reactorUsername.isEmpty) reactorUsername = 'Someone';

  final uploaderUsername =
      type == 'group_reaction' ? d['uploader_username'] as String? : null;

  final media = await _notificationMedia(instance, reactorId, imageId);
  await showReactionNotification(
    instance: instance,
    reactorUsername: reactorUsername,
    reactorId: reactorId,
    emoji: emoji,
    imageId: imageId,
    uploaderUsername: uploaderUsername,
    reactorAvatarBytes: media.avatar,
    imageBytes: media.image,
  );
}

Future<void> showReactionNotification({
  required KrabInstance instance,
  required String reactorUsername,
  required String emoji,
  required String imageId,
  String reactorId = '',
  String? uploaderUsername,
  Uint8List? reactorAvatarBytes,
  Uint8List? imageBytes,
}) =>
    ReactionTallies.instance.serialized(() => _showReactionNotification(
          instance: instance,
          reactorUsername: reactorUsername,
          emoji: emoji,
          imageId: imageId,
          reactorId: reactorId,
          uploaderUsername: uploaderUsername,
          reactorAvatarBytes: reactorAvatarBytes,
          imageBytes: imageBytes,
        ));

Future<void> _showReactionNotification({
  required KrabInstance instance,
  required String reactorUsername,
  required String emoji,
  required String imageId,
  String reactorId = '',
  String? uploaderUsername,
  Uint8List? reactorAvatarBytes,
  Uint8List? imageBytes,
}) async {
  await _ensureChannels();

  final l10n = _l10n();
  final id = reactionNotificationId(imageId);

  final arriving = ReactionEntry(
    reactorId: reactorId,
    reactorUsername: reactorUsername,
    emoji: emoji,
    at: DateTime.now(),
  );

  final earlier = await _liveReactionTally(id);
  final tally = (earlier ??
          ReactionTally(
            instanceId: instance.id,
            imageId: imageId,
            reactions: const [],
            shownAt: DateTime.now(),
            uploaderUsername: uploaderUsername ?? '',
          ))
      .withReaction(arriving);

  await ReactionTallies.instance.record(id, tally);

  final reactors = tally.newestFirst;
  final lines = [
    for (final reaction in reactors)
      '${reaction.reactorUsername} ${reaction.emoji}'
  ];

  final single = reactors.length == 1;
  final onSomeoneElses = tally.uploaderUsername.isNotEmpty;
  final title = single
      ? reactorUsername
      : (onSomeoneElses
          ? l10n.reactions_on_someone_photo(tally.uploaderUsername)
          : l10n.reactions_on_your_photo);
  final body = single
      ? (onSomeoneElses
          ? l10n.new_reaction_on_someone_notification(
              emoji, tally.uploaderUsername)
          : l10n.new_reaction_on_your_image_notification(emoji))
      : lines.join(', ');

  await _flnp.show(
    id: id,
    title: title,
    body: body,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        KrabChannel.reactions.id,
        KrabChannel.reactions.text.name,
        channelDescription: KrabChannel.reactions.text.description,
        icon: _icon,
        importance: KrabChannel.reactions.importance,
        priority: Priority.low,
        category: AndroidNotificationCategory.social,
        groupKey: reactionBundleKey(instance.id),
        when: _whenMillis(arriving.at),
        number: reactors.length,
        largeIcon: _largeIcon(imageBytes, reactorAvatarBytes),
        styleInformation: single
            ? null
            : InboxStyleInformation(
                lines,
                contentTitle: title,
                summaryText: l10n.notification_reaction_count(reactors.length),
              ),
      ),
    ),
    payload: jsonEncode({
      'type': 'new_reaction',
      'instance_url': instance.url,
      'image_id': imageId
    }),
  );

  await _refreshReactionsBundle(instance, alsoLive: {id});
}

/// The reactions under this id, or null when nothing of it is on screen.
Future<ReactionTally?> _liveReactionTally(int id) async {
  final recorded = await ReactionTallies.instance.read(id);
  if (recorded == null) return null;

  final live = await _activeNotificationIds();
  if (live != null && !live.contains(id)) {
    await ReactionTallies.instance.forget([id]);
    return null;
  }
  return recorded;
}
