#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
#
Pod::Spec.new do |s|
  s.name             = 'log_vault'
  s.version          = '0.1.0'
  s.summary          = 'Log retention and shared log dump for Flutter apps.'
  s.description      = <<-DESC
Log retention (in-memory ring buffer + rotating file storage) and shared
log dump/export for Flutter apps, with an optional native (Kotlin/Swift)
logging bridge.
                       DESC
  s.homepage         = 'https://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Your Company' => 'email@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version    = '5.0'
end
