Pod::Spec.new do |s|
  s.name         = "FFmpegWrapper"
  s.version      = "1.0"
  s.summary      = "A lightweight Objective-C wrapper for some FFmpeg libav functions"
  s.homepage     = "https://github.com/OpenWatch/FFmpegWrapper"
  s.license      = 'LGPLv2.1+'
  s.author       = { "Chris Ballinger" => "chris@openwatch.net" }
  s.platform     = :ios, '6.0'
  s.source       = { :git => "https://github.com/OpenWatch/FFmpegWrapper.git", :tag => "1.0"}
  s.source_files  = 'FFmpegWrapper/*.{h,m}'
  s.ios.deployment_target = '6.0'

  # ――― Project Settings ――――――――――――――――――――――――――――――――――――――――――――――――――――――――― #
  #
  #  If your library depends on compiler flags you can set them in the xcconfig hash
  #  where they will only apply to your library. If you depend on other Podspecs
  #  you can include multiple dependencies to ensure it works.

  s.requires_arc = true

  s.dependency 'FFmpeg-iOS', '~> 2.2'
end
