import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:krab/models/group.dart';
import 'package:krab/models/image_ref.dart';
import 'package:krab/models/reaction.dart';
import 'package:krab/models/shared_image.dart';
import 'package:krab/services/api/krab_api.dart';
import 'package:krab/services/instance/instance_registry.dart';
import 'package:krab/services/instance/krab_instance.dart';
import 'package:krab/services/share_id.dart';
import 'package:krab/services/upload_outbox.dart';

/// Reads and writes one image as a single thing, across every server holding a
/// copy of it.
class SharedImageApi {
  SharedImageApi(this.image);

  final SharedImage image;

  /// The instances still connected that hold a copy, paired with that copy.
  List<({KrabInstance instance, ImageRef copy})> get _present {
    final registry = InstanceRegistry.instance;
    final pairs = <({KrabInstance instance, ImageRef copy})>[];
    for (final copy in image.copies) {
      final instance = registry.byId(copy.instanceId);
      if (instance != null) pairs.add((instance: instance, copy: copy));
    }
    return pairs;
  }

  /// Where a write goes: always the primary copy.

  /// Null when the primary's instance is gone from the registry entirely, in
  /// which case the caller has nothing to write to and should say so.
  ({KrabInstance instance, ImageRef copy})? get writeTarget {
    final present = _present;
    return present.isEmpty ? null : present.first;
  }

  // ---------------------------------------------------------------------------
  // Reactions
  // ---------------------------------------------------------------------------

  /// A tally to show, and where the viewer's own reactions actually live.
  ///
  /// onlyOn narrows this to one server's copy.
  ///
  /// mineByInstance is which emoji the viewer holds on each copy. The copies
  /// can legitimately disagree, since a gallery reacts on its own server alone,
  /// so a write cannot just toggle them all; setReaction needs to know which
  /// ones are already in the state being asked for.
  Future<
      ({
        List<ReactionSummary> tally,
        Map<String, Set<String>> mineByInstance
      })?> reactions({String? onlyOn}) async {
    final copies = onlyOn == null
        ? _present
        : _present.where((p) => p.instance.id == onlyOn).toList();
    if (copies.isEmpty) return null;

    final results = await Future.wait(copies
        .map((pair) => pair.instance.api.getImageReactions(pair.copy.id)));

    final perCopy = <List<ReactionSummary>>[];
    final mine = <String, Set<String>>{};
    var anyAnswered = false;

    for (var i = 0; i < results.length; i++) {
      final response = results[i];
      if (!response.success || response.data == null) continue;
      anyAnswered = true;
      final tally = [
        for (final raw in response.data!)
          ReactionSummary.fromJson(raw as Map<String, dynamic>)
      ];
      perCopy.add(tally);
      mine[copies[i].instance.id] = {
        for (final r in tally)
          if (r.reactedByMe) r.emoji
      };
    }

    final merged = mergeTallies(perCopy, anyAnswered: anyAnswered);
    if (merged == null) return null;
    return (tally: merged, mineByInstance: mine);
  }

  /// Which copies a write has to touch to leave the viewer's reaction [on].
  ///
  /// onlyOn confines the write to one server.Left null every copy is written to.
  ///
  /// A copy already in the wanted state is left out.
  @visibleForTesting
  static List<String> copiesToToggle({
    required List<String> writable,
    required Map<String, Set<String>> mineByInstance,
    required String emoji,
    required bool on,
    String? onlyOn,
  }) {
    final considered =
        onlyOn == null ? writable : writable.where((id) => id == onlyOn);
    return [
      for (final id in considered)
        if ((mineByInstance[id]?.contains(emoji) ?? false) != on) id
    ];
  }

  /// Put the viewer's reaction into a known state, rather than toggling.
  ///
  /// onlyOn is the server the view is about, and the write goes there alone.
  /// From the cross-group feed it is null, and the write reaches every copy.
  ///
  /// mineByInstance comes from reactions: a copy already in the wanted state
  /// is left alone, because the underlying call toggles and would undo it.
  ///
  /// Returns where the viewer's reactions stand afterwards, so the caller can go
  /// again without re-reading.
  Future<SupabaseResponse<Map<String, Set<String>>>> setReaction(
    String emoji, {
    required bool on,
    required Map<String, Set<String>> mineByInstance,
    String? onlyOn,
  }) async {
    final writable = [
      for (final pair in _present)
        if (pair.instance.auth.isLoggedIn) pair
    ];
    if (writable.isEmpty) {
      return const SupabaseResponse(success: false, error: errorServer);
    }

    // What the caller should believe afterwards, copied so the argument is left
    // as it was.
    final updated = {
      for (final entry in mineByInstance.entries)
        entry.key: Set<String>.of(entry.value)
    };

    final wanted = copiesToToggle(
      writable: [for (final p in writable) p.instance.id],
      mineByInstance: mineByInstance,
      emoji: emoji,
      on: on,
      onlyOn: onlyOn,
    ).toSet();
    final needed =
        writable.where((p) => wanted.contains(p.instance.id)).toList();
    // Already as asked everywhere that matters.
    if (needed.isEmpty) return SupabaseResponse(success: true, data: updated);

    final results = await Future.wait(needed
        .map((pair) => pair.instance.api.toggleReaction(pair.copy.id, emoji)));

    final failed = [
      for (var i = 0; i < results.length; i++)
        if (!results[i].success) needed[i].instance.id
    ];
    if (failed.length == results.length) {
      return SupabaseResponse(
        success: false,
        error: results.first.error,
        offline: results.every((r) => r.offline),
      );
    }
    if (failed.isNotEmpty) {
      debugPrint('SharedImage: reaction not written to ${failed.join(', ')}');
    }

    // Only the copies that actually took it.
    for (var i = 0; i < needed.length; i++) {
      if (!results[i].success) continue;
      final set = updated.putIfAbsent(needed[i].instance.id, () => <String>{});
      if (on) {
        set.add(emoji);
      } else {
        set.remove(emoji);
      }
    }
    return SupabaseResponse(success: true, data: updated);
  }

  /// Add up one tally per copy, counting the viewer once.
  static List<ReactionSummary>? mergeTallies(
    Iterable<List<ReactionSummary>> perCopy, {
    required bool anyAnswered,
  }) {
    if (!anyAnswered) return null;

    final totals = <String, ReactionSummary>{};
    // How many copies reported the viewer's own reaction, per emoji.
    final mineOn = <String, int>{};

    for (final tally in perCopy) {
      for (final summary in tally) {
        if (summary.reactedByMe) {
          mineOn[summary.emoji] = (mineOn[summary.emoji] ?? 0) + 1;
        }
        final running = totals[summary.emoji];
        totals[summary.emoji] = running == null
            ? summary
            : running.copyWith(
                count: running.count + summary.count,
                // Reacted here or there is reacted.
                reactedByMe: running.reactedByMe || summary.reactedByMe,
              );
      }
    }

    final merged = <ReactionSummary>[];
    for (final entry in totals.entries) {
      // A tap in the cross-group feed wrote the same reaction to every copy, so
      // all but one of those are the same tap coming back again.
      final duplicates = (mineOn[entry.key] ?? 0) - 1;
      merged.add(duplicates > 0
          ? entry.value.copyWith(count: entry.value.count - duplicates)
          : entry.value);
    }

    merged.sort((a, b) {
      final byCount = b.count.compareTo(a.count);
      return byCount != 0 ? byCount : a.emoji.compareTo(b.emoji);
    });
    return merged;
  }

  // ---------------------------------------------------------------------------
  // Comments
  // ---------------------------------------------------------------------------

  /// Total comments on the image, across every copy.
  Future<int> commentCount() async {
    final present = _present;
    final results = await Future.wait(present
        .map((pair) => pair.instance.api.getImageCommentCount(pair.copy.id)));
    var total = 0;
    for (var i = 0; i < results.length; i++) {
      final response = results[i];
      if (!response.success) {
        debugPrint('SharedImage: comment count from ${present[i].instance.id} '
            'unavailable (${response.error}); total will be short');
        continue;
      }
      total += response.data ?? 0;
    }
    return total;
  }

  /// Each copy's comments, grouped by the group they were left in.
  Future<List<({KrabInstance instance, Map<String, dynamic> section})>>
      commentsGrouped({String? primaryGroupId}) async {
    final present = _present;
    final results = await Future.wait(present.map((pair) => pair.instance.api
        .getImageCommentsGrouped(pair.copy.id,
            primaryGroupId: primaryGroupId)));

    final sections =
        <({KrabInstance instance, Map<String, dynamic> section})>[];
    for (var i = 0; i < results.length; i++) {
      final response = results[i];
      if (!response.success || response.data == null) {
        debugPrint('SharedImage: comments from ${present[i].instance.id} '
            'unavailable (${response.error})');
        continue;
      }
      for (final raw in response.data!) {
        sections.add((
          instance: present[i].instance,
          section: raw as Map<String, dynamic>,
        ));
      }
    }
    return sections;
  }

  // ---------------------------------------------------------------------------
  // Groups
  // ---------------------------------------------------------------------------

  /// Every group the image was posted to that the viewer can see, on any
  /// server. Groups from different instances are different groups.
  Future<List<Group>?> postedInGroups() async {
    final present = _present;
    final results = await Future.wait(
        present.map((pair) => pair.instance.viewer.fetchPostedInGroups(
              pair.copy.id,
            )));

    final groups = <Group>[];
    var anySucceeded = false;
    for (final result in results) {
      if (result == null) continue;
      anySucceeded = true;
      groups.addAll(result);
    }
    return anySucceeded ? groups : null;
  }

  /// The group lists already cached for every copy, or null when none of them
  /// has been loaded yet. Lets the viewer draw the pill without a flash.
  List<Group>? cachedPostedInGroups() {
    final groups = <Group>[];
    var anyCached = false;
    for (final pair in _present) {
      final cached = pair.instance.viewer.cachedPostedInGroups(pair.copy.id);
      if (cached == null) continue;
      anyCached = true;
      groups.addAll(cached);
    }
    return anyCached ? groups : null;
  }

  /// The groups this image can be added to.
  ///
  /// On an instance already holding a copy, adding is a link to the image
  /// that is already there. On any other it means uploading the image, a
  /// second copy, tied to the first by the share id.
  Future<List<Group>?> groupsItCouldJoin() async {
    final instances = image.primary.shareId == null
        ? [for (final pair in _present) pair.instance]
        : InstanceRegistry.instance.all;
    final results = await Future.wait(
        instances.map((instance) => instance.api.getUserGroups()));

    final groups = <Group>[];
    var anySucceeded = false;
    for (final response in results) {
      if (!response.success || response.data == null) continue;
      anySucceeded = true;
      groups.addAll(response.data!);
    }
    return anySucceeded ? groups : null;
  }

  /// Add the image to more groups, each on the instance that owns it.
  ///
  /// A group on an instance already holding a copy is linked to that copy. A
  /// group anywhere else needs the image to exist there first, so the bytes are
  /// uploaded under this image's own share id.
  Future<SupabaseResponse<List<ImageRef>>> addToGroups(
    List<Group> groups, {
    Future<Uint8List?> Function()? loadBytes,
    String description = '',
  }) async {
    final byInstance = <String, List<String>>{};
    for (final group in groups) {
      (byInstance[group.instanceId] ??= []).add(group.id);
    }

    // Only worth asking for when a copy has to be made somewhere new; linking
    // groups on servers that already hold one needs no id at all.
    final needsCopy =
        byInstance.keys.any((id) => !_present.any((p) => p.instance.id == id));
    final had = image.primary.shareId;
    String? shareId = had;
    if (needsCopy && shareId == null) shareId = await _ensureShareId();

    String? error;
    final created = <ImageRef>[];

    // The copy we are about to make carries the new id, but the one already on
    // screen still has none, and the two would read as different images until
    // the next listing. Hand back the copy it should now be.
    if (had == null && shareId != null) {
      final origin = writeTarget;
      if (origin != null) created.add(origin.copy.copyWith(shareId: shareId));
    }
    for (final entry in byInstance.entries) {
      final ids = entry.value;
      if (ids.isEmpty) continue;

      final held =
          _present.where((p) => p.instance.id == entry.key).firstOrNull;
      if (held != null) {
        final response =
            await held.instance.api.addImageToGroups(held.copy.id, ids);
        if (!response.success) error ??= response.error;
        continue;
      }

      final instance = InstanceRegistry.instance.byId(entry.key);
      if (instance == null) continue;
      final response =
          await _uploadCopyTo(instance, ids, loadBytes, description, shareId);
      if (!response.success) {
        error ??= response.error;
      } else if (response.data != null) {
        created.add(response.data!);
      }
    }
    return error == null
        ? SupabaseResponse(success: true, data: created)
        : SupabaseResponse(success: false, error: error, data: created);
  }

  /// Give this image a share id when it has none, by asking the server holding
  /// the copy we would copy from.
  ///
  /// Returns null when there is nowhere to stamp it, which the caller reports as
  /// a failure to copy.
  Future<String?> _ensureShareId() async {
    final target = writeTarget;
    if (target == null) return null;

    final response =
        await target.instance.api.assignShareId(target.copy.id, newShareId());
    if (!response.success) {
      debugPrint('SharedImage: could not mint a share id on '
          '${target.instance.id}: ${response.error}');
      return null;
    }
    return response.data;
  }

  /// Put a copy of this image on an instance, in groupIds.
  Future<SupabaseResponse<ImageRef>> _uploadCopyTo(
    KrabInstance instance,
    List<String> groupIds,
    Future<Uint8List?> Function()? loadBytes,
    String description,
    String? shareId,
  ) async {
    if (loadBytes == null || shareId == null) {
      debugPrint('SharedImage: cannot copy to ${instance.id} '
          '(bytes: ${loadBytes != null}, share id: ${shareId != null})');
      return const SupabaseResponse(success: false, error: errorServer);
    }

    final bytes = await loadBytes();
    if (bytes == null) {
      return const SupabaseResponse(success: false, error: errorServer);
    }

    // sendImageToGroups reads the file only when it has no prepared bytes, but
    // it takes one either way, and the outbox needs a real path to retry from.
    File? scratch;
    try {
      final dir = await getTemporaryDirectory();
      scratch = File('${dir.path}/reshare_${shareId}_${instance.id}.jpg');
      await scratch.writeAsBytes(bytes);

      // The outbox has to retry under any id this reserved, or it would send
      // the image a second time.
      String? reserved;

      String? storedShareId = shareId;

      final response = await instance.api.sendImageToGroups(
        scratch,
        groupIds,
        description,
        shareId: shareId,
        preparedBytes: bytes,
        onReserved: (imageId) async => reserved = imageId,
        onShareIdDropped: () => storedShareId = null,
      );

      if (!response.success || response.data == null) {
        // Offline is not a refusal: hold the copy and send it when the server
        // is reachable
        if (response.offline) {
          await UploadOutbox.instance.enqueue(
            instance.id,
            scratch,
            groupIds,
            description,
            reservedImageId: reserved,
            shareId: shareId,
          );
        }
        return SupabaseResponse(
          success: false,
          error: response.error,
          offline: response.offline,
        );
      }

      final imageId = response.data!;

      // No uploadedAt: this copy is new here, but the image is as old as its
      // oldest copy, and dating it now would move the image in a feed ordered
      // by that.
      return SupabaseResponse(
        success: true,
        data: ImageRef(
          instanceId: instance.id,
          id: imageId,
          shareId: storedShareId,
          uploadedBy: instance.auth.currentUserId,
        ),
      );
    } catch (e) {
      debugPrint('SharedImage: copying to ${instance.id} failed: $e');
      return const SupabaseResponse(success: false, error: errorServer);
    } finally {
      try {
        if (scratch != null && await scratch.exists()) await scratch.delete();
      } catch (_) {}
    }
  }

  /// Whether the signed-in user is the one who uploaded this image.
  bool isOwnedBy(String uploaderId, String instanceId) {
    final instance = InstanceRegistry.instance.byId(instanceId);
    return instance != null && instance.auth.currentUserId == uploaderId;
  }

  /// Forget the cached group lists for every copy, after one of them changed.
  void invalidatePostedInGroups() {
    for (final pair in _present) {
      pair.instance.viewer.invalidatePostedInGroups(pair.copy.id);
    }
  }

  // ---------------------------------------------------------------------------
  // Deletion
  // ---------------------------------------------------------------------------

  /// Delete the image everywhere it exists.
  ///
  /// Fails if any copy survives.
  Future<SupabaseResponse<void>> delete() async {
    final results = await Future.wait(
        _present.map((pair) => pair.instance.api.deleteImage(pair.copy.id)));

    final failed = results.where((r) => !r.success).toList();
    if (failed.isEmpty) return const SupabaseResponse(success: true);

    debugPrint('SharedImage: ${failed.length} of ${results.length} copies '
        'could not be deleted');
    return SupabaseResponse(
      success: false,
      error: failed.first.error,
      offline: failed.every((r) => r.offline),
    );
  }

  /// Remove the image from some groups.
  ///
  /// Returns whether the image is now gone from everywhere.
  Future<SupabaseResponse<bool>> removeFromGroups(List<Group> groups) async {
    final byInstance = <String, List<String>>{};
    for (final group in groups) {
      (byInstance[group.instanceId] ??= []).add(group.id);
    }

    var fullyDeletedEverywhere = true;
    String? error;

    for (final pair in _present) {
      final ids = byInstance[pair.instance.id];
      if (ids == null || ids.isEmpty) {
        fullyDeletedEverywhere = false;
        continue;
      }
      final response =
          await pair.instance.api.removeImageFromGroups(pair.copy.id, ids);
      if (!response.success) {
        error ??= response.error;
        fullyDeletedEverywhere = false;
        continue;
      }
      if (response.data != true) fullyDeletedEverywhere = false;
    }

    if (error != null) {
      return SupabaseResponse(success: false, error: error);
    }
    return SupabaseResponse(success: true, data: fullyDeletedEverywhere);
  }
}

/// The copies of refs held by instances none of refs came from.
///
/// A group gallery only ever lists one server's images, so without this an image
/// opened from there would show only that copy's comments even though the
/// viewer can plainly see the other ones.
Future<List<ImageRef>> siblingCopiesOf(Iterable<ImageRef> refs) async {
  final registry = InstanceRegistry.instance;
  if (registry.all.length < 2) return const [];

  // Only an image carrying a share id can have siblings.
  final coveredBy = <String, Set<String>>{};
  for (final ref in refs) {
    final shareId = ref.shareId;
    if (shareId == null) continue;
    (coveredBy[shareId] ??= <String>{}).add(ref.instanceId);
  }
  if (coveredBy.isEmpty) return const [];

  final found = <ImageRef>[];
  await Future.wait(registry.all.map((instance) async {
    final ask = [
      for (final entry in coveredBy.entries)
        if (!entry.value.contains(instance.id)) entry.key
    ];
    if (ask.isEmpty) return;

    final response = await instance.api.findImagesByShareId(ask);
    if (response.success && response.data != null) found.addAll(response.data!);
  }));

  return found;
}
