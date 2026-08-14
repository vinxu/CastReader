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
kotlin_names = kotlin_event_section.scan(/([A-Z_]+)\(\s*"([^"]+)"/).to_h
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
# 副本允许携带各自发布线的超前内容（中国区元数据、后端先行放开的白名单值等），
# 但 canonical 已声明的部分必须完整存在且逐字段一致，防止事件契约在分发中漂移。
copy_paths.each do |path|
  next unless path.file?
  copy = JSON.parse(path.read)
  problems = []

  if copy.dig("transport", "endpoint") != canonical_json.dig("transport", "endpoint")
    problems << "transport.endpoint drift"
  end

  copy_events = (copy["events"] || []).to_h { |event| [event["name"], event] }
  (copy_events.keys.to_set - canonical_json.fetch("events").map { |event| event.fetch("name") }.to_set)
    .to_a.sort.each { |name| problems << "event only in copy: #{name}" }
  canonical_json.fetch("events").each do |event|
    name = event.fetch("name")
    copy_event = copy_events[name]
    if copy_event.nil?
      problems << "missing event: #{name}"
      next
    end
    %w[legacy_event product_area legacy_event_by_result].each do |key|
      next if copy_event[key] == event[key]
      problems << "event #{name} #{key} drift"
    end
    %w[required_properties optional_properties].each do |key|
      next if (copy_event[key] || []).to_set == event.fetch(key).to_set
      problems << "event #{name} #{key} drift: copy=#{(copy_event[key] || []).sort.inspect} canonical=#{event.fetch(key).sort.inspect}"
    end
  end

  canonical_json.fetch("value_domains").each do |domain, values|
    missing = values.to_set - (copy.dig("value_domains", domain) || []).to_set
    problems << "value domain #{domain} missing #{missing.to_a.sort.inspect}" unless missing.empty?
  end

  %w[required_envelope_fields privacy_forbidden_keys].each do |key|
    missing = canonical_json.fetch(key).to_set - (copy[key] || []).to_set
    problems << "#{key} missing #{missing.to_a.sort.inspect}" unless missing.empty?
  end

  next if problems.empty?
  warn "analytics contract copy incompatible: #{path}"
  problems.each { |problem| warn "  #{problem}" }
  exit 1
end

event_count = contract.length
puts "mobile analytics contract verified: JSON=#{event_count} iOS=#{swift_definitions.length} Android=#{kotlin_definitions.length}; event names and required/optional properties match"
