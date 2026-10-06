#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "optparse"
require "uri"
require File.expand_path("~/.codex/skills/submit-castreader-ios-to-app-store/scripts/asc_client.rb")

APP_ID = "6757636395"
LOCALES = %w[en-US zh-Hans ja es-ES fr-FR pt-BR it hi de-DE zh-Hant es-MX].freeze
TERMINAL_REVIEW_STATES = %w[COMPLETE CANCELED].freeze
VERSION_CREATION_ALLOWED_STATES = %w[READY_FOR_SALE READY_FOR_DISTRIBUTION].freeze

def query_path(path, params)
  "#{path}?#{URI.encode_www_form(params)}"
end

def semver_key(value)
  parts = value.to_s.split(".").map { |part| Integer(part, 10) rescue 0 }
  (parts + [0, 0, 0]).first(3)
end

def next_patch(value)
  major, minor, patch = semver_key(value)
  [major, minor, patch + 1].join(".")
end

def app_versions(client, app_id)
  client.get_all(query_path("/v1/apps/#{app_id}/appStoreVersions", {
    "filter[platform]" => "IOS",
    "limit" => "200"
  }))
end

def app_builds(client, app_id)
  client.get_all(query_path("/v1/builds", {
    "filter[app]" => app_id,
    "limit" => "200"
  }))
end

def app_infos(client, app_id)
  client.get_all("/v1/apps/#{app_id}/appInfos?limit=50")
end

def review_submissions(client, app_id)
  client.get_all(query_path("/v1/apps/#{app_id}/reviewSubmissions", {
    "filter[platform]" => "IOS",
    "limit" => "200"
  }))
end

def compact_version(resource)
  {
    id: resource.fetch("id"),
    version: resource.dig("attributes", "versionString"),
    state: resource.dig("attributes", "appStoreState") || resource.dig("attributes", "appVersionState"),
    releaseType: resource.dig("attributes", "releaseType")
  }
end

def inspect_state(client, app_id)
  versions = app_versions(client, app_id)
  builds = app_builds(client, app_id)
  submissions = review_submissions(client, app_id)
  infos = app_infos(client, app_id)
  latest = versions.max_by { |item| semver_key(item.dig("attributes", "versionString")) }
  latest_state = latest && (latest.dig("attributes", "appStoreState") || latest.dig("attributes", "appVersionState"))
  max_build = builds.map { |item| item.dig("attributes", "version").to_i }.max || 0
  active = submissions.reject { |item| TERMINAL_REVIEW_STATES.include?(item.dig("attributes", "state")) }

  puts JSON.pretty_generate(
    appId: app_id,
    latestVersion: latest && compact_version(latest),
    suggestedVersion: latest && next_patch(latest.dig("attributes", "versionString")),
    nextVersionCreation: {
      allowed: latest.nil? || VERSION_CREATION_ALLOWED_STATES.include?(latest_state),
      blockingState: VERSION_CREATION_ALLOWED_STATES.include?(latest_state) ? nil : latest_state
    },
    highestUploadedBuild: max_build,
    suggestedBuild: max_build + 1,
    activeReviewSubmissions: active.map do |item|
      {
        id: item.fetch("id"),
        state: item.dig("attributes", "state"),
        submittedDate: item.dig("attributes", "submittedDate")
      }
    end,
    appInfos: infos.map do |item|
      {
        id: item.fetch("id"),
        state: item.dig("attributes", "appStoreState") || item.dig("attributes", "state")
      }
    end
  )
end

def wait_build(client, app_id, build_number, timeout, interval)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  loop do
    builds = client.get_all(query_path("/v1/builds", {
      "filter[app]" => app_id,
      "filter[version]" => build_number.to_s,
      "limit" => "50"
    }))
    build = builds.max_by { |item| item.dig("attributes", "uploadedDate").to_s }
    if build
      state = build.dig("attributes", "processingState")
      audience = build.dig("attributes", "buildAudienceType")
      warn "Build #{build_number}: #{state || 'UNKNOWN'} / #{audience || 'UNKNOWN'}"
      if state == "VALID" && audience == "APP_STORE_ELIGIBLE"
        puts JSON.pretty_generate(
          id: build.fetch("id"),
          buildNumber: build.dig("attributes", "version"),
          uploadedDate: build.dig("attributes", "uploadedDate"),
          processingState: state,
          buildAudienceType: audience,
          usesNonExemptEncryption: build.dig("attributes", "usesNonExemptEncryption")
        )
        return
      end
      if %w[FAILED INVALID].include?(state)
        abort "Build #{build_number} processing failed with state #{state}"
      end
    else
      warn "Build #{build_number}: not visible yet"
    end

    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    abort "Timed out after #{timeout}s waiting for Build #{build_number}" if elapsed >= timeout
    sleep interval
  end
end

def pending_and_baseline_infos(client, app_id)
  infos = app_infos(client, app_id)
  pending = infos.select do |item|
    (item.dig("attributes", "appStoreState") || item.dig("attributes", "state")) == "PREPARE_FOR_SUBMISSION"
  end
  baseline = infos.select do |item|
    %w[READY_FOR_SALE READY_FOR_DISTRIBUTION].include?(
      item.dig("attributes", "appStoreState") || item.dig("attributes", "state")
    )
  end
  [pending, baseline]
end

def create_version(client, app_id, version_string, previous_version_id, release_type, execute)
  versions = app_versions(client, app_id)
  existing = versions.find do |item|
    item.dig("attributes", "platform") == "IOS" && item.dig("attributes", "versionString") == version_string
  end
  if existing
    pending, baseline = pending_and_baseline_infos(client, app_id)
    puts JSON.pretty_generate(
      resumed: true,
      version: compact_version(existing),
      pendingAppInfoId: pending.length == 1 ? pending.first.fetch("id") : nil,
      baselineAppInfoId: baseline.max_by { |item| item.fetch("id") }&.fetch("id"),
      warnings: pending.length == 1 ? [] : ["Expected one pending App Info, found #{pending.length}"]
    )
    return
  end

  latest = versions.max_by { |item| semver_key(item.dig("attributes", "versionString")) }
  latest_state = latest && (latest.dig("attributes", "appStoreState") || latest.dig("attributes", "appVersionState"))
  creation_allowed = latest.nil? || VERSION_CREATION_ALLOWED_STATES.include?(latest_state)

  previous = if previous_version_id
    client.request("GET", "/v1/appStoreVersions/#{previous_version_id}").fetch("data")
  else
    versions.max_by { |item| semver_key(item.dig("attributes", "versionString")) }
  end
  abort "No previous App Store version is available to preserve release attributes" unless previous

  attributes = {
    platform: "IOS",
    versionString: version_string,
    copyright: previous.dig("attributes", "copyright"),
    releaseType: release_type || previous.dig("attributes", "releaseType") || "AFTER_APPROVAL"
  }
  payload = {
    data: {
      type: "appStoreVersions",
      attributes: attributes,
      relationships: { app: { data: { type: "apps", id: app_id } } }
    }
  }
  unless execute
    puts JSON.pretty_generate(
      mode: "dry-run",
      canExecute: creation_allowed,
      blockingState: creation_allowed ? nil : latest_state,
      create: payload
    )
    return
  end
  abort "Cannot create #{version_string} while latest version is #{latest_state}; keep the uploaded build and resume after distribution" unless creation_allowed

  begin
    version = client.request("POST", "/v1/appStoreVersions", payload).fetch("data")
  rescue ASCError => error
    raise unless error.ambiguous_write

    version = app_versions(client, app_id).find do |item|
      item.dig("attributes", "versionString") == version_string && item.dig("attributes", "platform") == "IOS"
    end
    raise unless version
  end

  pending = []
  baseline = []
  6.times do
    pending, baseline = pending_and_baseline_infos(client, app_id)
    break if pending.length == 1
    sleep 5
  end
  abort "Version created, but expected one pending App Info and found #{pending.length}" unless pending.length == 1

  puts JSON.pretty_generate(
    resumed: false,
    version: compact_version(version),
    pendingAppInfoId: pending.first.fetch("id"),
    baselineAppInfoId: baseline.max_by { |item| item.fetch("id") }&.fetch("id")
  )
end

def localization_map(client, path)
  client.get_all(path).to_h { |item| [item.dig("attributes", "locale"), item] }
end

def audit_version(client, options)
  errors = []
  version_id = options.fetch(:version_id)
  expected_build_id = options.fetch(:build_id)
  version = client.request("GET", "/v1/appStoreVersions/#{version_id}").fetch("data")
  abort "Wrong Mac version" unless version.dig("attributes", "platform") == "MAC_OS" && version.dig("attributes", "versionString") == "1.2.47"
  build = client.request("GET", "/v1/appStoreVersions/#{version_id}/build")["data"]
  if build.nil?
    errors << "App Store version has no attached build"
  else
    errors << "Attached build #{build.fetch('id')} does not match #{expected_build_id}" unless build.fetch("id") == expected_build_id
    errors << "Build is #{build.dig('attributes', 'processingState')}, expected VALID" unless build.dig("attributes", "processingState") == "VALID"
    errors << "Build audience is not APP_STORE_ELIGIBLE" unless build.dig("attributes", "buildAudienceType") == "APP_STORE_ELIGIBLE"
  end
  expected_release_type = options.fetch(:release_type)
  actual_release_type = version.dig("attributes", "releaseType")
  errors << "Release type #{actual_release_type} does not match #{expected_release_type}" unless actual_release_type == expected_release_type

  version_localizations = localization_map(
    client,
    "/v1/appStoreVersions/#{version_id}/appStoreVersionLocalizations?limit=50"
  )
  errors << "Version locale set mismatch" unless version_localizations.keys.sort == LOCALES.sort
  # Apple permits Promotional Text to be absent; preserve an intentionally blank value.
  # https://developer.apple.com/app-store/product-page/#promotional-text
  required_version_fields = %w[description keywords supportUrl marketingUrl] # First Mac release has no prior version changes.
  absent_promotional_text_locales = []
  version_localizations.each do |locale, item|
    required_version_fields.each do |field|
      value = item.dig("attributes", field)
      errors << "#{locale} version field #{field} is empty" unless value.is_a?(String) && !value.strip.empty?
    end
    promotional_text = item.dig("attributes", "promotionalText")
    if promotional_text.nil? || (promotional_text.is_a?(String) && promotional_text.strip.empty?)
      absent_promotional_text_locales << locale
    elsif !promotional_text.is_a?(String)
      errors << "#{locale} promotionalText must be a string when present"
    elsif promotional_text.length > 170
      errors << "#{locale} promotionalText exceeds 170 characters"
    end
  end

  title_guard = { policy: options.fetch(:title_policy), unchanged: nil }
  pending_info_id = options[:pending_app_info_id]
  if pending_info_id
    pending_localizations = localization_map(client, "/v1/appInfos/#{pending_info_id}/appInfoLocalizations?limit=50")
    errors << "Pending App Info locale set mismatch" unless pending_localizations.keys.sort == LOCALES.sort
    if options.fetch(:title_policy) == "preserve"
      baseline_info_id = options[:baseline_app_info_id]
      abort "--baseline-app-info-id is required with --title-policy preserve" unless baseline_info_id
      baseline_localizations = localization_map(client, "/v1/appInfos/#{baseline_info_id}/appInfoLocalizations?limit=50")
      changed = LOCALES.select do |locale|
        pending = pending_localizations[locale]
        baseline = baseline_localizations[locale]
        !pending || !baseline || %w[name subtitle].any? do |field|
          pending.dig("attributes", field) != baseline.dig("attributes", field)
        end
      end
      title_guard[:unchanged] = changed.empty?
      title_guard[:changedLocales] = changed
      errors << "Title/subtitle changed in: #{changed.join(', ')}" unless changed.empty?
    end
  end

  screenshots = {}
  version_localizations.each do |locale, localization|
    sets = client.get_all("/v1/appStoreVersionLocalizations/#{localization.fetch('id')}/appScreenshotSets?limit=50")
    complete = 0
    set_summaries = sets.map do |set|
      images = client.get_all("/v1/appScreenshotSets/#{set.fetch('id')}/appScreenshots?limit=50")
      complete_images = images.count { |image| image.dig("attributes", "assetDeliveryState", "state") == "COMPLETE" }
      complete += complete_images
      {
        displayType: set.dig("attributes", "screenshotDisplayType"),
        complete: complete_images,
        total: images.length
      }
    end
    screenshots[locale] = { sets: set_summaries, complete: complete, fallbackToPrimary: sets.empty? }
    errors << "#{locale} has a screenshot set without a complete screenshot" if !sets.empty? && complete.zero?
  end
  errors << "Primary locale en-US has no complete screenshots" if screenshots.dig("en-US", :complete).to_i.zero?

  review_detail = client.request("GET", "/v1/appStoreVersions/#{version_id}/appStoreReviewDetail")["data"]
  errors << "Missing App Store Review Details" unless review_detail

  result = {
    version: compact_version(version),
    build: build && {
      id: build.fetch("id"),
      number: build.dig("attributes", "version"),
      processingState: build.dig("attributes", "processingState"),
      buildAudienceType: build.dig("attributes", "buildAudienceType"),
      usesNonExemptEncryption: build.dig("attributes", "usesNonExemptEncryption")
    },
    locales: version_localizations.keys.sort,
    titleGuard: title_guard,
    optionalPromotionalTextAbsentLocales: absent_promotional_text_locales.sort,
    screenshots: screenshots,
    reviewDetailsPresent: !review_detail.nil?,
    errors: errors
  }
  puts JSON.pretty_generate(result)
  exit 1 unless errors.empty?
end

command = ARGV.shift
abort "Only audit is supported; this helper cannot mutate other platforms" unless command == "audit"
abort "Usage: release_ops.rb inspect|wait-build|create-version|audit [options]" unless command
client = ASCClient.new

case command
when "inspect"
  options = { app_id: APP_ID }
  OptionParser.new { |parser| parser.on("--app-id ID") { |value| options[:app_id] = value } }.parse!(ARGV)
  inspect_state(client, options.fetch(:app_id))
when "wait-build"
  options = { app_id: APP_ID, timeout: 1_800, interval: 30 }
  OptionParser.new do |parser|
    parser.on("--app-id ID") { |value| options[:app_id] = value }
    parser.on("--build-number NUMBER", Integer) { |value| options[:build_number] = value }
    parser.on("--timeout SECONDS", Integer) { |value| options[:timeout] = value }
    parser.on("--interval SECONDS", Integer) { |value| options[:interval] = value }
  end.parse!(ARGV)
  abort "--build-number is required" unless options[:build_number]
  wait_build(client, options.fetch(:app_id), options.fetch(:build_number), options.fetch(:timeout), options.fetch(:interval))
when "create-version"
  options = { app_id: APP_ID, execute: false, release_type: nil }
  OptionParser.new do |parser|
    parser.on("--app-id ID") { |value| options[:app_id] = value }
    parser.on("--version VERSION") { |value| options[:version] = value }
    parser.on("--previous-version-id ID") { |value| options[:previous_version_id] = value }
    parser.on("--release-type TYPE") { |value| options[:release_type] = value }
    parser.on("--execute") { options[:execute] = true }
  end.parse!(ARGV)
  abort "--version is required" unless options[:version]
  create_version(
    client,
    options.fetch(:app_id),
    options.fetch(:version),
    options[:previous_version_id],
    options[:release_type],
    options.fetch(:execute)
  )
when "audit"
  options = { title_policy: "ignore", release_type: "AFTER_APPROVAL" }
  OptionParser.new do |parser|
    parser.on("--version-id ID") { |value| options[:version_id] = value }
    parser.on("--build-id ID") { |value| options[:build_id] = value }
    parser.on("--pending-app-info-id ID") { |value| options[:pending_app_info_id] = value }
    parser.on("--baseline-app-info-id ID") { |value| options[:baseline_app_info_id] = value }
    parser.on("--title-policy POLICY", %w[preserve ignore]) { |value| options[:title_policy] = value }
    parser.on("--release-type TYPE") { |value| options[:release_type] = value }
  end.parse!(ARGV)
  abort "--version-id and --build-id are required" unless options[:version_id] && options[:build_id]
  audit_version(client, options)
else
  abort "Unknown command: #{command}"
end
