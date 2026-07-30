#!/usr/bin/env ruby
# 登记 Google Play 图书适配的新源文件到 CastReader.xcodeproj（传统 pbxproj，objectVersion 55）。
# 用法（仓库根）：ruby scripts/add_google_books_files.rb
require 'xcodeproj'

project = Xcodeproj::Project.open('CastReader.xcodeproj')
app = project.targets.find { |t| t.name == 'CastReader' } or abort 'no CastReader target'
tests = project.targets.find { |t| t.name == 'CastReaderTests' } or abort 'no CastReaderTests target'
src = project.main_group['CastReader'] or abort 'no CastReader group'
tests_group = project.main_group['CastReaderTests'] or abort 'no CastReaderTests group'

def subgroup(parent, name)
  parent.children.find { |c| c.display_name == name && c.is_a?(Xcodeproj::Project::Object::PBXGroup) } ||
    parent.new_group(name, name)
end

def add_swift(target, group, basename)
  if group.children.any? { |c| c.display_name == basename }
    puts "skip (exists): #{basename}"
    return
  end
  ref = group.new_reference(basename)
  target.source_build_phase.add_file_reference(ref)
  puts "added: #{basename}"
end

models      = subgroup(src, 'Models')
services    = subgroup(src, 'Services')
views       = subgroup(src, 'Views')
googlebooks = subgroup(views, 'GoogleBooks')

add_swift(app, models,      'GoogleBooksModels.swift')
add_swift(app, services,    'GoogleBooksWebScripts.swift')
add_swift(app, services,    'GoogleBooksLibraryStore.swift')
add_swift(app, googlebooks, 'GoogleBooksLibraryViews.swift')
add_swift(tests, tests_group, 'GoogleBooksContractTests.swift')

project.save
puts 'saved project.'
