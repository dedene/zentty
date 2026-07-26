Pod::Spec.new do |s|
  s.name           = 'PushKeyMirror'
  s.version        = '1.0.0'
  s.summary        = 'Mirrors Zentty push-seal key material into the shared App Group for the Notification Service Extension.'
  s.license        = 'MIT'
  s.author         = 'Zenjoy'
  s.homepage       = 'https://github.com/zenjoy/zentty'
  s.platforms      = { :ios => '15.1' }
  s.swift_version  = '5.9'
  s.source         = { git: '' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  s.source_files = '**/*.{h,m,swift}'
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'SWIFT_COMPILATION_MODE' => 'wholemodule'
  }
end
