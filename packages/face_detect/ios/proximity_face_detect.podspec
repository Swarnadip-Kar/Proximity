Pod::Spec.new do |s|
  s.name             = 'proximity_face_detect'
  s.version          = '0.1.0'
  s.summary          = 'First-party face-presence detector (Apple Vision).'
  s.homepage         = 'https://example.invalid'
  s.license          = { :type => 'MIT' }
  s.author           = { 'Proximity' => 'dev@example.invalid' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.0'
  # System frameworks only — no vendored binaries, no arch exclusions,
  # so arm64 simulator builds keep working.
  s.frameworks       = 'Vision', 'UIKit'
end
