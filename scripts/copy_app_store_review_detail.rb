#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "digest"
require "json"
require "net/http"
require "openssl"
require "uri"

BASE_URL = "https://api.appstoreconnect.apple.com"
DEFAULT_KEY_ID = "6QN4G1IJDEP1"
REVIEW_FIELDS = %w[
  contactFirstName
  contactLastName
  contactPhone
  contactEmail
  demoAccountRequired
  demoAccountName
  demoAccountPassword
  notes
].freeze

def load_config
  path = ENV["ASC_CONFIG_PATH"]
  return [{}, nil] if path.nil? || path.empty?

  expanded_path = File.expand_path(path)
  parsed = JSON.parse(File.read(expanded_path))
  abort "ASC_CONFIG_PATH must contain a JSON object" unless parsed.is_a?(Hash)

  [parsed, File.dirname(expanded_path)]
rescue Errno::ENOENT
  abort "ASC_CONFIG_PATH does not exist"
rescue JSON::ParserError
  abort "ASC_CONFIG_PATH is not valid JSON"
end

def config_value(config, *keys)
  keys.each do |key|
    value = config[key]
    return value unless value.nil? || value.to_s.empty?
  end
  nil
end

CONFIG, CONFIG_DIRECTORY = load_config
KEY_ID = ENV["ASC_KEY_ID"] || config_value(CONFIG, "key_id", "keyId", "ASC_KEY_ID") || DEFAULT_KEY_ID
configured_key_path = ENV["ASC_KEY_PATH"] || config_value(CONFIG, "key_path", "keyPath", "ASC_KEY_PATH")
KEY_PATH = if configured_key_path.nil?
  File.expand_path("~/.appstoreconnect/private_keys/AuthKey_#{KEY_ID}.p8")
elsif configured_key_path.start_with?("~", "/")
  File.expand_path(configured_key_path)
else
  File.expand_path(configured_key_path, CONFIG_DIRECTORY || Dir.pwd)
end
ISSUER_ID = ENV["ASC_ISSUER_ID"] || config_value(CONFIG, "issuer_id", "issuerId", "ASC_ISSUER_ID")

def base64url(value)
  Base64.urlsafe_encode64(value, padding: false)
end

def jwt
  now = Time.now.to_i
  header = base64url(JSON.generate(alg: "ES256", kid: KEY_ID, typ: "JWT"))
  claims = { iat: now, exp: now + 1_000, aud: "appstoreconnect-v1" }
  if ISSUER_ID.nil? || ISSUER_ID.empty?
    claims[:sub] = "user"
  else
    claims[:iss] = ISSUER_ID
  end
  payload = base64url(JSON.generate(claims))
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

def request(method, path, payload = nil)
  uri = URI.join(BASE_URL, path)
  http_request = Net::HTTP.const_get(method.capitalize).new(uri)
  http_request["Authorization"] = "Bearer #{jwt}"
  http_request["Content-Type"] = "application/json"
  http_request.body = JSON.generate(payload) if payload
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(http_request) }
  parsed = response.body.empty? ? {} : JSON.parse(response.body)
  return parsed if response.is_a?(Net::HTTPSuccess)

  abort "App Store Connect #{method.upcase} request failed with HTTP #{response.code}"
rescue JSON::ParserError
  abort "App Store Connect #{method.upcase} response was not valid JSON"
end

def review_detail(version_id)
  response = request("Get", "/v1/appStoreVersions/#{version_id}/appStoreReviewDetail")
  response["data"] || abort("App Store review detail is missing for version #{version_id}")
end

def resource(id, attributes)
  {
    data: {
      type: "appStoreReviewDetails",
      id: id,
      attributes: attributes
    }
  }
end

def notes_summary(attributes)
  notes = attributes["notes"]
  {
    present: !notes.nil?,
    length: notes.nil? ? 0 : notes.length,
    sha256: notes.nil? ? nil : Digest::SHA256.hexdigest(notes)
  }
end

def field_presence(attributes)
  REVIEW_FIELDS.to_h { |field| [field, attributes.key?(field) && !attributes[field].nil?] }
end

old_version_id = ARGV.fetch(0) { abort "Usage: #{$PROGRAM_NAME} OLD_VERSION_ID NEW_VERSION_ID" }
new_version_id = ARGV.fetch(1) { abort "Usage: #{$PROGRAM_NAME} OLD_VERSION_ID NEW_VERSION_ID" }
version_id_pattern = /\A[0-9a-fA-F-]+\z/
abort "OLD_VERSION_ID has an invalid format" unless old_version_id.match?(version_id_pattern)
abort "NEW_VERSION_ID has an invalid format" unless new_version_id.match?(version_id_pattern)
abort "Old and new App Store version IDs must differ" if old_version_id == new_version_id

old_detail = review_detail(old_version_id)
new_detail = review_detail(new_version_id)
old_attributes = old_detail.fetch("attributes")
copied_attributes = REVIEW_FIELDS.to_h { |field| [field.to_sym, old_attributes[field]] }

request(
  "Patch",
  "/v1/appStoreReviewDetails/#{new_detail.fetch("id")}",
  resource(new_detail.fetch("id"), copied_attributes)
)

verified_new_detail = review_detail(new_version_id)
verified_attributes = verified_new_detail.fetch("attributes")
mismatched_fields = REVIEW_FIELDS.reject { |field| verified_attributes[field] == old_attributes[field] }
abort "App Store review detail verification failed for fields: #{mismatched_fields.join(', ')}" unless mismatched_fields.empty?

puts JSON.pretty_generate(
  oldDetailId: old_detail.fetch("id"),
  newDetailId: verified_new_detail.fetch("id"),
  oldNotes: notes_summary(old_attributes),
  newNotes: notes_summary(verified_attributes),
  oldFieldPresence: field_presence(old_attributes),
  newFieldPresence: field_presence(verified_attributes)
)
