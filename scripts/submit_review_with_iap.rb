#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "uri"
require ENV.fetch("ASC_CLIENT_PATH", File.expand_path("~/.codex/skills/submit-castreader-ios-to-app-store/scripts/asc_client.rb"))

TERMINAL_STATES = %w[COMPLETE CANCELED].freeze
SUBMITTED_STATES = %w[WAITING_FOR_REVIEW IN_REVIEW COMPLETING COMPLETE].freeze

options = {
  execute: false,
  timeout: 300,
  interval: 10,
  submission_id: nil,
  iap_version_ids: []
}
parser = OptionParser.new do |option_parser|
  option_parser.banner = "Usage: submit_review.rb APP_ID VERSION_ID [--execute] [--submission-id ID]"
  option_parser.on("--iap-version-id ID") { |value| options[:iap_version_ids] << value }
  option_parser.on("--execute") { options[:execute] = true }
  option_parser.on("--submission-id ID") { |value| options[:submission_id] = value }
  option_parser.on("--timeout SECONDS", Integer) { |value| options[:timeout] = value }
  option_parser.on("--interval SECONDS", Integer) { |value| options[:interval] = value }
end
parser.parse!(ARGV)
app_id = ARGV.fetch(0)
version_id = ARGV.fetch(1)
abort "Duplicate IAP version IDs" unless options[:iap_version_ids].uniq == options[:iap_version_ids]
client = ASCClient.new

def submissions(client, app_id)
  client.get_all("/v1/apps/#{app_id}/reviewSubmissions?filter%5Bplatform%5D=IOS&limit=200")
end

def submission_items(client, submission_id)
  client.get_all("/v1/reviewSubmissions/#{submission_id}/items?include=appStoreVersion,inAppPurchaseVersion&limit=200")
end

def targets_version?(items, version_id)
  items.any? { |item| item.dig("relationships", "appStoreVersion", "data", "id") == version_id }
end

def compact_submission(submission, items)
  {
    id: submission.fetch("id"),
    state: submission.dig("attributes", "state"),
    submittedDate: submission.dig("attributes", "submittedDate"),
    items: items.map do |item|
      {
        id: item.fetch("id"),
        state: item.dig("attributes", "state"),
        appStoreVersionId: item.dig("relationships", "appStoreVersion", "data", "id"),
        inAppPurchaseVersionId: item.dig("relationships", "inAppPurchaseVersion", "data", "id")
      }
    end
  }
end

def targets_iap?(items, id)
  items.any? { |item| item.dig("relationships", "inAppPurchaseVersion", "data", "id") == id }
end

def validate_exact_items!(items, version_id, iap_ids)
  app_count = items.count { |item| item.dig("relationships", "appStoreVersion", "data", "id") == version_id }
  iap_counts = iap_ids.map { |id| items.count { |item| item.dig("relationships", "inAppPurchaseVersion", "data", "id") == id } }
  abort "Pre-submit invariant failed: expected one app and exactly the intended IAP versions" unless app_count == 1 && iap_counts.all? { |n| n == 1 } && items.length == 1 + iap_ids.length
end

all = submissions(client, app_id)
active = all.reject { |submission| TERMINAL_STATES.include?(submission.dig("attributes", "state")) }
audits = active.map { |submission| [submission, submission_items(client, submission.fetch("id"))] }
selected = if options[:submission_id]
  audits.find { |submission, _items| submission.fetch("id") == options[:submission_id] }
else
  matching = audits.select { |_submission, items| targets_version?(items, version_id) }
  abort "Version appears in multiple active review submissions" if matching.length > 1
  matching.first
end

if selected
  submission, items = selected
  unrelated = items.reject do |item|
    item.dig("relationships", "appStoreVersion", "data", "id") == version_id ||
      options[:iap_version_ids].include?(item.dig("relationships", "inAppPurchaseVersion", "data", "id"))
  end
  abort "Selected review submission contains unrelated items" unless unrelated.empty?
  state = submission.dig("attributes", "state")
  if SUBMITTED_STATES.include?(state)
    validate_exact_items!(items, version_id, options[:iap_version_ids])
    version = client.request("GET", "/v1/appStoreVersions/#{version_id}").fetch("data")
    puts JSON.pretty_generate(
      mode: options[:execute] ? "execute" : "dry-run",
      resumed: true,
      writes: [],
      submission: compact_submission(submission, items),
      versionState: version.dig("attributes", "appStoreState") || version.dig("attributes", "appVersionState")
    )
    exit 0
  end
  abort "Selected review submission is #{state}, expected READY_FOR_REVIEW" unless state == "READY_FOR_REVIEW"
else
  unrelated_active = audits.reject do |submission, items|
    submission.dig("attributes", "state") == "READY_FOR_REVIEW" && items.empty?
  end
  unless unrelated_active.empty?
    details = unrelated_active.map { |submission, _| "#{submission.fetch('id')}:#{submission.dig('attributes', 'state')}" }
    abort "Unrelated active review submission exists: #{details.join(', ')}"
  end
  empty = audits.select { |submission, items| submission.dig("attributes", "state") == "READY_FOR_REVIEW" && items.empty? }
  if empty.length == 1
    abort "Empty review submission #{empty.first.first.fetch('id')} exists; rerun with --submission-id to resume it"
  end
  abort "Multiple empty READY_FOR_REVIEW submissions exist" if empty.length > 1
end

planned_writes = []
unless selected
  planned_writes << { method: "POST", path: "/v1/reviewSubmissions" }
end
unless selected && targets_version?(selected.last, version_id)
  planned_writes << { method: "POST", path: "/v1/reviewSubmissionItems", appStoreVersionId: version_id }
end
options[:iap_version_ids].each do |id|
  next if selected && targets_iap?(selected.last, id)
  planned_writes << { method: "POST", path: "/v1/reviewSubmissionItems", inAppPurchaseVersionId: id }
end
planned_writes << { method: "PATCH", path: "/v1/reviewSubmissions/<id>", submitted: true }

unless options[:execute]
  puts JSON.pretty_generate(
    mode: "dry-run",
    selectedSubmission: selected && compact_submission(selected.first, selected.last),
    plannedWrites: planned_writes
  )
  exit 0
end

unless selected
  create_payload = {
    data: {
      type: "reviewSubmissions",
      attributes: { platform: "IOS" },
      relationships: { app: { data: { type: "apps", id: app_id } } }
    }
  }
  begin
    submission = client.request("POST", "/v1/reviewSubmissions", create_payload).fetch("data")
  rescue ASCError => error
    raise unless error.ambiguous_write

    candidates = submissions(client, app_id).reject do |item|
      TERMINAL_STATES.include?(item.dig("attributes", "state"))
    end.select do |item|
      item.dig("attributes", "state") == "READY_FOR_REVIEW" && submission_items(client, item.fetch("id")).empty?
    end
    abort "Review submission create result is ambiguous; found #{candidates.length} resumable empty submissions" unless candidates.length == 1
    submission = candidates.first
  end
  selected = [submission, submission_items(client, submission.fetch("id"))]
end

submission, items = selected
submission_id = submission.fetch("id")
unless targets_version?(items, version_id)
  item_payload = {
    data: {
      type: "reviewSubmissionItems",
      relationships: {
        reviewSubmission: { data: { type: "reviewSubmissions", id: submission_id } },
        appStoreVersion: { data: { type: "appStoreVersions", id: version_id } }
      }
    }
  }
  begin
    client.request("POST", "/v1/reviewSubmissionItems", item_payload)
  rescue ASCError => error
    raise unless error.ambiguous_write && targets_version?(submission_items(client, submission_id), version_id)
  end
end

options[:iap_version_ids].each do |id|
  next if targets_iap?(submission_items(client, submission_id), id)
  payload = {
    data: {
      type: "reviewSubmissionItems",
      relationships: {
        reviewSubmission: { data: { type: "reviewSubmissions", id: submission_id } },
        inAppPurchaseVersion: { data: { type: "inAppPurchaseVersions", id: id } }
      }
    }
  }
  begin
    client.request("POST", "/v1/reviewSubmissionItems", payload)
  rescue ASCError => error
    raise unless error.ambiguous_write && targets_iap?(submission_items(client, submission_id), id)
  end
end
items = submission_items(client, submission_id)
validate_exact_items!(items, version_id, options[:iap_version_ids])
submission = client.request("GET", "/v1/reviewSubmissions/#{submission_id}").fetch("data")
abort "Submission is no longer READY_FOR_REVIEW" unless submission.dig("attributes", "state") == "READY_FOR_REVIEW"

submit_payload = {
  data: {
    type: "reviewSubmissions",
    id: submission_id,
    attributes: { submitted: true }
  }
}
begin
  client.request("PATCH", "/v1/reviewSubmissions/#{submission_id}", submit_payload)
rescue ASCError => error
  raise unless error.ambiguous_write
end

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
loop do
  submission = client.request("GET", "/v1/reviewSubmissions/#{submission_id}").fetch("data")
  state = submission.dig("attributes", "state")
  warn "Review submission #{submission_id}: #{state}"
  break unless state == "READY_FOR_REVIEW"

  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  abort "Timed out after #{options[:timeout]}s; re-run to resume/read back safely" if elapsed >= options[:timeout]
  sleep options[:interval]
end

state = submission.dig("attributes", "state")
abort "Review submission ended in unexpected state #{state}" unless SUBMITTED_STATES.include?(state)
version = client.request("GET", "/v1/appStoreVersions/#{version_id}").fetch("data")
puts JSON.pretty_generate(
  mode: "execute",
  resumed: !planned_writes.first || planned_writes.first[:method] != "POST",
  submission: compact_submission(submission, submission_items(client, submission_id)),
  iapVersions: options[:iap_version_ids].map do |id|
    item = client.request("GET", "/v1/inAppPurchaseVersions/#{id}").fetch("data")
    { id: id, state: item.dig("attributes", "state") }
  end,
  version: {
    id: version.fetch("id"),
    version: version.dig("attributes", "versionString"),
    state: version.dig("attributes", "appStoreState") || version.dig("attributes", "appVersionState"),
    releaseType: version.dig("attributes", "releaseType")
  }
)
