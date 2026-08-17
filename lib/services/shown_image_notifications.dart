import 'package:krab/services/notification_records.dart';

/// What one image notification on screen stands for.
///
/// A photo sent to several servers, or to several groups on one, arrives as one
/// push per sender and all of them land on the same notification id. Each has to
/// fold into what is already showing rather than replace it, so what is showing
/// has to be readable.
class ShownImageNotification {
  const ShownImageNotification({
    required this.groupsDisplay,
    required this.imageIds,
    required this.tapGroupId,
    required this.shownAt,
    this.instanceId = '',
    this.groupId = '',
    this.groupName = '',
    this.senderUsername = '',
    DateTime? eventAt,
  }) : _eventAt = eventAt;

  /// The group names the notification currently lists.
  final String groupsDisplay;

  /// Every copy of the photo it now speaks for, comma separated.
  final String imageIds;

  /// The group a tap opens, empty when it opens the cross-group feed.
  final String tapGroupId;

  final DateTime shownAt;
  final String instanceId;
  final String groupId;
  final String groupName;
  final String senderUsername;

  final DateTime? _eventAt;

  DateTime get eventAt => _eventAt ?? shownAt;

  Map<String, dynamic> toJson() => {
        'groups_display': groupsDisplay,
        'image_ids': imageIds,
        'tap_group_id': tapGroupId,
        'shown_at': shownAt.toIso8601String(),
        if (instanceId.isNotEmpty) 'instance_id': instanceId,
        if (groupId.isNotEmpty) 'group_id': groupId,
        if (groupName.isNotEmpty) 'group_name': groupName,
        if (senderUsername.isNotEmpty) 'sender_username': senderUsername,
        if (_eventAt != null) 'event_at': _eventAt.toIso8601String(),
      };

  static ShownImageNotification? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final shownAt = DateTime.tryParse(raw['shown_at']?.toString() ?? '');
    if (shownAt == null) return null;
    return ShownImageNotification(
      groupsDisplay: raw['groups_display']?.toString() ?? '',
      imageIds: raw['image_ids']?.toString() ?? '',
      tapGroupId: raw['tap_group_id']?.toString() ?? '',
      shownAt: shownAt,
      instanceId: raw['instance_id']?.toString() ?? '',
      groupId: (raw['group_id'] ?? raw['channel_id'])?.toString() ?? '',
      groupName: (raw['group_name'] ?? raw['channel_name'])?.toString() ?? '',
      senderUsername: raw['sender_username']?.toString() ?? '',
      eventAt: DateTime.tryParse(raw['event_at']?.toString() ?? ''),
    );
  }

  /// Whether this notification is speaking for the given copy of a photo.
  bool covers(String imageId) =>
      imageId.isNotEmpty &&
      imageIds.split(',').map((s) => s.trim()).contains(imageId);
}

/// The image notifications this device has posted, by notification id.
class ShownImageNotifications
    extends NotificationRecordStore<ShownImageNotification> {
  ShownImageNotifications._();
  static final ShownImageNotifications instance = ShownImageNotifications._();

  static const String storeKey = 'krab_shown_image_notifications';

  /// Entries older than this are dropped
  static const Duration storeMaxAge = Duration(days: 2);

  @override
  String get prefsKey => storeKey;

  @override
  Duration get maxAge => storeMaxAge;

  @override
  DateTime timestampOf(ShownImageNotification record) => record.shownAt;

  @override
  Map<String, dynamic> toJson(ShownImageNotification record) => record.toJson();

  @override
  ShownImageNotification? fromJson(Object? raw) =>
      ShownImageNotification.fromJson(raw);

  /// The ids of every notification standing for this copy of a photo, so a
  /// deleted photo can be taken off the screen even where it was merged into a
  /// notification another copy started.
  Future<List<int>> idsCovering(String imageId) async {
    if (imageId.isEmpty) return const [];
    final entries = await readAll();
    return [
      for (final entry in entries.entries)
        if (entry.value.covers(imageId)) entry.key
    ];
  }
}
