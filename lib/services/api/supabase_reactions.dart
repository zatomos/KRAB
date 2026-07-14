part of 'supabase.dart';

/// ------------------ REACTION FUNCTIONS ------------------

/// Add or remove the current user's emoji reaction on an image. Returns whether
/// the reaction now exists or was removed.
Future<SupabaseResponse<bool>> toggleReaction(String imageId, String emoji) =>
    _rpc("toggle_reaction",
        params: {"p_image_id": imageId, "p_emoji": emoji},
        errorContext: "toggling reaction",
        parse: (r) => r['reacted'] == true);

/// Per-emoji tally of an image's reactions, across every group the current user
/// can see.
Future<SupabaseResponse<List<dynamic>>> getImageReactions(String imageId) =>
    _rpc("get_image_reactions",
        params: {"p_image_id": imageId},
        errorContext: "loading reactions",
        parse: (r) => (r['reactions'] as List?) ?? []);

/// Who reacted to an image, one entry per (user, emoji), for the reactors sheet.
Future<SupabaseResponse<List<dynamic>>> getImageReactors(String imageId) =>
    _rpc("get_image_reactors",
        params: {"p_image_id": imageId},
        errorContext: "loading reactors",
        parse: (r) => (r['reactors'] as List?) ?? []);
