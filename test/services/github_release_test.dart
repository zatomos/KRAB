import 'package:flutter_test/flutter_test.dart';

import 'package:krab/services/update_service.dart';

/// One entry as GitHub actually returns it from
Map<String, dynamic> release({
  String tag = 'v1.2.3',
  String body = 'Something changed',
  List<Map<String, dynamic>>? assets,
}) =>
    {
      'tag_name': tag,
      'body': body,
      'draft': false,
      'prerelease': false,
      'assets': assets ??
          [
            {
              'name': 'krab-1.2.3.apk',
              'browser_download_url':
                  'https://github.com/zatomos/KRAB/releases/download/v1.2.3/krab-1.2.3.apk',
            }
          ],
    };

void main() {
  group('Release.fromGitHub', () {
    test('reads the version, APK asset and changelog from a release', () {
      final r = Release.fromGitHub(release(
        tag: 'v1.2.3',
        body: '- Added a thing\n- Fixed another\n',
      ))!;

      expect(r.version, '1.2.3');
      expect(
        r.downloadUrl,
        'https://github.com/zatomos/KRAB/releases/download/v1.2.3/krab-1.2.3.apk',
      );
      expect(r.changelog, ['Added a thing', 'Fixed another']);
    });

    test('accepts a tag without the conventional v prefix', () {
      expect(Release.fromGitHub(release(tag: '1.2.3'))!.version, '1.2.3');
    });

    test('bullets are stripped whether written with - or *', () {
      final r = Release.fromGitHub(release(body: '* One\n- Two\nThree'))!;
      expect(r.changelog, ['One', 'Two', 'Three']);
    });

    test('a release with no APK attached is not an update', () {
      // Offering it would send the user to a download that 404s.
      expect(Release.fromGitHub(release(assets: [])), isNull);
      expect(
        Release.fromGitHub(release(assets: [
          {
            'name': 'source.zip',
            'browser_download_url': 'https://example.test/source.zip',
          }
        ])),
        isNull,
      );
    });

    test('picks the .apk even when other assets are attached', () {
      final r = Release.fromGitHub(release(assets: [
        {'name': 'checksums.txt', 'browser_download_url': 'https://x/c.txt'},
        {'name': 'krab-9.9.9.apk', 'browser_download_url': 'https://x/k.apk'},
      ]))!;
      expect(r.downloadUrl, 'https://x/k.apk');
    });

    test('an empty tag yields no release', () {
      expect(Release.fromGitHub(release(tag: '')), isNull);
    });

    test('empty release notes are tolerated', () {
      final r = Release.fromGitHub(release(body: ''))!;
      expect(r.changelog, isEmpty);
    });
  });
}
