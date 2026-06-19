#!/usr/bin/env ruby
require 'xcodeproj'
project = Xcodeproj::Project.open('CastReader.xcodeproj')
target = project.targets.find { |t| t.name == 'CastReaderTests' } or abort 'no CastReaderTests target'
group = project.main_group['CastReaderTests'] or abort 'no CastReaderTests group'
name = 'WebReaderEvalTests.swift'
if group.children.any? { |c| c.display_name == name }
  puts "skip (exists): #{name}"
else
  ref = group.new_reference(name)
  target.source_build_phase.add_file_reference(ref)
  puts "added test: #{name}"
end
project.save
puts 'saved.'
