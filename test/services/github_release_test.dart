import 'package:flutter_test/flutter_test.dart';

import 'package:krab/services/update_service.dart';

Map<String, dynamic> asset(String name) => {
      'name': name,
      'browser_download_url':
          'https://github.com/zatomos/KRAB/releases/download/v1.2.3/$name',
    };

/// The APKs a release carries: one per ABI, plus a universal one.
List<Map<String, dynamic>> splitAssets() => [
      asset('krab-1.2.3-arm64-v8a.apk'),
      asset('krab-1.2.3-armeabi-v7a.apk'),
      asset('krab-1.2.3-universal.apk'),
      asset('krab-1.2.3-x86_64.apk'),
    ];

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
      'assets': assets ?? splitAssets(),
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
        r.apkUrlFor(const ['arm64-v8a']),
        'https://github.com/zatomos/KRAB/releases/download/v1.2.3/krab-1.2.3-arm64-v8a.apk',
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

    test('an empty tag yields no release', () {
      expect(Release.fromGitHub(release(tag: '')), isNull);
    });

    test('empty release notes are tolerated', () {
      final r = Release.fromGitHub(release(body: ''))!;
      expect(r.changelog, isEmpty);
    });

    test('a tag that is not a version number is not a release we can offer', () {
      expect(Release.fromGitHub(release(tag: 'nightly')), isNull);
      expect(Release.fromGitHub(release(tag: 'latest')), isNull);
      expect(Release.fromGitHub(release(tag: 'v')), isNull);
      expect(Release.fromGitHub(release(tag: '')), isNull);
    });

    test('a prerelease tag still parses', () {
      final r = Release.fromGitHub(release(tag: 'v1.2.3-beta.2'))!;
      expect(r.version, '1.2.3-beta.2');
    });

    test('non-APK assets are ignored', () {
      final r = Release.fromGitHub(release(assets: [
        {'name': 'checksums.txt', 'browser_download_url': 'https://x/c.txt'},
        ...splitAssets(),
      ]))!;
      expect(r.apks.map((a) => a.name), everyElement(endsWith('.apk')));
    });
  });

  group('Release.apkUrlFor', () {
    test('installs the APK built for the device ABI', () {
      final r = Release.fromGitHub(release(assets: splitAssets()))!;

      expect(r.apkUrlFor(const ['arm64-v8a', 'armeabi-v7a']),
          endsWith('krab-1.2.3-arm64-v8a.apk'));
      expect(r.apkUrlFor(const ['armeabi-v7a']),
          endsWith('krab-1.2.3-armeabi-v7a.apk'));
      expect(r.apkUrlFor(const ['x86_64']), endsWith('krab-1.2.3-x86_64.apk'));
    });

    test('a 64-bit device is not handed the 32-bit APK', () {

      final r = Release.fromGitHub(release(assets: splitAssets()))!;
      expect(r.apkUrlFor(const ['arm64-v8a', 'armeabi-v7a']),
          isNot(contains('armeabi')));
    });

    test('an unknown ABI falls back to the universal APK', () {
      // A device whose ABI we do not publish, or one whose ABIs we could not
      // read at all, still gets something installable.
      final r = Release.fromGitHub(release(assets: splitAssets()))!;

      expect(r.apkUrlFor(const ['riscv64']), endsWith('krab-1.2.3-universal.apk'));
      expect(r.apkUrlFor(const []), endsWith('krab-1.2.3-universal.apk'));
    });

    test('a release carrying no APK for us is not an update', () {
      // Offering it would send the user to a download they cannot install.
      final r = Release.fromGitHub(release(assets: [
        asset('krab-1.2.3-x86_64.apk'),
      ]))!;
      expect(r.apkUrlFor(const ['arm64-v8a']), isNull);
    });
  });
}
