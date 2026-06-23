#!/usr/bin/env ruby
# 登记测试文件到 CastReaderTests target。幂等。
require 'xcodeproj'

project = Xcodeproj::Project.open('CastReader.xcodeproj')
target = project.targets.find { |t| t.name == 'CastReaderTests' }
abort 'no CastReaderTests target' unless target

name = 'EpubNativeEngineTests.swift'
if project.files.any? { |f| f.display_name == name }
  puts "skip #{name} (already registered)"
else
  sib = project.files.find { |f| f.display_name == 'EvalTests.swift' }
  abort 'sibling EvalTests.swift not found' unless sib
  group = sib.parent
  ref = group.new_reference(name)
  target.add_file_references([ref])
  puts "added #{name} to group '#{group.display_name}'"
end

project.save
puts 'saved project'
