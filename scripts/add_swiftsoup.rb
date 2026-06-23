#!/usr/bin/env ruby
# 给 app target 加 SwiftSoup SPM 依赖（EPUB native 解析用）。幂等。
require 'xcodeproj'

project = Xcodeproj::Project.open('CastReader.xcodeproj')
target = project.targets.find { |t| t.name == 'CastReader' }
abort 'no CastReader target' unless target

# 1. XCRemoteSwiftPackageReference
pkg = project.root_object.package_references.find do |r|
  r.is_a?(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference) &&
    r.repositoryURL.to_s.include?('SwiftSoup')
end
unless pkg
  pkg = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
  pkg.repositoryURL = 'https://github.com/scinfu/SwiftSoup.git'
  pkg.requirement = { 'kind' => 'upToNextMajorVersion', 'minimumVersion' => '2.6.0' }
  project.root_object.package_references << pkg
  puts 'added XCRemoteSwiftPackageReference SwiftSoup'
end

# 2. XCSwiftPackageProductDependency
dep = target.package_product_dependencies.find { |d| d.product_name == 'SwiftSoup' }
unless dep
  dep = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dep.package = pkg
  dep.product_name = 'SwiftSoup'
  target.package_product_dependencies << dep
  puts 'added XCSwiftPackageProductDependency SwiftSoup'
end

# 3. PBXBuildFile in Frameworks phase
exists = target.frameworks_build_phase.files.any? do |f|
  f.product_ref && f.product_ref.product_name == 'SwiftSoup'
end
unless exists
  bf = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  bf.product_ref = dep
  target.frameworks_build_phase.files << bf
  puts 'added PBXBuildFile SwiftSoup'
end

project.save
puts 'saved project'
