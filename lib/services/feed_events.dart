import 'dart:async';

/// A new image that arrived via push while the app is foregrounded.
class NewImageEvent {
  final String imageId;

  /// The group the image was posted to, or null if absent from the payload.
  final String? groupId;

  const NewImageEvent({required this.imageId, this.groupId});
}

/// App-wide broadcast of live feed events
class FeedEvents {
  FeedEvents._();
  static final FeedEvents instance = FeedEvents._();

  final StreamController<NewImageEvent> _newImages =
      StreamController<NewImageEvent>.broadcast();

  /// Emits whenever a new_image push is received in the foreground.
  Stream<NewImageEvent> get newImages => _newImages.stream;

  void notifyNewImage(NewImageEvent event) => _newImages.add(event);
}
