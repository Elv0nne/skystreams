Pod::Spec.new do |s|
  s.name             = 'challenge_browser'
  s.version          = '0.1.0'
  s.summary          = 'Runs one short-lived page in WKWebView, hidden or shown in a platform view.'
  s.homepage         = 'https://github.com/akashdh11/skystream'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'SkyStream'
  s.source           = { :path => '.' }
  s.source_files     = 'challenge_browser/Sources/challenge_browser/**/*.swift'
  s.ios.dependency 'Flutter'
  s.osx.dependency 'FlutterMacOS'
  s.ios.deployment_target = '15.0'
  s.osx.deployment_target = '12.0'
  s.frameworks = 'WebKit'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
