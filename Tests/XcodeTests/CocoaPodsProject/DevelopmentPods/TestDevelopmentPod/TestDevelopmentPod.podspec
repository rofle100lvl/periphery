Pod::Spec.new do |spec|
  spec.name         = "TestDevelopmentPod"
  spec.version      = "0.0.1"
  spec.summary      = "A pod for testing."
  spec.homepage     = "https://github.com/peripheryapp/periphery"
  spec.license      = "MIT"
  spec.author       = "Ian Leitch"
  spec.platform     = :ios, "15.5"
  spec.source       = { :path => "." }
  spec.source_files = "Classes"
end
