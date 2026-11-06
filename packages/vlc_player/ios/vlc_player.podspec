#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint vlc_player.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'vlc_player'
  s.version          = '2.1.3'
  s.summary          = 'A Flutter plugin for video playback using VLCKit.'
  s.description      = <<-DESC
A Flutter plugin for video playback using VideoLAN VLCKit.
                       DESC
  s.homepage         = 'https://github.com/lingjhf/vlc_player'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'lingjhf' => 'lingjhf@users.noreply.github.com' }

  s.source           = { :path => '.' }
  # The renderer and VlcSharedSources.cc are symlinks into ../darwin, the one
  # copy both Darwin pods compile; the macOS podspec explains why they cannot
  # be listed by their real path.
  s.source_files = 'vlc_player/Sources/vlc_player/**/*.{swift,h,mm,cc}'
  # Only the Objective-C renderer belongs in the generated umbrella header;
  # that umbrella is compiled as Objective-C, and the shared headers are C++.
  s.public_header_files = [
    'vlc_player/Sources/vlc_player/VlcTextureRenderer.h',
    'vlc_player/Sources/vlc_player/VlcPlayerEvents.h',
  ]
  s.resource_bundles = {'vlc_player_privacy' => ['vlc_player/Sources/vlc_player/PrivacyInfo.xcprivacy']}

  s.dependency 'Flutter'
  s.dependency 'MobileVLCKit', '3.7.4'

  s.platform = :ios, '13.0'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    'CLANG_CXX_LANGUAGE_STANDARD' => 'c++17',
    'CLANG_CXX_LIBRARY' => 'libc++',
    # MobileVLCKit ships the libvlc C headers under its framework's Headers/vlc,
    # so `#include <vlc/vlc.h>` resolves exactly as it does on macOS. The
    # extracted slice is listed first because that is what CocoaPods builds
    # against; the checked-in xcframework's slices follow for when it has not
    # been extracted yet, and both are named because the device and simulator
    # slices carry identical headers.
    'HEADER_SEARCH_PATHS' => [
      '"$(PODS_TARGET_SRCROOT)/../src/native"',
      '"$(PODS_XCFRAMEWORKS_BUILD_DIR)/MobileVLCKit/MobileVLCKit.framework/Headers"',
      '"$(PODS_ROOT)/MobileVLCKit/MobileVLCKit.xcframework/ios-arm64_armv7_armv7s/MobileVLCKit.framework/Headers"',
      '"$(PODS_ROOT)/MobileVLCKit/MobileVLCKit.xcframework/ios-arm64_i386_x86_64-simulator/MobileVLCKit.framework/Headers"',
    ].join(' '),
  }
  s.swift_version = '5.0'
end
