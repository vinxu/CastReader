#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "net/http"
require "openssl"
require "uri"

KEY_ID = ENV.fetch("ASC_KEY_ID", "6QN4G1IJDEP1")
KEY_PATH = ENV.fetch(
  "ASC_KEY_PATH",
  File.expand_path("~/.appstoreconnect/private_keys/AuthKey_#{KEY_ID}.p8")
)
BASE_URL = "https://api.appstoreconnect.apple.com"

LOCALIZATION_ID = ARGV.fetch(0)
SCREENSHOT_DIRECTORY = File.expand_path(ARGV.fetch(1))
PREVIEW_PATH = File.expand_path(ARGV.fetch(2))
REPLACE_SCREENSHOTS = ENV["ASC_REPLACE_SCREENSHOTS"] == "1"
PRESERVE_PREVIEW = ENV["ASC_PRESERVE_PREVIEW"] == "1"

def base64url(value)
  Base64.urlsafe_encode64(value, padding: false)
end

def token
  now = Time.now.to_i
  header = base64url(JSON.generate(alg: "ES256", kid: KEY_ID, typ: "JWT"))
  payload = base64url(JSON.generate(sub: "user", iat: now, exp: now + 1_000, aud: "appstoreconnect-v1"))
  signing_input = "#{header}.#{payload}"
  key = OpenSSL::PKey.read(File.read(KEY_PATH))
  sequence = OpenSSL::ASN1.decode(key.sign("SHA256", signing_input))
  signature = sequence.value.map do |integer|
    hex = integer.value.to_s(16)
    hex = "0#{hex}" if hex.length.odd?
    [hex].pack("H*").rjust(32, "\0")
  end.join
  "#{signing_input}.#{base64url(signature)}"
end

def asc_request(method, path, payload = nil)
  uri = URI.join(BASE_URL, path)
  request = Net::HTTP.const_get(method.to_s.capitalize).new(uri)
  request["Authorization"] = "Bearer #{token}"
  request["Content-Type"] = "application/json"
  request.body = JSON.generate(payload) if payload
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 300) do |http|
    http.request(request)
  end
  parsed = response.body.nil? || response.body.empty? ? {} : JSON.parse(response.body)
  return parsed if response.is_a?(Net::HTTPSuccess)

  warn JSON.pretty_generate(parsed)
  abort "App Store Connect #{method.to_s.upcase} #{path} failed with HTTP #{response.code}"
end

def resource(type, id: nil, attributes: nil, relationships: nil)
  data = { type: type }
  data[:id] = id if id
  data[:attributes] = attributes if attributes
  data[:relationships] = relationships if relationships
  { data: data }
end

def upload_operations(path, operations)
  File.open(path, "rb") do |file|
    operations.each_with_index do |operation, index|
      offset = operation.fetch("offset")
      length = operation.fetch("length")
      file.seek(offset)
      bytes = file.read(length)
      abort "Unable to read upload chunk #{index + 1} for #{path}" unless bytes&.bytesize == length

      uri = URI(operation.fetch("url"))
      request = Net::HTTP.const_get(operation.fetch("method").capitalize).new(uri)
      operation.fetch("requestHeaders", []).each do |header|
        request[header.fetch("name")] = header.fetch("value")
      end
      request.body = bytes
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: uri.scheme == "https", read_timeout: 600) do |http|
        http.request(request)
      end
      next if response.is_a?(Net::HTTPSuccess)

      abort "Asset chunk #{index + 1} failed with HTTP #{response.code}"
    end
  end
end

def reserve_and_upload(path, asset_type:, relationship_name:, set_type:, set_id:)
  relationships = {
    relationship_name => { data: { type: set_type, id: set_id } }
  }
  response = asc_request(
    :post,
    "/v1/#{asset_type}",
    resource(
      asset_type,
      attributes: { fileName: File.basename(path), fileSize: File.size(path) },
      relationships: relationships
    )
  )
  item = response.fetch("data")
  operations = item.dig("attributes", "uploadOperations")
  abort "No upload operations returned for #{path}" if operations.nil? || operations.empty?

  upload_operations(path, operations)
  checksum = Digest::MD5.file(path).hexdigest
  asc_request(
    :patch,
    "/v1/#{asset_type}/#{item.fetch("id")}",
    resource(
      asset_type,
      id: item.fetch("id"),
      attributes: { uploaded: true, sourceFileChecksum: checksum }
    )
  )
  puts "Uploaded #{File.basename(path)} as #{item.fetch("id")}"
  item.fetch("id")
end

def wait_for_delivery(asset_type, id, state_field, timeout_seconds: 1_800)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  loop do
    response = asc_request(
      :get,
      "/v1/#{asset_type}/#{id}?fields%5B#{asset_type}%5D=#{state_field}"
    )
    state = response.dig("data", "attributes", state_field, "state")
    puts "#{asset_type} #{id}: #{state || "PENDING"}"
    return if state == "COMPLETE"
    abort "#{asset_type} #{id} failed processing" if state == "FAILED"
    abort "#{asset_type} #{id} processing timed out" if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > timeout_seconds

    sleep 10
  end
end

def relationship_order(set_collection, set_id, asset_type, ids)
  asc_request(
    :patch,
    "/v1/#{set_collection}/#{set_id}/relationships/#{asset_type}",
    { data: ids.map { |id| { type: asset_type, id: id } } }
  )
end

screenshots = Dir.glob(File.join(SCREENSHOT_DIRECTORY, "*.png"))
  .select { |path| File.basename(path).match?(/\A\d{2}-.+\.png\z/) }
  .sort
abort "Expected at least one screenshot in #{SCREENSHOT_DIRECTORY}" if screenshots.empty?
abort "App Store Connect accepts at most 10 screenshots" if screenshots.length > 10
abort "Preview not found: #{PREVIEW_PATH}" unless PRESERVE_PREVIEW || File.file?(PREVIEW_PATH)

existing_screenshot_sets = asc_request(
  :get,
  "/v1/appStoreVersionLocalizations/#{LOCALIZATION_ID}/appScreenshotSets?limit=50"
).fetch("data")
existing_screenshot_set = existing_screenshot_sets.find do |set|
  set.dig("attributes", "screenshotDisplayType") == "APP_IPHONE_67"
end

existing_preview_sets = asc_request(
  :get,
  "/v1/appStoreVersionLocalizations/#{LOCALIZATION_ID}/appPreviewSets?limit=50"
).fetch("data")
existing_preview_set = existing_preview_sets.find do |set|
  set.dig("attributes", "previewType") == "IPHONE_67"
end

localization_relationship = {
  appStoreVersionLocalization: {
    data: { type: "appStoreVersionLocalizations", id: LOCALIZATION_ID }
  }
}

screenshots_to_delete_after_upload = []

if existing_screenshot_set
  screenshot_set = existing_screenshot_set
  uploaded = asc_request(
    :get,
    "/v1/appScreenshotSets/#{screenshot_set.fetch("id")}/appScreenshots?limit=10"
  ).fetch("data")

  if REPLACE_SCREENSHOTS
    existing_by_signature = uploaded.to_h do |item|
      attributes = item.fetch("attributes")
      [[attributes.fetch("fileName"), attributes.fetch("sourceFileChecksum")], item]
    end
    reusable_by_path = screenshots.to_h do |path|
      signature = [File.basename(path), Digest::MD5.file(path).hexdigest]
      [path, existing_by_signature[signature]]
    end
    reusable_ids = reusable_by_path.values.compact.map { |item| item.fetch("id") }
    missing_paths = screenshots.reject { |path| reusable_by_path[path] }
    obsolete_items = uploaded.reject { |item| reusable_ids.include?(item.fetch("id")) }

    missing_names = missing_paths.map { |path| File.basename(path) }
    delete_before_upload = obsolete_items.select do |item|
      missing_names.include?(item.dig("attributes", "fileName"))
    end
    remaining_obsolete = obsolete_items - delete_before_upload
    capacity_excess = [
      uploaded.length - delete_before_upload.length + missing_paths.length - 10,
      0
    ].max
    delete_before_upload.concat(remaining_obsolete.first(capacity_excess))
    delete_before_upload.uniq! { |item| item.fetch("id") }

    delete_before_upload.each do |item|
      asc_request(:delete, "/v1/appScreenshots/#{item.fetch("id")}")
      puts "Deleted superseded screenshot before upload #{item.fetch("id")}"
    end

    uploaded_by_path = missing_paths.to_h do |path|
      id = reserve_and_upload(
        path,
        asset_type: "appScreenshots",
        relationship_name: :appScreenshotSet,
        set_type: "appScreenshotSets",
        set_id: screenshot_set.fetch("id")
      )
      [path, id]
    end
    screenshot_ids = screenshots.map do |path|
      reusable_by_path[path]&.fetch("id") || uploaded_by_path.fetch(path)
    end
    deleted_before_ids = delete_before_upload.map { |item| item.fetch("id") }
    screenshots_to_delete_after_upload = obsolete_items
      .reject { |item| deleted_before_ids.include?(item.fetch("id")) }
      .map { |item| item.fetch("id") }
    puts "Replacing screenshots in set #{screenshot_set.fetch("id")}"
  else
    by_name = uploaded.to_h { |item| [item.dig("attributes", "fileName"), item] }
    missing = screenshots.map { |path| File.basename(path) }.reject { |name| by_name.key?(name) }
    abort "Existing APP_IPHONE_67 set is incomplete: missing #{missing.join(", ")}" unless missing.empty?

    screenshot_ids = screenshots.map { |path| by_name.fetch(File.basename(path)).fetch("id") }
    puts "Reusing completed screenshot set #{screenshot_set.fetch("id")}"
  end
else
  screenshot_set = asc_request(
    :post,
    "/v1/appScreenshotSets",
    resource(
      "appScreenshotSets",
      attributes: { screenshotDisplayType: "APP_IPHONE_67" },
      relationships: localization_relationship
    )
  ).fetch("data")
  puts "Created screenshot set #{screenshot_set.fetch("id")}"

  screenshot_ids = screenshots.map do |path|
    reserve_and_upload(
      path,
      asset_type: "appScreenshots",
      relationship_name: :appScreenshotSet,
      set_type: "appScreenshotSets",
      set_id: screenshot_set.fetch("id")
    )
  end
end
screenshot_ids.each do |id|
  wait_for_delivery("appScreenshots", id, "assetDeliveryState")
end
screenshots_to_delete_after_upload.each do |id|
  asc_request(:delete, "/v1/appScreenshots/#{id}")
  puts "Deleted superseded screenshot after replacement #{id}"
end
relationship_order("appScreenshotSets", screenshot_set.fetch("id"), "appScreenshots", screenshot_ids)

if PRESERVE_PREVIEW
  preview_set = existing_preview_set
  preview_id = nil
  puts "Preserving existing preview assets without mutation"
elsif existing_preview_set
  preview_set = existing_preview_set
  uploaded = asc_request(
    :get,
    "/v1/appPreviewSets/#{preview_set.fetch("id")}/appPreviews?limit=3"
  ).fetch("data")
  preview_item = uploaded.find do |item|
    item.dig("attributes", "fileName") == File.basename(PREVIEW_PATH)
  end
  abort "Existing IPHONE_67 preview set does not contain #{File.basename(PREVIEW_PATH)}" unless preview_item

  preview_id = preview_item.fetch("id")
  puts "Reusing preview set #{preview_set.fetch("id")}"
  wait_for_delivery("appPreviews", preview_id, "videoDeliveryState")
  relationship_order("appPreviewSets", preview_set.fetch("id"), "appPreviews", [preview_id])
else
  preview_set = asc_request(
    :post,
    "/v1/appPreviewSets",
    resource(
      "appPreviewSets",
      attributes: { previewType: "IPHONE_67" },
      relationships: localization_relationship
    )
  ).fetch("data")
  puts "Created preview set #{preview_set.fetch("id")}"

  preview_id = reserve_and_upload(
    PREVIEW_PATH,
    asset_type: "appPreviews",
    relationship_name: :appPreviewSet,
    set_type: "appPreviewSets",
    set_id: preview_set.fetch("id")
  )
  wait_for_delivery("appPreviews", preview_id, "videoDeliveryState")
  relationship_order("appPreviewSets", preview_set.fetch("id"), "appPreviews", [preview_id])
end

old_sets = existing_screenshot_sets.select do |set|
  set.dig("attributes", "screenshotDisplayType") == "APP_IPHONE_65"
end
old_sets.each do |set|
  asc_request(:delete, "/v1/appScreenshotSets/#{set.fetch("id")}")
  puts "Deleted superseded APP_IPHONE_65 screenshot set #{set.fetch("id")}"
end

puts JSON.generate(
  screenshotSetId: screenshot_set.fetch("id"),
  screenshotIds: screenshot_ids,
  previewSetId: preview_set&.fetch("id"),
  previewId: preview_id
)
