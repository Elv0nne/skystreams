import 'package:flutter_test/flutter_test.dart';
import 'package:skystream/core/data/models/github_release.dart';
import 'package:skystream/core/services/update_service.dart';

GithubAsset _asset(String name) => GithubAsset(
  name: name,
  browserDownloadUrl: 'https://example.com/$name',
  size: 1,
  contentType: 'application/octet-stream',
);

/// A release as release.yml publishes it for Linux.
final _release = [
  for (final arch in ['x64', 'arm64'])
    for (final ext in ['tar.gz', 'deb', 'AppImage'])
      _asset('skystream-linux-$arch-2.9.0.$ext'),
  _asset('skystream-windows-x64-2.9.0.exe'),
];

void main() {
  group('linuxInstallOf', () {
    test('an AppImage: the runtime set APPIMAGE and APPDIR, and the binary '
        'runs from inside APPDIR', () {
      expect(
        UpdateService.linuxInstallOf(
          environment: {
            'APPIMAGE': '/home/u/Apps/SkyStream.AppImage',
            'APPDIR': '/tmp/.mount_SkyStrAbC123',
          },
          executable: '/tmp/.mount_SkyStrAbC123/opt/skystream/skystream',
        ),
        LinuxInstall.appImage,
      );
    });

    test('APPIMAGE inherited from another AppImage that started SkyStream '
        'is not an AppImage install', () {
      expect(
        UpdateService.linuxInstallOf(
          environment: {
            'APPIMAGE': '/home/u/Apps/Launcher.AppImage',
            'APPDIR': '/tmp/.mount_LauncXyZ789',
          },
          executable: '/opt/skystream/skystream',
        ),
        LinuxInstall.deb,
      );
    });

    test('the .deb installs to /opt/skystream', () {
      expect(
        UpdateService.linuxInstallOf(
          environment: const {},
          executable: '/opt/skystream/skystream',
        ),
        LinuxInstall.deb,
      );
    });

    test('anything else is the tarball, unpacked wherever its owner chose', () {
      expect(
        UpdateService.linuxInstallOf(
          environment: const {},
          executable: '/home/u/skystream/skystream',
        ),
        LinuxInstall.tarball,
      );
      expect(
        UpdateService.linuxInstallOf(
          environment: const {},
          executable: '/opt/skystream-old/skystream',
        ),
        LinuxInstall.tarball,
      );
    });
  });

  group('linuxAsset', () {
    test('each install gets its own format, for its architecture', () {
      expect(
        UpdateService.linuxAsset(
          _release,
          isArm: false,
          install: LinuxInstall.appImage,
        )?.name,
        'skystream-linux-x64-2.9.0.AppImage',
      );
      expect(
        UpdateService.linuxAsset(
          _release,
          isArm: true,
          install: LinuxInstall.deb,
        )?.name,
        'skystream-linux-arm64-2.9.0.deb',
      );
      expect(
        UpdateService.linuxAsset(
          _release,
          isArm: false,
          install: LinuxInstall.tarball,
        )?.name,
        'skystream-linux-x64-2.9.0.tar.gz',
      );
    });

    test('a .deb install is never sent an AppImage, which would install a '
        'second copy beside it', () {
      expect(
        UpdateService.linuxAsset(
          _release,
          isArm: false,
          install: LinuxInstall.deb,
        )?.name,
        endsWith('.deb'),
      );
    });

    test('none when the release lacks the format, so the release page opens '
        'instead', () {
      final withoutAppImage = _release
          .where((a) => !a.name.endsWith('.AppImage'))
          .toList();
      expect(
        UpdateService.linuxAsset(
          withoutAppImage,
          isArm: false,
          install: LinuxInstall.appImage,
        ),
        isNull,
      );
    });

    test('never an asset for the other architecture', () {
      final x64Only = _release.where((a) => a.name.contains('x64')).toList();
      expect(
        UpdateService.linuxAsset(
          x64Only,
          isArm: true,
          install: LinuxInstall.deb,
        ),
        isNull,
      );
    });

    test('x86_64 and amd64 name the x64 build too', () {
      expect(
        UpdateService.linuxAsset(
          [_asset('skystream-linux-x86_64.AppImage')],
          isArm: false,
          install: LinuxInstall.appImage,
        )?.name,
        'skystream-linux-x86_64.AppImage',
      );
      expect(
        UpdateService.linuxAsset(
          [_asset('skystream-linux-amd64.deb')],
          isArm: false,
          install: LinuxInstall.deb,
        )?.name,
        'skystream-linux-amd64.deb',
      );
    });

    test('a name without an architecture serves either', () {
      expect(
        UpdateService.linuxAsset(
          [_asset('skystream-linux.deb')],
          isArm: true,
          install: LinuxInstall.deb,
        )?.name,
        'skystream-linux.deb',
      );
    });
  });
}
