#!/usr/bin/env ruby

require "json"
require "pathname"
require "set"

root = Pathname(__dir__).parent
android_root = Pathname(ENV.fetch("CASTREADER_ANDROID_ROOT", root.parent.join("CastReader-Android").to_s))

contract_rows = JSON.parse(root.join("docs/analytics/mobile-events-v2.json").read).fetch("events")
contract = contract_rows.to_h do |event|
  [
    event.fetch("name"),
    [event.fetch("required_properties").to_set, event.fetch("optional_properties").to_set]
  ]
end

swift = root.join("CastReader/Services/ProductAnalytics.swift").read
swift_event_section = swift.split("enum AnalyticsProductArea", 2).first
swift_names = swift_event_section.scan(/case\s+(\w+)\s*=\s*"([^"]+)"/).to_h
swift_definitions = swift.scan(
  /\.(\w+):\s*\.init\(\s*required:\s*\[([^\]]*)\],\s*optional:\s*\[([^\]]*)\]\s*\)/m
).to_h do |name, required, optional|
  [
    swift_names.fetch(name),
    [required.scan(/"([^"]+)"/).flatten.to_set, optional.scan(/"([^"]+)"/).flatten.to_set]
  ]
end

kotlin = android_root.join("app/src/main/java/com/same/castreader/analytics/AnalyticsContract.kt").read
kotlin_event_section = kotlin.split("enum class AnalyticsProductArea", 2).first
kotlin_names = kotlin_event_section.scan(/([A-Z_]+)\("([^"]+)"/).to_h
kotlin_definitions = kotlin.scan(
  /AnalyticsEventName\.([A-Z_]+)\s+to\s+AnalyticsDefinition\(\s*setOf\(([^)]*)\)(?:,\s*setOf\(([^)]*)\))?\s*\)/
).to_h do |name, required, optional|
  [
    kotlin_names.fetch(name),
    [
      required.scan(/"([^"]+)"/).flatten.to_set,
      (optional || "").scan(/"([^"]+)"/).flatten.to_set
    ]
  ]
end

def report_contract_drift(label, actual, expected)
  return if actual == expected

  warn "#{label} analytics event/property contract mismatch"
  (expected.keys - actual.keys).sort.each { |name| warn "  missing event: #{name}" }
  (actual.keys - expected.keys).sort.each { |name| warn "  extra event: #{name}" }
  (actual.keys & expected.keys).sort.each do |name|
    next if actual.fetch(name) == expected.fetch(name)
    expected_required, expected_optional = expected.fetch(name)
    actual_required, actual_optional = actual.fetch(name)
    warn "  #{name} required missing=#{(expected_required - actual_required).to_a.sort.inspect} extra=#{(actual_required - expected_required).to_a.sort.inspect}"
    warn "  #{name} optional missing=#{(expected_optional - actual_optional).to_a.sort.inspect} extra=#{(actual_optional - expected_optional).to_a.sort.inspect}"
  end
  exit 1
end

report_contract_drift("iOS", swift_definitions, contract)
report_contract_drift("Android", kotlin_definitions, contract)

canonical_json = JSON.parse(root.join("docs/analytics/mobile-events-v2.json").read)
copy_paths = [
  android_root.join("app/src/main/assets/contracts/mobile-events-v2.json"),
  root.parent.join("MyProject/readout-web/docs/contracts/mobile-events-v2.json")
]
copy_paths.each do |path|
  next unless path.file?
  next if JSON.parse(path.read) == canonical_json
  warn "analytics contract copy drift: #{path}"
  exit 1
end

event_count = contract.length
puts "mobile analytics contract verified: JSON=#{event_count} iOS=#{swift_definitions.length} Android=#{kotlin_definitions.length}; event names and required/optional properties match"
