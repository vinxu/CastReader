#!/usr/bin/env ruby
# frozen_string_literal: true

# New iPad sets only. Never deletes assets or touches iPhone/preview sets.
# Usage: ruby scripts/upload-ipad-app-store.rb LOCALE_ID FINAL_DIR JOURNAL [--execute]
# Validate local files without accessing ASC: ... --validate-only
require "digest"
require "fileutils"
require "json"
require "net/http"
require "uri"

localization, directory, journal_path = ARGV.take(3)
abort "Expected localization ID, final screenshot directory and journal path" unless journal_path
files = Dir.glob(File.join(directory, "*.png")).sort
names = %w[01-home 02-kindle-read 03-kindle-explain 04-voices 05-import].map { |n| "#{n}.png" }
abort "Expected exactly the five reviewed screenshots in order" unless files.map { |p| File.basename(p) } == names
images = files.map do |path|
  header = File.binread(path, 24)
  abort "Invalid PNG dimensions: #{path}" unless header.start_with?("\x89PNG\r\n\x1a\n".b) && header[16, 8].unpack("NN") == [2048, 2732]
  sha = Digest::SHA256.file(path).hexdigest
  { "path" => File.expand_path(path), "name" => "#{File.basename(path, '.png')}-#{sha[0, 12]}.png",
    "sha256" => sha, "md5" => Digest::MD5.file(path).hexdigest, "size" => File.size(path) }
end
if ARGV.include?("--validate-only")
  puts JSON.pretty_generate(images.map { |i| i.reject { |k, _| k == "path" } })
  exit
end

require File.expand_path(ENV.fetch("CASTREADER_ASC_CLIENT", "~/.codex/skills/submit-castreader-ios-to-app-store/scripts/asc_client.rb"))
client = ASCClient.new
execute = ARGV.include?("--execute")
display = "APP_IPAD_PRO_3GEN_129"
locale = client.request("GET", "/v1/appStoreVersionLocalizations/#{localization}?include=appStoreVersion")
version = locale.fetch("included").find { |x| x["type"] == "appStoreVersions" }
abort "Use only the pending 1.2.43 iOS version" unless version && version.dig("attributes", "versionString") == "1.2.43" && version.dig("attributes", "platform") == "IOS" && version.dig("attributes", "appStoreState") == "PREPARE_FOR_SUBMISSION"
app = client.request("GET", "/v1/appStoreVersions/#{version.fetch('id')}/app").fetch("data")
abort "Unexpected App Store app" unless app["id"] == "6757636395"
abort "Only the two reviewed locales are supported" unless %w[en-US zh-Hans].include?(locale.dig("data", "attributes", "locale"))
abort "Screenshot directory does not match the target locale" unless File.basename(File.expand_path(directory)) == locale.dig("data", "attributes", "locale")
sets = client.get_all("/v1/appStoreVersionLocalizations/#{localization}/appScreenshotSets?limit=50")
matches = sets.select { |s| s.dig("attributes", "screenshotDisplayType") == display }
abort "Ambiguous existing iPad sets" if matches.size > 1
set = matches.first
items = set ? client.get_all("/v1/appScreenshotSets/#{set.fetch('id')}/appScreenshots?limit=50") : []
abort "Existing iPad assets differ; preserve and review them separately" unless items.all? { |i| images.any? { |p| p["name"] == i.dig("attributes", "fileName") && p["size"] == i.dig("attributes", "fileSize") } }
abort "Duplicate reserved screenshot names" unless items.map { |i| i.dig("attributes", "fileName") }.uniq.size == items.size
unless execute
  puts JSON.pretty_generate(localization: localization, display: display, existingSet: set&.fetch("id"), existingAssets: items.map { |i| i["id"] }, intended: images.map { |i| i["name"] }, writes: false)
  exit
end

journal = File.exist?(journal_path) ? JSON.parse(File.read(journal_path)) : { "localization" => localization, "display" => display, "images" => {} }
abort "Journal belongs to a different target" unless journal["localization"] == localization && journal["display"] == display
save = lambda do
  FileUtils.mkdir_p(File.dirname(journal_path))
  File.write("#{journal_path}.tmp", JSON.pretty_generate(journal) + "\n", perm: 0o600)
  File.rename("#{journal_path}.tmp", journal_path)
end
resource = ->(type, attributes, relationships = nil, id = nil) { { data: { type: type, attributes: attributes, relationships: relationships, id: id }.compact } }
unless set
  abort "Previous set reservation is uncertain; re-read before retrying" if journal["setReservation"]
  journal["setReservation"] = true
  save.call
  set = client.request("POST", "/v1/appScreenshotSets", resource.call("appScreenshotSets", { screenshotDisplayType: display }, { appStoreVersionLocalization: { data: { type: "appStoreVersionLocalizations", id: localization } } })).fetch("data")
end
journal["setID"] = set.fetch("id")
save.call

images.each do |file|
  item = items.find { |i| i.dig("attributes", "fileName") == file["name"] }
  previous = journal["images"][file["name"]]
  unless item
    abort "Previous #{file['name']} reservation is uncertain; re-read before retrying" if previous
    journal["images"][file["name"]] = { "state" => "reserving", "sha256" => file["sha256"] }
    save.call
    item = client.request("POST", "/v1/appScreenshots", resource.call("appScreenshots", { fileName: file["name"], fileSize: file["size"] }, { appScreenshotSet: { data: { type: "appScreenshotSets", id: set.fetch("id") } } })).fetch("data")
  end
  id = item.fetch("id")
  journal["images"][file["name"]] = { "id" => id, "sha256" => file["sha256"] }
  save.call # Save every reserved ID before any bytes are uploaded.
  state = item.dig("attributes", "assetDeliveryState", "state")
  abort "Apple rejected #{id}; preserve it and inspect its error" if state == "FAILED"
  if state == "AWAITING_UPLOAD"
    operations = item.dig("attributes", "uploadOperations")
    abort "Missing upload operations for #{id}" if !operations || operations.empty?
    File.open(file["path"], "rb") do |input|
      operations.each do |operation|
        uri = URI(operation.fetch("url"))
        abort "Non-HTTPS upload operation" unless uri.scheme == "https"
        input.seek(operation.fetch("offset"))
        bytes = input.read(operation.fetch("length"))
        abort "Incomplete upload chunk" unless bytes&.bytesize == operation.fetch("length")
        request = Net::HTTP.const_get(operation.fetch("method").capitalize).new(uri)
        operation.fetch("requestHeaders", []).each { |h| request[h.fetch("name")] = h.fetch("value") }
        request.body = bytes
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 20, read_timeout: 60) { |http| http.request(request) }
        abort "Asset #{id} chunk failed: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
      end
    end
    client.request("PATCH", "/v1/appScreenshots/#{id}", resource.call("appScreenshots", { uploaded: true, sourceFileChecksum: file["md5"] }, nil, id))
  end
  final = client.request("GET", "/v1/appScreenshots/#{id}").fetch("data")
  state = final.dig("attributes", "assetDeliveryState", "state")
  if state == "COMPLETE"
    abort "Checksum mismatch for #{id}" unless final.dig("attributes", "sourceFileChecksum") == file["md5"]
  end
  journal["images"][file["name"]]["state"] = state
  save.call
  puts "#{file['name']}: #{id} #{state}"
end
unless journal["images"].values.all? { |i| i["state"] == "COMPLETE" }
  puts "Processing is pending. Resume this same journal to re-read existing assets."
  exit 2
end
ids = images.map { |i| journal["images"].fetch(i["name"]).fetch("id") }
client.request("PATCH", "/v1/appScreenshotSets/#{set.fetch('id')}/relationships/appScreenshots", { data: ids.map { |id| { type: "appScreenshots", id: id } } })
order = client.get_all("/v1/appScreenshotSets/#{set.fetch('id')}/appScreenshots?limit=50")
abort "Screenshot order/readback mismatch" unless order.map { |i| i["id"] } == ids && order.all? { |i| i.dig("attributes", "assetDeliveryState", "state") == "COMPLETE" }
journal["complete"] = true
save.call
puts "Verified five COMPLETE iPad screenshots in the required order."
