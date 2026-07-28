import 'package:krab/models/reaction.dart';
import 'package:krab/services/api/krab_api.dart';
import 'package:krab/services/cache/bounded_cache.dart';

/// One instance's reaction tallies per image, so swiping between images shows
/// them immediately instead of flashing empty.
///
/// Per instance: image ids are only meaningful on the server that issued them.
class ReactionCache {
  ReactionCache(this._api);

  final KrabApi _api;
  final BoundedCache<List<ReactionSummary>> _reactions =
      BoundedCache<List<ReactionSummary>>(200);

  /// Fetch an image's reaction tally and refresh the cache. Returns null on
  /// failure. Also used by the gallery to warm neighbors before they're swiped
  /// to.
  Future<List<ReactionSummary>?> fetch(String imageId) async {
    final response = await _api.getImageReactions(imageId);
    if (!response.success || response.data == null) return null;
    final list = response.data!
        .map((e) => ReactionSummary.fromJson(e as Map<String, dynamic>))
        .toList();
    _reactions[imageId] = list;
    return list;
  }

  /// The tally held for an image, or an empty list when none has been loaded.
  List<ReactionSummary> cached(String imageId) =>
      _reactions[imageId] ?? const [];

  /// Record a tally, including an optimistic one the server hasn't confirmed.
  void put(String imageId, List<ReactionSummary> reactions) =>
      _reactions[imageId] = reactions;

  /// The cached total reaction count for an image, or null if it hasn't
  /// been loaded yet.
  int? cachedTotal(String imageId) =>
      _reactions[imageId]?.fold<int>(0, (sum, r) => sum + r.count);

  /// Forget everything. Called on logout.
  void clear() => _reactions.clear();
}
