#!/usr/bin/env ruby
# 登记 Kindle 书架扫描策略及其测试。幂等。
require 'xcodeproj'

project = Xcodeproj::Project.open('CastReader.xcodeproj')
app = project.targets.find { |t| t.name == 'CastReader' }
tests = project.targets.find { |t| t.name == 'CastReaderTests' }
abort 'missing target' unless app && tests

# 新文件 => [同组已有文件, 目标 target]
additions = {
  'KindleShelfScanPolicy.swift'      => ['KindleModels.swift', app],
  'KindleShelfScanPolicyTests.swift' => ['KindleStorefrontTests.swift', tests]
}

additions.each do |name, (sibling, target)|
  if project.files.any? { |f| f.display_name == name }
    puts "skip #{name} (already registered)"
    next
  end
  sib = project.files.find { |f| f.display_name == sibling }
  abort "sibling #{sibling} not found for #{name}" unless sib
  group = sib.parent
  ref = group.new_reference(name)
  target.add_file_references([ref])
  puts "added #{name} -> group '#{group.display_name}', target '#{target.name}'"
end

project.save
puts 'saved project'
