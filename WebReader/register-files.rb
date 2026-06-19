#!/usr/bin/env ruby
# 登记 WebReader 相关新文件到 CastReader.xcodeproj（传统 pbxproj objectVersion 55）。
# 用法（仓库根）：ruby WebReader/register-files.rb
require 'xcodeproj'

project = Xcodeproj::Project.open('CastReader.xcodeproj')
target = project.targets.find { |t| t.name == 'CastReader' } or abort 'no CastReader target'
src = project.main_group['CastReader'] or abort 'no CastReader group'

def subgroup(parent, name)
  parent.children.find { |c| c.display_name == name && c.is_a?(Xcodeproj::Project::Object::PBXGroup) } ||
    parent.new_group(name, name)
end

def add_swift(target, group, basename)
  if group.children.any? { |c| c.display_name == basename }
    puts "skip (exists): #{basename}"; return
  end
  ref = group.new_reference(basename)
  target.source_build_phase.add_file_reference(ref)
  puts "added swift: #{basename}"
end

models   = subgroup(src, 'Models')
services = subgroup(src, 'Services')
views    = subgroup(src, 'Views')
reader   = subgroup(views, 'Reader')
utils    = subgroup(src, 'Utils')

add_swift(target, models,   'WebReaderProtocol.swift')
add_swift(target, services, 'WebReaderBridge.swift')
add_swift(target, reader,   'WebReaderView.swift')
add_swift(target, utils,    'LanguageDetector.swift')

# WebAssets 作为蓝色 folder reference（整目录原样进 app bundle Resources）
if src.children.any? { |c| c.display_name == 'WebAssets' }
  puts 'skip WebAssets (exists)'
else
  fref = src.new_reference('WebAssets')
  fref.last_known_file_type = 'folder'
  fref.source_tree = '<group>'
  target.resources_build_phase.add_file_reference(fref)
  puts 'added WebAssets folder reference'
end

project.save
puts 'saved project.'
