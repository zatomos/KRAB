part of 'notification_channels.dart';

/// The summaries that head a bundle.
Future<void> _refreshImageBundle(
  KrabInstance instance, {
  Set<int> alsoLive = const {},
}) async {
  final onScreen = await _onScreen(alsoLive);
  final l10n = _l10n();
  final children = <BundleChild>[];

  final photos = await ShownImageNotifications.instance.readAll();
  for (final entry in photos.entries) {
    final record = entry.value;
    if (record.instanceId != instance.id) continue;
    if (onScreen != null && !onScreen.contains(entry.key)) continue;
    children.add(BundleChild(
      id: entry.key,
      kind: BundleKind.image,
      line: '${record.senderUsername} · ${record.groupsDisplay}',
      at: record.eventAt,
    ));
  }

  final bundleKey = imageBundleKey(instance.id);
  await _postBundleSummary(
    id: bundleSummaryId(bundleKey),
    bundleKey: bundleKey,
    channel: KrabChannel.photos,
    title: l10n.channel_photos,
    summary: summarizeBundle(children),
    payload: jsonEncode({
      'type': 'images_summary',
      'instance_url': instance.url,
    }),
  );
}

Future<void> _refreshCommentBundle(
  KrabInstance instance, {
  Set<int> alsoLive = const {},
}) async {
  final onScreen = await _onScreen(alsoLive);
  final children = <BundleChild>[];

  final threads = await CommentThreads.instance.readAll();
  for (final entry in threads.entries) {
    final thread = entry.value;
    if (thread.instanceId != instance.id) continue;
    if (onScreen != null && !onScreen.contains(entry.key)) continue;
    if (thread.messages.isEmpty) continue;
    final newest = thread.messages.last;
    children.add(BundleChild(
      id: entry.key,
      kind: BundleKind.comment,
      line: '${newest.authorUsername}: ${newest.text}',
      at: newest.at,
      count: thread.messages.length,
    ));
  }

  final bundleKey = commentBundleKey(instance.id);
  await _postBundleSummary(
    id: bundleSummaryId(bundleKey),
    bundleKey: bundleKey,
    channel: KrabChannel.comments,
    title: _l10n().channel_comments,
    summary: summarizeBundle(children),
    payload: jsonEncode({
      'type': 'comments_summary',
      'instance_url': instance.url,
    }),
  );
}

/// What the system says is on screen, plus what was just posted.
Future<Set<int>?> _onScreen(Set<int> alsoLive) async {
  final live = await _activeNotificationIds();
  if (live == null) return null;
  return {...live, ...alsoLive};
}

Future<void> _refreshReactionsBundle(
  KrabInstance instance, {
  Set<int> alsoLive = const {},
}) async {
  final onScreen = await _onScreen(alsoLive);

  final children = <BundleChild>[];
  final tallies = await ReactionTallies.instance.readAll();
  for (final entry in tallies.entries) {
    final tally = entry.value;
    if (tally.instanceId != instance.id) continue;
    if (onScreen != null && !onScreen.contains(entry.key)) continue;
    final newest = tally.newestFirst.firstOrNull;
    if (newest == null) continue;
    children.add(BundleChild(
      id: entry.key,
      kind: BundleKind.reaction,
      line: '${newest.reactorUsername} ${newest.emoji}',
      at: newest.at,
      count: tally.reactions.length,
    ));
  }

  final bundleKey = reactionBundleKey(instance.id);
  await _postBundleSummary(
    id: bundleSummaryId(bundleKey),
    bundleKey: bundleKey,
    channel: KrabChannel.reactions,
    title: _l10n().reactions_title,
    summary: summarizeBundle(children),
    payload: jsonEncode({
      'type': 'reactions_summary',
      'instance_url': instance.url,
    }),
  );
}

/// Post the notification that heads a bundle, or take it down when the bundle
/// no longer needs one.
Future<void> _postBundleSummary({
  required int id,
  required String bundleKey,
  required KrabChannel channel,
  required String title,
  required BundleSummary summary,
  required String payload,
}) async {
  if (!summary.isWorthPosting) {
    await _flnp.cancel(id: id);
    return;
  }

  final l10n = _l10n();
  final body = bundleSummaryText(
    summary,
    images: l10n.notification_image_count,
    comments: l10n.notification_comment_count,
    reactions: l10n.notification_reaction_count,
  );

  await _flnp.show(
    id: id,
    title: title,
    body: body,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        channel.id,
        channel.text.name,
        channelDescription: channel.text.description,
        icon: _icon,
        importance: channel.importance,
        priority: Priority.high,
        category: AndroidNotificationCategory.social,
        groupKey: bundleKey,
        setAsGroupSummary: true,
        groupAlertBehavior: GroupAlertBehavior.children,
        onlyAlertOnce: true,
        number: summary.total,
        styleInformation: InboxStyleInformation(
          summary.lines,
          contentTitle: title,
          summaryText: body,
        ),
      ),
    ),
    payload: payload,
  );
}
