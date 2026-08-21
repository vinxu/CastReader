#!/usr/bin/env ruby
# 登记 PhotoOCRCache.swift 到 app target（FileRef + Group + Sources phase）。幂等。
require 'xcodeproj'

project = Xcodeproj::Project.open('CastReader.xcodeproj')
target = project.targets.find { |t| t.name == 'CastReader' }
abort 'no CastReader target' unless target

additions = { 'CastReader/Services/PhotoOCRCache.swift' => 'HistoryStore.swift' }

additions.each do |rel, sibling|
  name = File.basename(rel)
  if project.files.any? { |f| f.display_name == name }
    puts "skip #{name} (already registered)"
    next
  end
  sib = project.files.find { |f| f.display_name == sibling }
  abort "sibling #{sibling} not found for #{name}" unless sib
  group = sib.parent
  ref = group.new_reference(name)
  target.add_file_references([ref])
  puts "added #{name} to group '#{group.display_name}'"
end

project.save
puts 'saved project'
