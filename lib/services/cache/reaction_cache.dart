import 'package:krab/models/reaction.dart';
import 'package:krab/services/api/supabase.dart';
import 'package:krab/services/cache/bounded_cache.dart';

/// Cached reaction tallies per image, so swiping between images shows them
/// immediately instead of flashing empty.
final _reactions = BoundedCache<List<ReactionSummary>>(200);

/// Fetch an image's reaction tally and refresh the cache. Returns null on
/// failure. Also used by the gallery to warm neighbors before they're swiped
/// to.
Future<List<ReactionSummary>?> fetchImageReactions(String imageId) async {
  final response = await getImageReactions(imageId);
  if (!response.success || response.data == null) return null;
  final list = response.data!
      .map((e) => ReactionSummary.fromJson(e as Map<String, dynamic>))
      .toList();
  _reactions[imageId] = list;
  return list;
}

/// The tally held for an image, or an empty list when none has been loaded.
List<ReactionSummary> cachedReactions(String imageId) =>
    _reactions[imageId] ?? const [];

/// Record a tally, including an optimistic one the server hasn't confirmed.
void cacheReactions(String imageId, List<ReactionSummary> reactions) =>
    _reactions[imageId] = reactions;

/// The cached total reaction count for an image, or null if it hasn't
/// been loaded yet.
int? cachedReactionTotal(String imageId) =>
    _reactions[imageId]?.fold<int>(0, (sum, r) => sum + r.count);

/// Forget everything. Called on logout.
void clearReactionCache() => _reactions.clear();
