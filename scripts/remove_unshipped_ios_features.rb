#!/usr/bin/env ruby
# frozen_string_literal: true

require "xcodeproj"

project_path = File.expand_path("../CastReader.xcodeproj", __dir__)
project = Xcodeproj::Project.open(project_path)

unshipped_files = %w[
  CloudStorageModels.swift
  CloudStorageProvider.swift
  CloudConnectionStore.swift
  CloudImportCoordinator.swift
  GoogleDriveProvider.swift
  DropboxProvider.swift
  OneDriveProvider.swift
  CloudStorageCenter.swift
  CloudHistoryReopenService.swift
  CloudStorageFlowViewModel.swift
  CloudStorageViews.swift
  DocumentImportPipeline.swift
  CloudStorage.xcstrings
  MSAL-LICENSE.txt
  CloudStorageCoreTests.swift
  GoogleDriveProviderTests.swift
  DropboxProviderTests.swift
  OneDriveProviderTests.swift
  CloudImportIntegrationTests.swift
  CloudHistoryTests.swift
  CloudHistoryReopenServiceTests.swift
]

project.files.select { |file| unshipped_files.include?(file.path) }.each do |file|
  file.build_files.each(&:remove_from_project)
  file.remove_from_project
end

project.targets.each do |target|
  target.package_product_dependencies.select do |dependency|
    %w[SwiftyDropbox MSAL].include?(dependency.product_name)
  end.each do |dependency|
    target.frameworks_build_phase.files.select do |build_file|
      build_file.product_ref == dependency
    end.each(&:remove_from_project)
    dependency.remove_from_project
  end
end

project.root_object.package_references.select do |package|
  %w[SwiftyDropbox MSALBinaryPackage].any? { |name| package.display_name.include?(name) }
end.each(&:remove_from_project)

project.save
