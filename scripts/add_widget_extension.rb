#!/usr/bin/env ruby
# frozen_string_literal: true

require "xcodeproj"

project_path = File.expand_path("../CastReader.xcodeproj", __dir__)
project = Xcodeproj::Project.open(project_path)
app = project.targets.find { |target| target.name == "CastReader" }
abort "CastReader target not found" unless app

def find_file(group, path)
  group.recursive_children.find do |child|
    child.respond_to?(:path) && child.path == path
  end
end

app_group = project.main_group.groups.find { |group| group.path == "CastReader" }
abort "CastReader group not found" unless app_group

system_group = app_group.groups.find { |group| group.path == "SystemIntegration" } ||
               app_group.new_group("SystemIntegration", "SystemIntegration")
shared_names = %w[
  SystemIntegrationModels.swift
  SystemIntegrationStores.swift
  CastReaderAppIntents.swift
]
shared_refs = shared_names.map do |name|
  find_file(system_group, name) || system_group.new_file(name)
end
shared_refs.each do |ref|
  unless app.source_build_phase.files_references.include?(ref)
    app.source_build_phase.add_file_reference(ref)
  end
end

app_shortcuts_ref = find_file(app_group, "AppShortcuts.xcstrings") ||
                    app_group.new_file("AppShortcuts.xcstrings")
unless app.resources_build_phase.files_references.include?(app_shortcuts_ref)
  app.resources_build_phase.add_file_reference(app_shortcuts_ref)
end

widget = project.targets.find { |target| target.name == "CastReader Widget" }
widget ||= project.new_target(:app_extension, "CastReader Widget", :ios, "17.6")

# xcodeproj may add a Foundation.framework reference whose SDK path is pinned to
# the gem author's Xcode version. Swift links Foundation through the SDK without
# that explicit entry, so remove the brittle target-local reference.
widget_foundation_refs = widget.frameworks_build_phase.files_references.select do |ref|
  ref.display_name == "Foundation.framework"
end
widget.frameworks_build_phase.files.each do |build_file|
  build_file.remove_from_project if widget_foundation_refs.include?(build_file.file_ref)
end
widget_foundation_refs.each do |ref|
  ref.remove_from_project if ref.build_files.empty?
end

widget_group = project.main_group.groups.find { |group| group.path == "CastReader Widget" } ||
               project.main_group.new_group("CastReader Widget", "CastReader Widget")
widget_source_names = %w[
  ContinueReadingWidget.swift
  CastReaderWidgetBundle.swift
]
widget_source_refs = widget_source_names.map do |name|
  find_file(widget_group, name) || widget_group.new_file(name)
end
info_ref = find_file(widget_group, "Info.plist") || widget_group.new_file("Info.plist")
entitlements_ref = find_file(widget_group, "CastReaderWidget.entitlements") ||
                   widget_group.new_file("CastReaderWidget.entitlements")
localizable_ref = find_file(widget_group, "Localizable.xcstrings") ||
                  widget_group.new_file("Localizable.xcstrings")

(widget_source_refs + shared_refs).each do |ref|
  unless widget.source_build_phase.files_references.include?(ref)
    widget.source_build_phase.add_file_reference(ref)
  end
end
unless widget.resources_build_phase.files_references.include?(localizable_ref)
  widget.resources_build_phase.add_file_reference(localizable_ref)
end

app_version = app.build_configurations.first.build_settings.fetch("CURRENT_PROJECT_VERSION", "1")
marketing_version = app.build_configurations.first.build_settings.fetch("MARKETING_VERSION", "1.0")
team = app.build_configurations.first.build_settings["DEVELOPMENT_TEAM"]

widget.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings["APPLICATION_EXTENSION_API_ONLY"] = "YES"
  settings["CODE_SIGN_ENTITLEMENTS"] = "CastReader Widget/CastReaderWidget.entitlements"
  settings["CODE_SIGN_STYLE"] = "Automatic"
  settings["CURRENT_PROJECT_VERSION"] = app_version
  settings["DEVELOPMENT_TEAM"] = team if team
  settings["GENERATE_INFOPLIST_FILE"] = "NO"
  settings["INFOPLIST_FILE"] = "CastReader Widget/Info.plist"
  settings["IPHONEOS_DEPLOYMENT_TARGET"] = "17.6"
  settings["MARKETING_VERSION"] = marketing_version
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.same.castreader.Widget"
  settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
  settings["SKIP_INSTALL"] = "YES"
  settings["SWIFT_ACTIVE_COMPILATION_CONDITIONS"] = "$(inherited) CASTREADER_WIDGET"
  settings["SWIFT_EMIT_LOC_STRINGS"] = "YES"
  settings["SWIFT_VERSION"] = "5.0"
  settings["TARGETED_DEVICE_FAMILY"] = "1,2"
end

unless app.dependencies.any? { |dependency| dependency.target == widget }
  app.add_dependency(widget)
end
embed_phase = app.copy_files_build_phases.find { |phase| phase.name == "Embed App Extensions" } ||
              app.new_copy_files_build_phase("Embed App Extensions")
embed_phase.symbol_dst_subfolder_spec = :plug_ins
unless embed_phase.files_references.include?(widget.product_reference)
  build_file = embed_phase.add_file_reference(widget.product_reference)
  build_file.settings = { "ATTRIBUTES" => ["CodeSignOnCopy", "RemoveHeadersOnCopy"] }
end

project.save
puts "CastReader Widget and shared App Intents are registered."
