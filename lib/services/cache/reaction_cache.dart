import 'package:krab/models/reaction.dart';
import 'package:krab/services/cache/bounded_cache.dart';

/// One instance's reaction tallies per image, so swiping between images shows
/// them immediately instead of flashing empty.
///
/// Per instance: image ids are only meaningful on the server that issued them.
class ReactionCache {
  final BoundedCache<List<ReactionSummary>> _reactions =
      BoundedCache<List<ReactionSummary>>(200);

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
