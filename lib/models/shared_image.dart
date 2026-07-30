import 'package:flutter/foundation.dart';

import 'package:krab/models/image_ref.dart';

/// One image, however many servers happen to be holding it.
///
/// Reads merge across copies. Writes go only to primary.
///
/// A viewer only ever sees the copies on servers they are connected to.
/// Two people on different servers cannot see each other.
class SharedImage {
  SharedImage(List<ImageRef> copies)
      : assert(copies.isNotEmpty, 'an image with no copies is not an image'),
        copies = List.unmodifiable(copies);

  /// Every copy this device can reach, in the order the instances are
  /// registered. Never empty.
  final List<ImageRef> copies;

  /// Stable across rebuilds and shared by every copy.
  String get identity => copies.first.identity;

  /// The copy that answers for the image: where the bytes are fetched from,
  /// what a new comment or reaction is written to, and whose id the viewer
  /// keys its state by.
  ImageRef get primary => copies.first;

  /// True when this image really does live on more than one server.
  bool get isShared => copies.length > 1;

  /// When the image was posted: the earliest any copy claims, since they were
  /// all sent in one action and the spread is just upload timing.
  DateTime? get uploadedAt {
    DateTime? earliest;
    for (final copy in copies) {
      final at = copy.uploadedAt;
      if (at == null) continue;
      if (earliest == null || at.isBefore(earliest)) earliest = at;
    }
    return earliest;
  }

  /// The uploader, as named by the primary copy.
  String? get uploadedBy => primary.uploadedBy;

  ImageRef? copyOn(String instanceId) {
    for (final copy in copies) {
      if (copy.instanceId == instanceId) return copy;
    }
    return null;
  }

  @override
  String toString() => 'SharedImage{identity: $identity, '
      'copies: ${copies.map((c) => '${c.instanceId}/${c.id}').join(', ')}}';
}

/// Collapse a list of copies into one entry per image.
List<SharedImage> mergeImages(
  Iterable<ImageRef> refs, {
  required List<String> instanceOrder,
}) {
  final byIdentity = <String, List<ImageRef>>{};
  final order = <String>[];

  for (final ref in refs) {
    final identity = ref.identity;
    final existing = byIdentity[identity];
    if (existing == null) {
      byIdentity[identity] = [ref];
      order.add(identity);
      continue;
    }
    // The same copy can arrive twice when a feed page overlaps a refresh.
    if (existing.any((c) => c.instanceId == ref.instanceId && c.id == ref.id)) {
      continue;
    }
    if (existing.any((c) => c.instanceId == ref.instanceId)) {
      final standalone = ImageRef(
        instanceId: ref.instanceId,
        id: ref.id,
        uploadedBy: ref.uploadedBy,
        uploadedAt: ref.uploadedAt,
      );
      final own = standalone.identity;
      debugPrint('mergeImages: $own claims identity $identity, already held '
          'there; showing it separately');
      if (byIdentity[own] == null) {
        byIdentity[own] = [standalone];
        order.add(own);
      }
      continue;
    }
    existing.add(ref);
  }

  int rank(ImageRef ref) {
    final index = instanceOrder.indexOf(ref.instanceId);
    // An instance that has since been removed sorts last rather than first.
    return index < 0 ? instanceOrder.length : index;
  }

  return [
    for (final identity in order)
      SharedImage(
          byIdentity[identity]!..sort((a, b) => rank(a).compareTo(rank(b))))
  ];
}

/// Order images newest first.
void sortImagesNewestFirst(List<SharedImage> images) {
  images.sort((a, b) {
    final aAt = a.uploadedAt;
    final bAt = b.uploadedAt;
    if (aAt == null && bAt == null) return a.identity.compareTo(b.identity);
    if (aAt == null) return 1;
    if (bAt == null) return -1;
    final byTime = bAt.compareTo(aAt);
    return byTime != 0 ? byTime : a.identity.compareTo(b.identity);
  });
}
