#!/usr/bin/env ruby

require "xcodeproj"

project_path = File.expand_path("../CastReader.xcodeproj", __dir__)
project = Xcodeproj::Project.open(project_path)
app = project.targets.find { |target| target.name == "CastReader" }
abort "CastReader target not found" unless app

def find_file(group, path)
  group.recursive_children.find { |child| child.respond_to?(:path) && child.path == path }
end

services = project.main_group.recursive_children.find do |child|
  child.is_a?(Xcodeproj::Project::Object::PBXGroup) && child.path == "Services"
end
abort "Services group not found" unless services

inbox_ref = find_file(services, "ShareInbox.swift") || services.new_file("ShareInbox.swift")
unless app.source_build_phase.files_references.include?(inbox_ref)
  app.source_build_phase.add_file_reference(inbox_ref)
end

share = project.targets.find { |target| target.name == "CastReader Share Extension" }
unless share
  share = project.new_target(:app_extension, "CastReader Share Extension", :ios, "17.6")
end

share_group = project.main_group.groups.find { |group| group.path == "CastReader Share Extension" } ||
              project.main_group.new_group("CastReader Share Extension", "CastReader Share Extension")

controller_ref = find_file(share_group, "ShareViewController.swift") || share_group.new_file("ShareViewController.swift")
info_ref = find_file(share_group, "Info.plist") || share_group.new_file("Info.plist")
entitlements_ref = find_file(share_group, "CastReaderShareExtension.entitlements") ||
                   share_group.new_file("CastReaderShareExtension.entitlements")
localizable_ref = find_file(share_group, "Localizable.xcstrings") || share_group.new_file("Localizable.xcstrings")

[controller_ref, inbox_ref].each do |ref|
  share.source_build_phase.add_file_reference(ref) unless share.source_build_phase.files_references.include?(ref)
end
share.resources_build_phase.add_file_reference(localizable_ref) unless share.resources_build_phase.files_references.include?(localizable_ref)

app_version = app.build_configurations.first.build_settings.fetch("CURRENT_PROJECT_VERSION", "1")
marketing_version = app.build_configurations.first.build_settings.fetch("MARKETING_VERSION", "1.0")
team = app.build_configurations.first.build_settings["DEVELOPMENT_TEAM"]
share.build_configurations.each do |config|
  settings = config.build_settings
  settings["APPLICATION_EXTENSION_API_ONLY"] = "YES"
  settings["CODE_SIGN_ENTITLEMENTS"] = "CastReader Share Extension/CastReaderShareExtension.entitlements"
  settings["CODE_SIGN_STYLE"] = "Automatic"
  settings["CURRENT_PROJECT_VERSION"] = app_version
  settings["DEVELOPMENT_TEAM"] = team if team
  settings["GENERATE_INFOPLIST_FILE"] = "NO"
  settings["INFOPLIST_FILE"] = "CastReader Share Extension/Info.plist"
  settings["IPHONEOS_DEPLOYMENT_TARGET"] = "17.6"
  settings["MARKETING_VERSION"] = marketing_version
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.same.castreader.ShareExtension"
  settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
  settings["SKIP_INSTALL"] = "YES"
  settings["SWIFT_VERSION"] = "5.0"
  settings["TARGETED_DEVICE_FAMILY"] = "1,2"
end

app.add_dependency(share) unless app.dependencies.any? { |dependency| dependency.target == share }
embed_phase = app.copy_files_build_phases.find { |phase| phase.name == "Embed App Extensions" } ||
              app.new_copy_files_build_phase("Embed App Extensions")
embed_phase.symbol_dst_subfolder_spec = :plug_ins
unless embed_phase.files_references.include?(share.product_reference)
  build_file = embed_phase.add_file_reference(share.product_reference)
  build_file.settings = { "ATTRIBUTES" => ["CodeSignOnCopy", "RemoveHeadersOnCopy"] }
end

project.save
puts "CastReader Share Extension is registered."
