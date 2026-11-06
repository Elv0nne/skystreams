Pod::Spec.new do |s|
  s.name             = 'cs3_engine'
  s.version          = '0.3.0'
  s.summary          = 'Runs CloudStream extensions in an embedded OpenJDK Zero VM (no JIT).'
  s.homepage         = 'https://github.com/akashdh11/skystream'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'SkyStream'
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  # Built by tool/ios/build_openjdk.sh (sim, device) and tool/ios/package_openjdk.sh: arm64 for
  # devices and for the simulator on Apple Silicon.
  s.vendored_frameworks = 'Frameworks/OpenJDKRuntime.xcframework'
  # CocoaPods only puts the vendored framework on the search path; the plugin links JNI from it.
  s.frameworks = 'OpenJDKRuntime'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 x86_64',
  }
  s.user_target_xcconfig = { 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386 x86_64' }
end
