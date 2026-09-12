import 'dart:async';

/// A new image that arrived via push while the app is foregrounded.
class NewImageEvent {
  final String imageId;

  /// The group the image was posted to, or null if absent from the payload.
  final String? groupId;

  const NewImageEvent({required this.imageId, this.groupId});
}

/// A comment that arrived via push while the app is foregrounded.
class NewCommentEvent {
  const NewCommentEvent({
    required this.instanceId,
    required this.imageId,
    this.groupId,
  });

  final String instanceId;
  final String imageId;
  final String? groupId;
}

/// A reaction that arrived via push while the app is foregrounded.
class NewReactionEvent {
  const NewReactionEvent({required this.instanceId, required this.imageId});

  final String instanceId;
  final String imageId;
}

/// App-wide broadcast of live feed events
class FeedEvents {
  FeedEvents._();
  static final FeedEvents instance = FeedEvents._();

  final StreamController<NewImageEvent> _newImages =
      StreamController<NewImageEvent>.broadcast();

  Stream<NewImageEvent> get newImages => _newImages.stream;

  final StreamController<NewCommentEvent> _newComments =
      StreamController<NewCommentEvent>.broadcast();

  final StreamController<NewReactionEvent> _newReactions =
      StreamController<NewReactionEvent>.broadcast();

  Stream<NewCommentEvent> get newComments => _newComments.stream;

  Stream<NewReactionEvent> get newReactions => _newReactions.stream;

  void notifyNewImage(NewImageEvent event) => _newImages.add(event);
  void notifyNewComment(NewCommentEvent event) => _newComments.add(event);
  void notifyNewReaction(NewReactionEvent event) => _newReactions.add(event);
}
