#!/usr/bin/env ruby
# 登记 Kindle 加固相关的新增源文件到对应 target（FileRef + BuildFile + Group + Sources phase）。幂等。
# 用法：ruby scripts/add_kindle_hardening_files.rb
require 'xcodeproj'

project = Xcodeproj::Project.open('CastReader.xcodeproj')
app = project.targets.find { |t| t.name == 'CastReader' }
tests = project.targets.find { |t| t.name == 'CastReaderTests' }
abort 'no CastReader target' unless app

# 新文件 => [同组已有文件（借其 group 定位）, 归属 target]
additions = {
  'CastReader/Services/WebViewBoundedEvaluate.swift' => ['TTSEndpoint.swift', app],
  'CastReader/Services/ReaderReadinessWatchdog.swift' => ['TTSEndpoint.swift', app],
  'CastReaderTests/ReaderReadinessWatchdogTests.swift' => ['EvalTests.swift', tests]
}

additions.each do |rel, (sibling, target)|
  name = File.basename(rel)
  unless File.exist?(rel)
    puts "skip #{name} (file not on disk yet)"
    next
  end
  if project.files.any? { |f| f.display_name == name }
    puts "skip #{name} (already registered)"
    next
  end
  abort "no target for #{name}" unless target
  sib = project.files.find { |f| f.display_name == sibling }
  abort "sibling #{sibling} not found for #{name}" unless sib
  group = sib.parent
  ref = group.new_reference(name)
  target.add_file_references([ref])
  puts "added #{name} to group '#{group.display_name}' target '#{target.name}'"
end

project.save
puts 'saved project'
