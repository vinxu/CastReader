#!/usr/bin/env ruby
# 登记 EPUB native 新增源文件到 app target（FileRef + Group + Sources phase）。幂等。
# 用法：ruby add_epub_files.rb（新文件清单写死在下方）
require 'xcodeproj'

project = Xcodeproj::Project.open('CastReader.xcodeproj')
target = project.targets.find { |t| t.name == 'CastReader' }
abort 'no CastReader target' unless target

# 新文件 => 同组已有文件（借其 group 定位，路径语义最稳）
additions = {
  'CastReader/Utils/HtmlParser.swift' => 'DocumentBuilder.swift',
  'CastReader/Services/EpubNativeEngine.swift' => 'APIService.swift'
}

additions.each do |rel, sibling|
  name = File.basename(rel)
  if project.files.any? { |f| f.display_name == name }
    puts "skip #{name} (already registered)"
    next
  end
  sib = project.files.find { |f| f.display_name == sibling }
  abort "sibling #{sibling} not found for #{name}" unless sib
  group = sib.parent
  ref = group.new_reference(name)            # 相对组路径 → CastReader/<Group>/<name>
  target.add_file_references([ref])          # 加入 Sources build phase
  puts "added #{name} to group '#{group.display_name}'"
end

project.save
puts 'saved project'
