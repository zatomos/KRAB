import 'package:flutter_test/flutter_test.dart';

import 'package:krab/services/notification_channels.dart';

void main() {
  String title({
    String commenter = 'Camille',
    String uploader = 'Sarah',
    bool uploaderIsMe = false,
    bool uploaderIsCommenter = false,
    String parentAuthor = '',
    bool parentAuthorIsMe = false,
    bool parentAuthorIsUploader = false,
  }) =>
      commentNotificationTitle(
        commenterUsername: commenter,
        uploaderUsername: uploader,
        uploaderIsMe: uploaderIsMe,
        uploaderIsCommenter: uploaderIsCommenter,
        parentAuthorUsername: parentAuthor,
        parentAuthorIsMe: parentAuthorIsMe,
        parentAuthorIsUploader: parentAuthorIsUploader,
      );

  group('replies', () {
    test('names both people when neither is you', () {
      expect(
        title(parentAuthor: 'Théo'),
        'Camille replied to Théo on Sarah\'s image',
      );
    });

    test('does not repeat a name when the photo is the replied-to one\'s', () {
      expect(
        title(
            parentAuthor: 'Théo',
            uploader: 'Théo',
            parentAuthorIsUploader: true),
        'Camille replied to Théo on their image',
      );
    });

    test('does not repeat the replier when the photo is theirs', () {
      expect(
        title(
            parentAuthor: 'Théo',
            uploader: 'Camille',
            uploaderIsCommenter: true),
        'Camille replied to Théo on their own image',
      );
    });

    test('says the photo is yours', () {
      expect(
        title(parentAuthor: 'Théo', uploaderIsMe: true),
        'Camille replied to Théo on your image',
      );
    });

    test('addresses you when the reply answers you', () {
      expect(
        title(parentAuthorIsMe: true),
        'Camille replied to you on Sarah\'s image',
      );
    });

    test('says so when the reply answers you under your own photo', () {
      expect(
        title(parentAuthorIsMe: true, uploaderIsMe: true),
        'Camille replied to you on your image',
      );
    });

    test('does not repeat the commenter under their own photo', () {
      expect(
        title(
            parentAuthorIsMe: true,
            uploader: 'Camille',
            uploaderIsCommenter: true),
        'Camille replied to you on their image',
      );
    });

    test('reads as a plain comment when the replied-to author is gone', () {
      expect(
        title(uploaderIsMe: true),
        'Camille commented on your image',
      );
    });
  });

  group('comments', () {
    test('names the uploader', () {
      expect(title(), 'Camille commented on Sarah\'s image');
    });

    test('says the photo is yours', () {
      expect(title(uploaderIsMe: true), 'Camille commented on your image');
    });

    test('says so when someone comments under their own photo', () {
      expect(
        title(uploader: 'Camille', uploaderIsCommenter: true),
        'Camille commented on their own image',
      );
    });

    test('falls back rather than naming nobody', () {
      expect(title(uploader: ''), 'Camille commented on Someone\'s image');
    });
  });
}
