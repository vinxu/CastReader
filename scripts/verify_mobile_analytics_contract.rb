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
  /\.(\w+):\s*\.init\(required:\s*\[([^\]]*)\],\s*optional:\s*\[([^\]]*)\]\)/
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
  /AnalyticsEventName\.([A-Z_]+)\s+to\s+AnalyticsDefinition\(setOf\(([^)]*)\)(?:,\s*setOf\(([^)]*)\))?\)/
).to_h do |name, required, optional|
  [
    kotlin_names.fetch(name),
    [
      required.scan(/"([^"]+)"/).flatten.to_set,
      (optional || "").scan(/"([^"]+)"/).flatten.to_set
    ]
  ]
end

abort "iOS analytics event/property contract mismatch" unless swift_definitions == contract
abort "Android analytics event/property contract mismatch" unless kotlin_definitions == contract

puts "mobile analytics contract verified: JSON=19 iOS=19 Android=19; event names and required/optional properties match"
