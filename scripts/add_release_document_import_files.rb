#!/usr/bin/env ruby
# frozen_string_literal: true

require "xcodeproj"

project = Xcodeproj::Project.open(File.expand_path("../CastReader.xcodeproj", __dir__))
target = project.targets.find { |candidate| candidate.name == "CastReader" }
abort "CastReader target not found" unless target

{
  "Models" => "CloudStorageModels.swift",
  "Utils" => ["DocumentImportPipeline.swift", "UnshippedIntegrationStubs.swift"]
}.each do |group_name, filenames|
  group = project.main_group.find_subpath("CastReader/#{group_name}", false)
  abort "Missing group CastReader/#{group_name}" unless group
  Array(filenames).each do |filename|
    reference = group.files.find { |file| file.path == filename } || group.new_reference(filename)
    target.add_file_references([reference]) if reference.build_files.empty?
  end
end

project.save
