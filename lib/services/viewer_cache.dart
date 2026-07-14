import 'package:krab/models/group.dart';
import 'package:krab/services/api/supabase.dart';

/// How many images to keep.
const int _maxCachedImages = 200;

final Map<String, List<Group>> _postedInGroups = {};
final Map<String, bool> _moderatedGroups = {};

/// The groups an image was shared to that the current user can see.
Future<List<Group>?> fetchPostedInGroups(String imageId) async {
  final cached = _postedInGroups[imageId];
  if (cached != null) return cached;

  final response = await getImageGroups(imageId);
  if (!response.success || response.data == null) return null;

  final groups = await Future.wait((response.data!).map((e) async {
    final map = e as Map<String, dynamic>;
    final id = map['group_id']?.toString() ?? '';
    return Group(
      id: id,
      name: map['group_name']?.toString() ?? '',
      iconUrl: await resolveGroupIconUrl(id),
      createdAt: '',
    );
  }));

  // Dart maps keep insertion order, so the oldest key is the first one.
  _postedInGroups[imageId] = groups;
  while (_postedInGroups.length > _maxCachedImages) {
    _postedInGroups.remove(_postedInGroups.keys.first);
  }
  return groups;
}

/// The cached group list for an image, or null if it hasn't been loaded.
List<Group>? cachedPostedInGroups(String imageId) => _postedInGroups[imageId];

/// Forget an image's cached groups so the next fetch reflects a change.
void invalidatePostedInGroups(String imageId) {
  _postedInGroups.remove(imageId);
}

/// Whether the user owns or administers groupId, and may remove other people's
/// photos from it.
Future<bool> canModerateGroup(String groupId) async {
  final cached = _moderatedGroups[groupId];
  if (cached != null) return cached;

  final res = await isGroupAdminOrOwner(groupId);
  if (!res.success || res.data == null) return false;
  _moderatedGroups[groupId] = res.data!;
  return res.data!;
}

/// Forget everything. Called on logout.
void clearViewerCaches() {
  _postedInGroups.clear();
  _moderatedGroups.clear();
}
