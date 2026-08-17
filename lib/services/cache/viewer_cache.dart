import 'package:krab/models/group.dart';
import 'package:krab/services/api/krab_api.dart';
import 'package:krab/services/cache/bounded_cache.dart';

/// What the viewer holds about one instance's images: which of its groups a
/// image was posted to, and which of them the user may moderate.
class ViewerCache {
  ViewerCache(this._api);

  final KrabApi _api;
  final BoundedCache<List<Group>> _postedInGroups =
      BoundedCache<List<Group>>(200);
  final Map<String, bool> _moderatedGroups = {};
  final Map<String, Future<List<Group>?>> _inFlight = {};

  /// The groups an image was shared to that the current user can see.
  Future<List<Group>?> fetchPostedInGroups(String imageId) {
    final cached = _postedInGroups[imageId];
    if (cached != null) return Future.value(cached);

    return _inFlight.putIfAbsent(
      imageId,
      () => _fetchPostedInGroups(imageId)
          .whenComplete(() => _inFlight.remove(imageId)),
    );
  }

  Future<List<Group>?> _fetchPostedInGroups(String imageId) async {
    final response = await _api.getImageGroups(imageId);
    if (!response.success || response.data == null) return null;

    final groups = await Future.wait((response.data!).map((e) async {
      final map = e as Map<String, dynamic>;
      final id = map['group_id']?.toString() ?? '';
      return Group(
        instanceId: _api.instanceId,
        id: id,
        name: map['group_name']?.toString() ?? '',
        iconUrl: await _api.resolveGroupIconUrl(id),
        createdAt: '',
      );
    }));

    _postedInGroups[imageId] = groups;
    return groups;
  }

  /// The cached group list for an image, or null if it hasn't been loaded.
  List<Group>? cachedPostedInGroups(String imageId) => _postedInGroups[imageId];

  /// Forget an image's cached groups so the next fetch reflects a change.
  void invalidatePostedInGroups(String imageId) =>
      _postedInGroups.remove(imageId);

  /// Whether the user owns or administers groupId, and may remove other
  /// people's images from it.
  Future<bool> canModerateGroup(String groupId) async {
    final cached = _moderatedGroups[groupId];
    if (cached != null) return cached;

    final res = await _api.isGroupAdminOrOwner(groupId);
    if (!res.success || res.data == null) return false;
    _moderatedGroups[groupId] = res.data!;
    return res.data!;
  }

  /// Forget everything. Called on logout.
  void clear() {
    _postedInGroups.clear();
    _moderatedGroups.clear();
  }
}
