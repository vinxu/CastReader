#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "pathname"

root = Pathname(__dir__).parent
resources = root.join("CastReader Safari Extension", "Resources")
manifest = JSON.parse(resources.join("manifest.json").read)
expected_locales = %w[de en es fr hi it ja pt_BR zh_CN]
locale_files = resources.join("_locales").children
  .select { |path| path.join("messages.json").file? }
  .sort_by { |path| path.basename.to_s }

abort "No Safari extension locales found" if locale_files.empty?
actual_locales = locale_files.map { |path| path.basename.to_s }
abort "Safari locale set mismatch: #{actual_locales.inspect}" unless actual_locales == expected_locales.sort

message_reference = /\A__MSG_([A-Za-z0-9_]+)__\z/
referenced_keys = []
walk = lambda do |value|
  case value
  when Hash
    value.each_value { |child| walk.call(child) }
  when Array
    value.each { |child| walk.call(child) }
  when String
    match = message_reference.match(value)
    referenced_keys << match[1] if match
  end
end
walk.call(manifest)
referenced_keys.uniq!

manifest_name = manifest.fetch("name")
name_match = message_reference.match(manifest_name)
abort "Safari manifest name must be localized with __MSG_key__" unless name_match

expected_references = [
  ["name", "name"],
  ["description", "description"],
  ["browser_action.default_title", "name"]
]

manifest_references = []
reference_walk = lambda do |value, path|
  case value
  when Hash
    value.each { |key, child| reference_walk.call(child, path + [key]) }
  when Array
    value.each_with_index { |child, index| reference_walk.call(child, path + [index]) }
  when String
    match = message_reference.match(value)
    manifest_references << [path.join("."), match[1]] if match
  end
end
reference_walk.call(manifest, [])

unless manifest_references.sort == expected_references.sort
  abort "Safari manifest localization contract mismatch: #{manifest_references.inspect}"
end

errors = []
key_sets = []

locale_files.each do |locale_path|
  locale = locale_path.basename.to_s
  messages_path = locale_path.join("messages.json")
  messages = JSON.parse(messages_path.read)
  key_sets << messages.keys.sort

  if messages.key?("extName") || messages.key?("extDescription")
    errors << "#{locale}: stale extName/extDescription keys"
  end

  referenced_keys.each do |key|
    message = messages.dig(key, "message")
    if !message.is_a?(String) || message.strip.empty?
      errors << "#{locale}: missing non-empty message for #{key}"
    end
  end

  name = messages.dig("name", "message")
  description = messages.dig("description", "message")
  edge_name = messages.dig("edgeExtName", "message")

  errors << "#{locale}: name is #{name.length} characters (maximum 40)" if name.is_a?(String) && name.length > 40
  errors << "#{locale}: description is #{description.length} characters (maximum 112)" if description.is_a?(String) && description.length > 112
  errors << "#{locale}: edgeExtName is #{edge_name.length} characters (maximum 40)" if edge_name.is_a?(String) && edge_name.length > 40
end

errors << "Safari locale message key sets differ" unless key_sets.uniq.length == 1
abort errors.join("\n") unless errors.empty?

puts "Safari extension locale validation passed (#{locale_files.length} locales; name <= 40; description <= 112)"
