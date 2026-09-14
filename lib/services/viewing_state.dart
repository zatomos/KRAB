import 'package:krab/models/shared_image.dart';

/// What the user has open right now.
class ViewingState {
  ViewingState._();

  static final ViewingState instance = ViewingState._();

  /// The copies of the image the viewer is showing
  Map<String, String> _openCopies = const {};

  /// The groups whose comments are on screen
  Map<String, Set<String>> _commentGroups = const {};

  void openImage(SharedImage image) {
    _openCopies = {
      for (final copy in image.copies) copy.instanceId: copy.id,
    };
  }

  void closeImage() {
    _openCopies = const {};
    _commentGroups = const {};
  }

  void openComments(Map<String, Set<String>> groupIds) {
    _commentGroups = {
      for (final entry in groupIds.entries) entry.key: {...entry.value},
    };
  }

  void closeComments() => _commentGroups = const {};

  /// Whether the viewer is showing the image this push is about
  bool isViewingImage({required String instanceId, required String imageId}) =>
      _openCopies[instanceId] == imageId;

  /// Whether the open comments sheet already shows this comment's thread
  bool isShowingComments({
    required String instanceId,
    required String imageId,
    required String? groupId,
  }) {
    if (groupId == null || groupId.isEmpty) return false;
    if (!isViewingImage(instanceId: instanceId, imageId: imageId)) return false;
    return _commentGroups[instanceId]?.contains(groupId) ?? false;
  }
}
