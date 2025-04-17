Pod::Spec.new do |s|
  s.name         = "react-native-vlc-media-player"
  s.version      = "1.0.3"
  s.summary      = "VLC player"
  s.requires_arc = true
  s.author       = { 'roshan.milinda' => 'rmilinda@gmail.com' }
  s.license      = 'MIT'
  s.homepage     = 'https://github.com/liixing/react-native-vlc-media-player.git'
  s.source       = { :git => "https://github.com/liixing/react-native-vlc-media-player.git" }
  s.source_files = 'ios/RCTVLCPlayer/*'
  s.ios.deployment_target = "8.4"
  s.tvos.deployment_target = "10.2"
  s.static_framework = true
  s.dependency 'React'
  s.ios.dependency 'MobileVLCKit', '4.0.0a2'
  s.tvos.dependency 'TVVLCKit', '4.0.0a2'
end
