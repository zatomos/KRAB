/// A stable, non-negative notification id derived from a string.
int notificationIdFrom(String source) {
  var hash = 0x811c9dc5; // FNV-1a 32-bit offset basis
  for (final unit in source.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash & 0x7FFFFFFF;
}

/// Stable notification id for one delivery of an image.
int imageNotificationId(String imageId,
        {String batchKey = '', String? shareId}) =>
    notificationIdFrom(shareId != null && shareId.isNotEmpty
        ? shareId
        : (batchKey.isEmpty ? imageId : '$imageId|$batchKey'));

/// Stable notification id for the comments on one photo in one group.
int commentThreadNotificationId(
        {required String groupId, required String imageId}) =>
    notificationIdFrom('comments|$groupId|$imageId');

/// Stable notification id for the reactions to one photo.
int reactionNotificationId(String imageId) =>
    notificationIdFrom('reaction|$imageId');

/// Identifies one delivery of a photo.
String imageBatchKey(Iterable<String> groupIds) =>
    (groupIds.toList()..sort()).join(',');

/// The bundle images collapse into.
String imageBundleKey(String instanceId) => 'krab|$instanceId|#images';

/// The bundle comment threads collapse into.
String commentBundleKey(String instanceId) => 'krab|$instanceId|#comments';

/// The bundle reactions collapse into.
String reactionBundleKey(String instanceId) => 'krab|$instanceId|#reactions';

/// The notification that heads a bundle.
int bundleSummaryId(String bundleKey) =>
    notificationIdFrom('summary|$bundleKey');

/// Id for an event that cannot be identified.
int unidentifiedNotificationId(String kind) =>
    notificationIdFrom('unidentified|$kind');
