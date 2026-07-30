#!/usr/bin/env ruby
# Register Kobo/live-web adapter files in the traditional CastReader pbxproj.
# Idempotent: existing references/build files are left untouched.

require 'xcodeproj'

project = Xcodeproj::Project.open('CastReader.xcodeproj')
app = project.targets.find { |target| target.name == 'CastReader' } or
  abort 'no CastReader target'
tests = project.targets.find { |target| target.name == 'CastReaderTests' } or
  abort 'no CastReaderTests target'
source_root = project.main_group['CastReader'] or abort 'no CastReader group'
tests_root = project.main_group['CastReaderTests'] or
  abort 'no CastReaderTests group'

def subgroup(parent, name)
  parent.children.find do |child|
    child.display_name == name &&
      child.is_a?(Xcodeproj::Project::Object::PBXGroup)
  end || parent.new_group(name, name)
end

def add_swift(target, group, basename)
  existing = group.children.find { |child| child.display_name == basename }
  reference = existing || group.new_reference(basename)
  unless target.source_build_phase.files_references.include?(reference)
    target.source_build_phase.add_file_reference(reference)
    puts "added #{target.name}: #{basename}"
  end
end

models = subgroup(source_root, 'Models')
services = subgroup(source_root, 'Services')
views = subgroup(source_root, 'Views')
kobo_views = subgroup(views, 'Kobo')

add_swift(app, models, 'KoboModels.swift')
add_swift(app, services, 'LiveWebPlatform.swift')
add_swift(app, services, 'KoboWebScripts.swift')
add_swift(app, services, 'KoboLibraryStore.swift')
add_swift(app, kobo_views, 'KoboLibraryViews.swift')
add_swift(tests, tests_root, 'KoboContractTests.swift')

project.save
puts 'saved CastReader.xcodeproj'
