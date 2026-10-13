#!/usr/bin/env ruby
# frozen_string_literal: true

require "xcodeproj"

project_path = File.expand_path("../CastReader.xcodeproj", __dir__)
project = Xcodeproj::Project.open(project_path)
target = project.targets.find { |item| item.name == "CastReader" }
abort "CastReader target not found" unless target

def ensure_group(parent, name)
  parent.groups.find { |group| group.display_name == name } || parent.new_group(name, name)
end

app_group = project.main_group.groups.find { |group| group.display_name == "CastReader" }
abort "CastReader group not found" unless app_group

group_map = {
  "Models" => ensure_group(app_group, "Models"),
  "Services" => ensure_group(app_group, "Services"),
  "Utils" => ensure_group(app_group, "Utils"),
  "ViewModels" => ensure_group(app_group, "ViewModels"),
  "Views/CloudStorage" => ensure_group(ensure_group(app_group, "Views"), "CloudStorage")
}

sources = {
  "Models" => %w[CloudStorageModels.swift],
  "Services" => %w[
    CloudStorageProvider.swift
    CloudConnectionStore.swift
    CloudImportCoordinator.swift
    GoogleDriveProvider.swift
    CloudStorageCenter.swift
    CloudHistoryReopenService.swift
  ],
  "Utils" => %w[DocumentImportPipeline.swift],
  "ViewModels" => %w[CloudStorageFlowViewModel.swift],
  "Views/CloudStorage" => %w[CloudStorageViews.swift]
}

sources.each do |group_name, names|
  group = group_map.fetch(group_name)
  names.each do |name|
    reference = project.files.find { |file| file.path == name } || group.new_reference(name)
    unless target.source_build_phase.files_references.include?(reference)
      target.add_file_references([reference])
    end
  end
end

resource = project.files.find { |file| file.path == "CloudStorage.xcstrings" } ||
  app_group.new_reference("CloudStorage.xcstrings")
unless target.resources_build_phase.files_references.include?(resource)
  target.resources_build_phase.add_file_reference(resource)
end

project.files.select { |file| file.path == "UnshippedIntegrationStubs.swift" }.each do |file|
  target.source_build_phase.files.select { |build| build.file_ref == file }.each(&:remove_from_project)
end

%w[DropboxProvider.swift OneDriveProvider.swift].each do |name|
  project.files.select { |file| file.path == name }.each do |file|
    target.source_build_phase.files.select { |build| build.file_ref == file }.each(&:remove_from_project)
  end
end

test_target = project.targets.find { |item| item.name == "CastReaderTests" }
test_group = project.main_group.groups.find { |group| group.display_name == "CastReaderTests" }
if test_target && test_group
  test_reference = project.files.find { |file| file.path == "GoogleDriveProviderTests.swift" } ||
    test_group.new_reference("GoogleDriveProviderTests.swift")
  unless test_target.source_build_phase.files_references.include?(test_reference)
    test_target.add_file_references([test_reference])
  end
end

project.save
