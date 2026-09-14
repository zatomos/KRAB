import 'package:flutter_test/flutter_test.dart';
import 'package:krab/models/image_ref.dart';
import 'package:krab/models/shared_image.dart';
import 'package:krab/services/viewing_state.dart';

SharedImage _image(List<(String instance, String id)> copies) => SharedImage([
      for (final (instance, id) in copies)
        ImageRef(instanceId: instance, id: id),
    ]);

void main() {
  final viewing = ViewingState.instance;

  setUp(() {
    viewing.closeImage();
  });

  group('reactions', () {
    test('a reaction on the open image is already on screen', () {
      viewing.openImage(_image([('inst_1', 'img-a')]));

      expect(
        viewing.isViewingImage(instanceId: 'inst_1', imageId: 'img-a'),
        isTrue,
      );
    });

    test('another image on the same server still notifies', () {
      viewing.openImage(_image([('inst_1', 'img-a')]));

      expect(
        viewing.isViewingImage(instanceId: 'inst_1', imageId: 'img-b'),
        isFalse,
      );
    });

    test('the same image id on a server not being viewed still notifies', () {
      viewing.openImage(_image([('inst_1', 'img-a')]));

      expect(
        viewing.isViewingImage(instanceId: 'inst_2', imageId: 'img-a'),
        isFalse,
      );
    });

    test('every copy of a shared image counts as the one on screen', () {
      viewing.openImage(_image([('inst_1', 'img-a'), ('inst_2', 'other-id')]));

      expect(viewing.isViewingImage(instanceId: 'inst_1', imageId: 'img-a'),
          isTrue);
      expect(viewing.isViewingImage(instanceId: 'inst_2', imageId: 'other-id'),
          isTrue);
    });

    test('nothing is on screen once the viewer closes', () {
      viewing.openImage(_image([('inst_1', 'img-a')]));
      viewing.closeImage();

      expect(viewing.isViewingImage(instanceId: 'inst_1', imageId: 'img-a'),
          isFalse);
    });
  });

  group('comments', () {
    test('a comment in a group the sheet is showing is already on screen', () {
      viewing.openImage(_image([('inst_1', 'img-a')]));
      viewing.openComments({
        'inst_1': {'group-1', 'group-2'}
      });

      expect(
        viewing.isShowingComments(
            instanceId: 'inst_1', imageId: 'img-a', groupId: 'group-2'),
        isTrue,
      );
    });

    test('a comment in another group of the same image still notifies', () {
      viewing.openImage(_image([('inst_1', 'img-a')]));
      viewing.openComments({
        'inst_1': {'group-1'}
      });

      expect(
        viewing.isShowingComments(
            instanceId: 'inst_1', imageId: 'img-a', groupId: 'group-9'),
        isFalse,
      );
    });

    test('a group on another server still notifies', () {
      viewing.openImage(_image([('inst_1', 'img-a'), ('inst_2', 'copy')]));
      viewing.openComments({
        'inst_1': {'group-1'}
      });

      expect(
        viewing.isShowingComments(
            instanceId: 'inst_2', imageId: 'copy', groupId: 'group-1'),
        isFalse,
        reason: 'group ids are only meaningful on their own server',
      );
    });

    test('a comment with no group named still notifies', () {
      viewing.openImage(_image([('inst_1', 'img-a')]));
      viewing.openComments({
        'inst_1': {'group-1'}
      });

      expect(
        viewing.isShowingComments(
            instanceId: 'inst_1', imageId: 'img-a', groupId: null),
        isFalse,
      );
    });

    test('closing the sheet notifies again, even with the viewer still open',
        () {
      viewing.openImage(_image([('inst_1', 'img-a')]));
      viewing.openComments({
        'inst_1': {'group-1'}
      });
      viewing.closeComments();

      expect(
        viewing.isShowingComments(
            instanceId: 'inst_1', imageId: 'img-a', groupId: 'group-1'),
        isFalse,
      );
      expect(viewing.isViewingImage(instanceId: 'inst_1', imageId: 'img-a'),
          isTrue,
          reason: 'the viewer is still up, so reactions stay quiet');
    });

    test('leaving the viewer clears the sheet too', () {
      viewing.openImage(_image([('inst_1', 'img-a')]));
      viewing.openComments({
        'inst_1': {'group-1'}
      });
      viewing.closeImage();

      expect(
        viewing.isShowingComments(
            instanceId: 'inst_1', imageId: 'img-a', groupId: 'group-1'),
        isFalse,
      );
    });
  });
}
