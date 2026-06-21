require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "react-native-bill-printer"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = "https://github.com/your-org/react-native-bill-printer"
  s.license      = "MIT"
  s.authors      = { "Your Org" => "dev@yourorg.com" }
  s.platforms    = { :ios => "15.0" }
  s.source       = { :git => "", :tag => "#{s.version}" }

  # Source files: Swift implementation + ObjC++ bridge
  s.source_files = "ios/**/*.{swift,h,m,mm}"

  s.dependency "React-Core"
  s.dependency "React-RCTFabric"
  s.dependency "ReactCommon/turbomodule/core"

  # New Architecture: install_modules_dependencies handles codegen linkage
  install_modules_dependencies(s)
end
