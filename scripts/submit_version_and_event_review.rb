#!/usr/bin/env ruby
# frozen_string_literal: true

# Safely submit one App Store version and one in-app event in the same modern
# App Store Connect review submission.
#
# The default mode is a read-only dry run. It audits current review submissions
# and their items, then prints the exact writes that would be needed. No write
# request can leave this process unless --execute is present.

require "base64"
require "json"
require "net/http"
require "openssl"
require "optparse"
require "time"
require "uri"

BASE_URL = ENV.fetch("ASC_BASE_URL", "https://api.appstoreconnect.apple.com")
TERMINAL_SUBMISSION_STATES = %w[COMPLETE].freeze
SUBMITTED_SUBMISSION_STATES = %w[
  WAITING_FOR_REVIEW
  IN_REVIEW
  UNRESOLVED_ISSUES
  CANCELING
  COMPLETING
  COMPLETE
].freeze
SUCCESSFUL_READBACK_STATES = %w[
  WAITING_FOR_REVIEW
  IN_REVIEW
  COMPLETING
  COMPLETE
].freeze

# Requesting these fields and includes makes each review item expose the exact
# reviewable resource it owns. The experiment relationships are how a PPO-only
# review submission is identified without changing or withdrawing it.
ITEM_RELATIONSHIPS = %w[
  appStoreVersion
  appCustomProductPageVersion
  appStoreVersionExperiment
  appStoreVersionExperimentV2
  appEvent
  backgroundAssetVersion
  gameCenterAchievementVersion
  gameCenterActivityVersion
  gameCenterChallengeVersion
  gameCenterLeaderboardSetVersion
  gameCenterLeaderboardVersion
  inAppPurchaseVersion
  subscriptionVersion
  subscriptionGroupVersion
].freeze
PPO_RELATIONSHIPS = %w[
  appStoreVersionExperiment
  appStoreVersionExperimentV2
].freeze
TARGET_TYPES = {
  "appStoreVersion" => "appStoreVersions",
  "appEvent" => "appEvents"
}.freeze

class ToolError < StandardError; end
class SafetyError < ToolError; end
class ConflictError < ToolError; end

class APIError < ToolError
  attr_reader :status, :method, :path, :document

  def initialize(status:, method:, path:, document:)
    @status = status
    @method = method
    @path = path
    @document = document
    super("App Store Connect #{method} #{path} failed with HTTP #{status}")
  end
end

Options = Struct.new(
  :app_id,
  :version_id,
  :event_id,
  :submission_id,
  :execute,
  :explicit_dry_run,
  :poll_interval,
  :timeout,
  keyword_init: true
)

def parse_options(argv)
  options = Options.new(
    execute: false,
    explicit_dry_run: false,
    poll_interval: 10,
    timeout: 600
  )

  parser = OptionParser.new do |opts|
    opts.banner = <<~USAGE
      Usage: ruby #{File.basename($PROGRAM_NAME)} \
        --app-id APP_ID --version-id VERSION_ID --event-id EVENT_ID [options]

      Default: read-only dry run. Pass --execute explicitly to create items and submit.
    USAGE

    opts.on("--app-id ID", "App Store Connect app resource ID") { |value| options.app_id = value }
    opts.on("--version-id ID", "App Store version resource ID") { |value| options.version_id = value }
    opts.on("--event-id ID", "In-app event resource ID") { |value| options.event_id = value }
    opts.on(
      "--submission-id ID",
      "Explicitly resume a READY_FOR_REVIEW submission (required for an empty draft)"
    ) { |value| options.submission_id = value }
    opts.on("--execute", "Enable writes; omitted means read-only dry run") { options.execute = true }
    opts.on("--dry-run", "Explicitly select the default read-only mode") { options.explicit_dry_run = true }
    opts.on("--poll-interval SECONDS", Integer, "Polling interval after submit (default: 10)") do |value|
      options.poll_interval = value
    end
    opts.on("--timeout SECONDS", Integer, "Polling timeout after submit (default: 600)") do |value|
      options.timeout = value
    end
    opts.on("-h", "--help", "Show this help") do
      puts opts
      exit 0
    end
  end

  parser.parse!(argv)
  raise ToolError, "Unexpected positional arguments: #{argv.join(' ')}" unless argv.empty?
  raise ToolError, "--execute and --dry-run are mutually exclusive" if options.execute && options.explicit_dry_run

  {
    "--app-id" => options.app_id,
    "--version-id" => options.version_id,
    "--event-id" => options.event_id
  }.each do |flag, value|
    raise ToolError, "Missing required #{flag}" if value.nil? || value.empty?
  end

  [options.app_id, options.version_id, options.event_id, options.submission_id].compact.each do |value|
    unless value.match?(/\A[A-Za-z0-9-]+\z/)
      raise ToolError, "Unsafe resource ID: #{value.inspect}"
    end
  end
  unless (1..60).cover?(options.poll_interval)
    raise ToolError, "--poll-interval must be between 1 and 60 seconds"
  end
  unless (10..3_600).cover?(options.timeout)
    raise ToolError, "--timeout must be between 10 and 3600 seconds"
  end

  options
rescue OptionParser::ParseError => error
  raise ToolError, error.message
end

def base64url(value)
  Base64.urlsafe_encode64(value, padding: false)
end

class ASCClient
  def initialize(base_url:, allow_writes:)
    @base_uri = URI(base_url)
    @allow_writes = allow_writes
    @key_id = ENV.fetch("ASC_KEY_ID", "6QN4G1IJDEP1")
    @key_path = ENV.fetch(
      "ASC_KEY_PATH",
      File.expand_path("~/.appstoreconnect/private_keys/AuthKey_#{@key_id}.p8")
    )
    @issuer_id = ENV["ASC_ISSUER_ID"]

    unless @base_uri.is_a?(URI::HTTPS) ||
           (@base_uri.host == "127.0.0.1" || @base_uri.host == "localhost")
      raise SafetyError, "ASC_BASE_URL must use HTTPS (localhost is allowed for tests)"
    end
    raise ToolError, "ASC private key not found: #{@key_path}" unless File.file?(@key_path)
  end

  def request(method, path, payload = nil)
    method = method.to_s.upcase
    if method != "GET" && !@allow_writes
      raise SafetyError, "Blocked #{method} #{path}: --execute was not supplied"
    end
    unless %w[GET POST PATCH].include?(method)
      raise SafetyError, "Unsupported HTTP method #{method}; this tool never deletes resources"
    end

    uri = resolve_uri(path)
    request_class = {
      "GET" => Net::HTTP::Get,
      "POST" => Net::HTTP::Post,
      "PATCH" => Net::HTTP::Patch
    }.fetch(method)
    request = request_class.new(uri)
    request["Authorization"] = "Bearer #{jwt}"
    request["Content-Type"] = "application/json"
    request.body = JSON.generate(payload) if payload

    response = Net::HTTP.start(
      uri.hostname,
      uri.port,
      use_ssl: uri.scheme == "https",
      open_timeout: 30,
      read_timeout: 90
    ) { |http| http.request(request) }
    document = if response.body.nil? || response.body.empty?
      {}
    else
      JSON.parse(response.body)
    end
    return document if response.is_a?(Net::HTTPSuccess)

    raise APIError.new(
      status: response.code.to_i,
      method: method,
      path: uri.request_uri,
      document: document
    )
  rescue JSON::ParserError => error
    raise ToolError, "Invalid JSON from App Store Connect for #{method} #{path}: #{error.message}"
  end

  def get_all(path)
    resources = []
    next_path = path
    while next_path
      document = request("GET", next_path)
      data = document.fetch("data")
      raise ToolError, "Expected a resource array from #{next_path}" unless data.is_a?(Array)

      resources.concat(data)
      next_path = document.dig("links", "next")
    end
    resources
  end

  private

  def resolve_uri(path)
    uri = path.start_with?("http://", "https://") ? URI(path) : URI.join(@base_uri.to_s, path)
    unless uri.scheme == @base_uri.scheme && uri.host == @base_uri.host && uri.port == @base_uri.port
      raise SafetyError, "Refusing to send ASC credentials to a different host: #{uri}"
    end
    uri
  end

  def jwt
    now = Time.now.to_i
    header = base64url(JSON.generate(alg: "ES256", kid: @key_id, typ: "JWT"))
    claims = { iat: now, exp: now + 1_000, aud: "appstoreconnect-v1" }
    if @issuer_id.nil? || @issuer_id.empty?
      claims[:sub] = "user"
    else
      claims[:iss] = @issuer_id
    end
    encoded_claims = base64url(JSON.generate(claims))
    signing_input = "#{header}.#{encoded_claims}"
    key = OpenSSL::PKey.read(File.read(@key_path))
    sequence = OpenSSL::ASN1.decode(key.sign("SHA256", signing_input))
    raw_signature = sequence.value.map do |integer|
      hex = integer.value.to_s(16)
      hex = "0#{hex}" if hex.length.odd?
      [hex].pack("H*").rjust(32, "\0")
    end.join
    "#{signing_input}.#{base64url(raw_signature)}"
  end
end

def query_path(path, parameters)
  "#{path}?#{URI.encode_www_form(parameters)}"
end

def resource(type, id: nil, attributes: nil, relationships: nil)
  data = { type: type }
  data[:id] = id if id
  data[:attributes] = attributes if attributes
  data[:relationships] = relationships if relationships
  { data: data }
end

def fetch_targets(client, options)
  version_path = query_path(
    "/v1/appStoreVersions/#{options.version_id}",
    {
      "fields[appStoreVersions]" => "platform,versionString,appStoreState,appVersionState,app",
      "fields[apps]" => "name,bundleId",
      "include" => "app"
    }
  )
  version_document = client.request("GET", version_path)
  version = version_document.fetch("data")
  version_app_id = version.dig("relationships", "app", "data", "id") ||
    version_document.fetch("included", []).find { |item| item["type"] == "apps" }&.fetch("id", nil)
  unless version_app_id == options.app_id
    raise SafetyError,
          "App Store version #{options.version_id} belongs to app #{version_app_id || 'UNKNOWN'}, not #{options.app_id}"
  end
  unless version.dig("attributes", "platform") == "IOS"
    raise SafetyError, "App Store version #{options.version_id} is not an IOS version"
  end

  events_path = query_path(
    "/v1/apps/#{options.app_id}/appEvents",
    {
      "limit" => "200",
      "fields[appEvents]" => "referenceName,eventState,deepLink,badge"
    }
  )
  event = client.get_all(events_path).find { |item| item["id"] == options.event_id }
  unless event
    raise SafetyError, "In-app event #{options.event_id} was not found under app #{options.app_id}"
  end

  {
    appStoreVersion: {
      id: version.fetch("id"),
      versionString: version.dig("attributes", "versionString"),
      state: version.dig("attributes", "appStoreState") || version.dig("attributes", "appVersionState")
    },
    appEvent: {
      id: event.fetch("id"),
      referenceName: event.dig("attributes", "referenceName"),
      state: event.dig("attributes", "eventState"),
      deepLink: event.dig("attributes", "deepLink")
    }
  }
end

def list_submissions(client, app_id)
  path = query_path(
    "/v1/apps/#{app_id}/reviewSubmissions",
    {
      "limit" => "200",
      "filter[platform]" => "IOS",
      "fields[reviewSubmissions]" => "platform,submittedDate,state,items"
    }
  )
  client.get_all(path)
end

def list_submission_items(client, submission_id)
  # Apple rejects a request that includes appStoreVersionExperiment and
  # appStoreVersionExperimentV2 together. Read both generations separately and
  # merge them by review-submission-item ID so PPO detection remains complete.
  legacy_relationships = ITEM_RELATIONSHIPS - ["appStoreVersionExperimentV2"]
  legacy_items = list_submission_items_with_relationships(
    client,
    submission_id,
    legacy_relationships
  )
  v2_items = list_submission_items_with_relationships(
    client,
    submission_id,
    ["appStoreVersionExperimentV2"]
  )

  by_id = legacy_items.to_h { |item| [item.fetch("id"), item] }
  v2_items.each do |item|
    existing = by_id[item.fetch("id")]
    unless existing
      by_id[item.fetch("id")] = item
      next
    end

    existing["relationships"] ||= {}
    existing["relationships"].merge!(item.fetch("relationships", {}))
  end
  by_id.values
end

def list_submission_items_with_relationships(client, submission_id, relationships)
  path = query_path(
    "/v1/reviewSubmissions/#{submission_id}/items",
    {
      "limit" => "200",
      "fields[reviewSubmissionItems]" => (["state"] + relationships).join(","),
      "include" => relationships.join(",")
    }
  )
  client.get_all(path)
end

def relationship_targets(item)
  item.fetch("relationships", {}).each_with_object({}) do |(name, relationship), targets|
    linkage = relationship["data"]
    next unless linkage.is_a?(Hash) && linkage["id"]

    targets[name] = { id: linkage.fetch("id"), type: linkage.fetch("type") }
  end
end

def summarize_item(item)
  {
    id: item.fetch("id"),
    state: item.dig("attributes", "state"),
    targets: relationship_targets(item)
  }
end

def audit_submission(client, submission)
  items = list_submission_items(client, submission.fetch("id"))
  {
    id: submission.fetch("id"),
    state: submission.dig("attributes", "state"),
    submittedDate: submission.dig("attributes", "submittedDate"),
    items: items.map { |item| summarize_item(item) },
    raw: submission
  }
end

def terminal_submission?(submission)
  TERMINAL_SUBMISSION_STATES.include?(submission.dig("attributes", "state"))
end

def target_items(audit, relationship, id)
  audit.fetch(:items).select { |item| item.dig(:targets, relationship, :id) == id }
end

def unrelated_items(audit, options)
  audit.fetch(:items).reject do |item|
    targets = item.fetch(:targets)
    exact_version = targets.keys == ["appStoreVersion"] &&
      targets.dig("appStoreVersion", :id) == options.version_id
    exact_event = targets.keys == ["appEvent"] &&
      targets.dig("appEvent", :id) == options.event_id
    exact_version || exact_event
  end
end

def ppo_only?(audit)
  items = audit.fetch(:items)
  return false if items.empty?

  items.all? do |item|
    targets = item.fetch(:targets)
    !targets.empty? && (targets.keys - PPO_RELATIONSHIPS).empty?
  end
end

def includes_app_version?(audit)
  audit.fetch(:items).any? do |item|
    item.fetch(:targets).key?("appStoreVersion")
  end
end

def parallel_item_only_submission?(audit)
  %w[WAITING_FOR_REVIEW IN_REVIEW COMPLETING].include?(audit.fetch(:state)) &&
    !audit.fetch(:items).empty? &&
    !includes_app_version?(audit)
end

def validate_no_duplicate_targets!(audit, options)
  version_count = target_items(audit, "appStoreVersion", options.version_id).length
  event_count = target_items(audit, "appEvent", options.event_id).length
  return if version_count <= 1 && event_count <= 1

  raise ConflictError,
        "Submission #{audit.fetch(:id)} already has duplicate target items " \
        "(version=#{version_count}, event=#{event_count}); refusing to delete or alter them"
end

def choose_submission!(active_audits, all_submissions, client, options)
  if options.submission_id
    submission = all_submissions.find { |item| item["id"] == options.submission_id }
    raise ConflictError, "Submission #{options.submission_id} does not belong to this app/IOS platform" unless submission

    audit = active_audits.find { |item| item[:id] == options.submission_id } ||
      audit_submission(client, submission)
    return audit
  end

  related = active_audits.select do |audit|
    !target_items(audit, "appStoreVersion", options.version_id).empty? ||
      !target_items(audit, "appEvent", options.event_id).empty?
  end
  if related.length > 1
    raise ConflictError,
          "Target resources appear in multiple active submissions: #{related.map { |item| item[:id] }.join(', ')}"
  end

  if related.length == 1
    other_active = active_audits.reject { |item| item[:id] == related.first[:id] }
    unless other_active.empty?
      raise ConflictError,
            "Another active review submission exists (#{other_active.map { |item| item[:id] }.join(', ')}); wait for it instead of mutating review state"
    end
    return related.first
  end

  return nil if active_audits.empty?

  # App Store Connect permits at most two simultaneous submissions per
  # platform: one containing an app version and one containing only associated
  # items. Preserve a currently submitted item-only review (for example PPO)
  # and create the requested app-version submission alongside it.
  if active_audits.length == 1 && parallel_item_only_submission?(active_audits.first)
    audit = active_audits.first
    puts "Preserving parallel item-only submission #{audit[:id]} (#{audit[:state]}); " \
         "creating a separate submission containing the app version."
    return nil
  end

  empty = active_audits.select { |audit| audit[:items].empty? && audit[:state] == "READY_FOR_REVIEW" }
  if empty.length == active_audits.length && empty.length == 1
    raise ConflictError,
          "An empty READY_FOR_REVIEW submission exists: #{empty.first[:id]}. " \
          "To resume it deliberately, rerun with --submission-id #{empty.first[:id]}; it was not modified."
  end

  details = active_audits.map { |audit| "#{audit[:id]} (#{audit[:state]})" }.join(", ")
  raise ConflictError,
        "Unrelated active review submission(s) detected: #{details}. Nothing was changed; wait for them to finish."
end

def validate_selected_submission!(audit, options)
  return unless audit

  validate_no_duplicate_targets!(audit, options)
  extras = unrelated_items(audit, options)
  unless extras.empty?
    kinds = extras.flat_map { |item| item.fetch(:targets).keys }.uniq
    label = ppo_only?({ items: extras }) ? "PPO" : (kinds.empty? ? "unknown" : kinds.join(", "))
    raise ConflictError,
          "Submission #{audit[:id]} contains unrelated #{label} item(s). " \
          "It was not modified; this tool only submits the requested version and event together."
  end

  state = audit.fetch(:state)
  version_present = !target_items(audit, "appStoreVersion", options.version_id).empty?
  event_present = !target_items(audit, "appEvent", options.event_id).empty?
  if state != "READY_FOR_REVIEW" && !(version_present && event_present)
    raise ConflictError,
          "Submission #{audit[:id]} is already #{state} but is missing " \
          "#{version_present ? 'the event' : 'the app version'}; it cannot be safely changed. Wait/read it in App Store Connect."
  end
end

def create_submission_payload(app_id)
  resource(
    "reviewSubmissions",
    attributes: { platform: "IOS" },
    relationships: { app: { data: { type: "apps", id: app_id } } }
  )
end

def create_item_payload(submission_id, relationship, target_id)
  resource(
    "reviewSubmissionItems",
    relationships: {
      reviewSubmission: {
        data: { type: "reviewSubmissions", id: submission_id }
      },
      relationship.to_sym => {
        data: { type: TARGET_TYPES.fetch(relationship), id: target_id }
      }
    }
  )
end

def submit_payload(submission_id)
  resource(
    "reviewSubmissions",
    id: submission_id,
    attributes: { submitted: true }
  )
end

def planned_writes(selected, options)
  placeholder = selected ? selected[:id] : "<new-review-submission-id>"
  writes = []
  writes << {
    method: "POST",
    path: "/v1/reviewSubmissions",
    body: create_submission_payload(options.app_id)
  } unless selected

  version_present = selected && !target_items(selected, "appStoreVersion", options.version_id).empty?
  event_present = selected && !target_items(selected, "appEvent", options.event_id).empty?
  unless version_present
    writes << {
      method: "POST",
      path: "/v1/reviewSubmissionItems",
      body: create_item_payload(placeholder, "appStoreVersion", options.version_id)
    }
  end
  unless event_present
    writes << {
      method: "POST",
      path: "/v1/reviewSubmissionItems",
      body: create_item_payload(placeholder, "appEvent", options.event_id)
    }
  end
  if selected.nil? || selected[:state] == "READY_FOR_REVIEW"
    writes << {
      method: "PATCH",
      path: "/v1/reviewSubmissions/#{placeholder}",
      body: submit_payload(placeholder)
    }
  end
  writes
end

def create_submission!(client, options)
  response = client.request("POST", "/v1/reviewSubmissions", create_submission_payload(options.app_id))
  submission = response.fetch("data")
  puts "Created review submission #{submission.fetch('id')} (resume with --submission-id if a later step fails)"
  audit_submission(client, submission)
end

def ensure_item!(client, audit, relationship, target_id)
  existing = target_items(audit, relationship, target_id)
  return audit unless existing.empty?

  client.request(
    "POST",
    "/v1/reviewSubmissionItems",
    create_item_payload(audit.fetch(:id), relationship, target_id)
  )
  refreshed = audit_submission(
    client,
    client.request("GET", "/v1/reviewSubmissions/#{audit.fetch(:id)}").fetch("data")
  )
  count = target_items(refreshed, relationship, target_id).length
  unless count == 1
    raise SafetyError,
          "Expected exactly one #{relationship} item after creation; found #{count}. Submission was not submitted."
  end
  refreshed
end

def assert_ready_to_submit!(audit, options)
  validate_selected_submission!(audit, options)
  unless audit[:state] == "READY_FOR_REVIEW"
    raise ConflictError, "Submission #{audit[:id]} is #{audit[:state]}, not READY_FOR_REVIEW"
  end

  version_count = target_items(audit, "appStoreVersion", options.version_id).length
  event_count = target_items(audit, "appEvent", options.event_id).length
  unless version_count == 1 && event_count == 1 && audit[:items].length == 2
    raise SafetyError,
          "Pre-submit invariant failed for #{audit[:id]}: " \
          "items=#{audit[:items].length}, version=#{version_count}, event=#{event_count}. Nothing was submitted."
  end
end

def fetch_submission(client, submission_id)
  path = query_path(
    "/v1/reviewSubmissions/#{submission_id}",
    { "fields[reviewSubmissions]" => "platform,submittedDate,state,items" }
  )
  client.request("GET", path).fetch("data")
end

def poll_submission(client, submission_id, interval:, timeout:)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  loop do
    submission = fetch_submission(client, submission_id)
    state = submission.dig("attributes", "state")
    puts "Review submission #{submission_id}: #{state || 'UNKNOWN'}"
    return submission unless state == "READY_FOR_REVIEW"

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    if elapsed >= timeout
      raise ToolError,
            "Timed out after #{timeout}s while #{submission_id} remained READY_FOR_REVIEW. " \
            "The submit PATCH may already have been accepted; rerun safely to read current state."
    end
    sleep interval
  end
end

def public_audit(audit)
  return nil unless audit

  audit.reject { |key, _value| key == :raw }
end

def run(options)
  client = ASCClient.new(base_url: BASE_URL, allow_writes: options.execute)
  targets = fetch_targets(client, options)
  submissions = list_submissions(client, options.app_id)
  active_submissions = submissions.reject { |submission| terminal_submission?(submission) }
  active_audits = active_submissions.map { |submission| audit_submission(client, submission) }
  selected = choose_submission!(active_audits, submissions, client, options)
  validate_selected_submission!(selected, options)
  writes = planned_writes(selected, options)

  unless options.execute
    puts JSON.pretty_generate(
      mode: "dry-run",
      writesEnabled: false,
      targets: targets,
      activeSubmissions: active_audits.map { |audit| public_audit(audit) },
      selectedSubmission: public_audit(selected),
      plannedWrites: writes,
      nextStep: writes.empty? ? "No write is needed; current submission is already submitted." : "Rerun with --execute after reviewing this plan."
    )
    return
  end

  puts "WRITE MODE ENABLED by explicit --execute"
  if writes.empty?
    raise ConflictError, "No write is needed, but the selected submission has no readable ID" unless selected
  elsif selected.nil?
    selected = create_submission!(client, options)
  end

  if selected[:state] == "READY_FOR_REVIEW"
    selected = ensure_item!(client, selected, "appStoreVersion", options.version_id)
    selected = ensure_item!(client, selected, "appEvent", options.event_id)
    # Re-read immediately before the irreversible transition to submitted.
    selected = audit_submission(client, fetch_submission(client, selected.fetch(:id)))
    assert_ready_to_submit!(selected, options)
    client.request(
      "PATCH",
      "/v1/reviewSubmissions/#{selected.fetch(:id)}",
      submit_payload(selected.fetch(:id))
    )
  elsif !SUBMITTED_SUBMISSION_STATES.include?(selected[:state])
    raise ConflictError,
          "Submission #{selected[:id]} is in unexpected state #{selected[:state]}; it was not modified"
  end

  submission = poll_submission(
    client,
    selected.fetch(:id),
    interval: options.poll_interval,
    timeout: options.timeout
  )
  final_audit = audit_submission(client, submission)
  final_targets = fetch_targets(client, options)
  result = {
    mode: "execute",
    submission: public_audit(final_audit),
    targets: final_targets
  }
  puts JSON.pretty_generate(result)

  state = final_audit[:state]
  return if SUCCESSFUL_READBACK_STATES.include?(state)

  if state == "UNRESOLVED_ISSUES"
    raise ConflictError,
          "Submission #{final_audit[:id]} has UNRESOLVED_ISSUES. It was not withdrawn or resubmitted."
  end
  raise ConflictError, "Submission #{final_audit[:id]} ended polling in unexpected state #{state}"
end

if $PROGRAM_NAME == __FILE__
  begin
    run(parse_options(ARGV))
  rescue APIError => error
    warn JSON.pretty_generate(error.document) unless error.document.nil? || error.document.empty?
    warn "ERROR: #{error.message}"
    exit 2
  rescue ToolError, KeyError => error
    warn "ERROR: #{error.message}"
    exit 2
  end
end
