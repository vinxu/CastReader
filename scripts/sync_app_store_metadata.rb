#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"

APP_ID = "6757636395"
VALIDATE_ONLY = ENV["ASC_VALIDATE_ONLY"] == "1"
DEFAULT_METADATA_PATH = File.expand_path("../docs/CastReader-AppStore-Metadata-11-Languages-1.2.20.md", __dir__)
VERSION_ID = VALIDATE_ONLY ? ARGV.fetch(0, "-") : ARGV.fetch(0)
BUILD_ID = VALIDATE_ONLY ? ARGV.fetch(1, "-") : ARGV.fetch(1)
METADATA_PATH = ENV.fetch("ASC_METADATA_PATH", ARGV.fetch(2, DEFAULT_METADATA_PATH))
APP_INFO_ID = VALIDATE_ONLY ? ARGV.fetch(3, "-") : ARGV.fetch(3)
KEY_ID = ENV.fetch("ASC_KEY_ID", "6QN4G1IJDEP1")
KEY_PATH = ENV.fetch("ASC_KEY_PATH", File.expand_path("~/.appstoreconnect/private_keys/AuthKey_#{KEY_ID}.p8"))
BASE_URL = "https://api.appstoreconnect.apple.com"
LOCALES = %w[en-US zh-Hans ja es-ES fr-FR pt-BR it hi de-DE zh-Hant es-MX].freeze
WHATS_NEW_ONLY = ENV["ASC_WHATS_NEW_ONLY"] == "1"
WHATS_NEW_PATH = ENV["ASC_WHATS_NEW_PATH"]

def base64url(value)
  Base64.urlsafe_encode64(value, padding: false)
end

def jwt
  now = Time.now.to_i
  header = base64url(JSON.generate(alg: "ES256", kid: KEY_ID, typ: "JWT"))
  payload = base64url(JSON.generate(sub: "user", iat: now, exp: now + 1_000, aud: "appstoreconnect-v1"))
  signing_input = "#{header}.#{payload}"
  key = OpenSSL::PKey.read(File.read(KEY_PATH))
  sequence = OpenSSL::ASN1.decode(key.sign("SHA256", signing_input))
  raw_signature = sequence.value.map do |integer|
    hex = integer.value.to_s(16)
    hex = "0#{hex}" if hex.length.odd?
    [hex].pack("H*").rjust(32, "\0")
  end.join
  "#{signing_input}.#{base64url(raw_signature)}"
end

def request(method, path, payload = nil)
  uri = URI.join(BASE_URL, path)
  request = Net::HTTP.const_get(method.capitalize).new(uri)
  request["Authorization"] = "Bearer #{jwt}"
  request["Content-Type"] = "application/json"
  request.body = JSON.generate(payload) if payload
  response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
  parsed = response.body.empty? ? {} : JSON.parse(response.body)
  return parsed if response.is_a?(Net::HTTPSuccess)

  warn JSON.pretty_generate(parsed)
  abort "App Store Connect #{method} #{path} failed with HTTP #{response.code}"
end

def parse_metadata(path)
  matches = File.read(path).scan(/^## .*?— `([^`]+)`\n(.*?)(?=^## |\z)/m)
  locale_counts = matches.each_with_object(Hash.new(0)) { |(locale, _body), counts| counts[locale] += 1 }
  duplicates = locale_counts.select { |_locale, count| count > 1 }.keys
  unexpected = locale_counts.keys - LOCALES
  missing = LOCALES - locale_counts.keys

  errors = []
  errors << "duplicate locales: #{duplicates.join(', ')}" unless duplicates.empty?
  errors << "unexpected locales: #{unexpected.join(', ')}" unless unexpected.empty?
  errors << "missing locales: #{missing.join(', ')}" unless missing.empty?
  abort "Invalid metadata locale set (#{errors.join('; ')})" unless errors.empty?

  sections = matches.to_h
  LOCALES.to_h do |locale|
    blocks = sections.fetch(locale).scan(/```text\n(.*?)\n```/m).flatten
    abort "Expected six metadata fields for #{locale}, found #{blocks.length}" unless blocks.length == 6
    [locale, {
      name: blocks[0].strip, subtitle: blocks[1].strip, promotionalText: blocks[2].strip, keywords: blocks[3].strip,
      description: blocks[4].strip, whatsNew: blocks[5].strip
    }]
  end
end

class DuplicateKeyHash < Hash
  attr_reader :duplicate_keys

  def initialize
    super
    @duplicate_keys = []
  end

  def []=(key, value)
    @duplicate_keys << key if key?(key)
    super
  end
end

def parse_whats_new(path)
  values = JSON.parse(File.read(path), object_class: DuplicateKeyHash)
  abort "What's New source must be a JSON object" unless values.is_a?(DuplicateKeyHash)

  duplicates = values.duplicate_keys.uniq
  unexpected = values.keys - LOCALES
  missing = LOCALES - values.keys
  errors = []
  errors << "duplicate locales: #{duplicates.join(', ')}" unless duplicates.empty?
  errors << "unexpected locales: #{unexpected.join(', ')}" unless unexpected.empty?
  errors << "missing locales: #{missing.join(', ')}" unless missing.empty?
  abort "Invalid What's New locale set (#{errors.join('; ')})" unless errors.empty?

  LOCALES.to_h do |locale|
    value = values.fetch(locale)
    abort "What's New for #{locale} must be a string" unless value.is_a?(String)
    [locale, { whatsNew: value.strip }]
  end
end

def character_count(value)
  value.each_grapheme_cluster.count
end

def validate_metadata(metadata)
  errors = []
  single_line_limits = { name: 30, subtitle: 30, promotionalText: 170, keywords: nil }
  multiline_limits = { description: 4_000, whatsNew: 4_000 }

  metadata.each do |locale, fields|
    fields.each do |field, value|
      errors << "#{locale} #{field} is empty" if value.empty?
    end

    single_line_limits.each do |field, limit|
      value = fields.fetch(field)
      errors << "#{locale} #{field} must be one line" if value.include?("\n")
      next unless limit

      count = character_count(value)
      errors << "#{locale} #{field} is #{count} characters (limit #{limit})" if count > limit
    end

    keyword_bytes = fields.fetch(:keywords).bytesize
    errors << "#{locale} keywords are #{keyword_bytes} UTF-8 bytes (limit 100)" if keyword_bytes > 100

    multiline_limits.each do |field, limit|
      count = character_count(fields.fetch(field))
      errors << "#{locale} #{field} is #{count} characters (limit #{limit})" if count > limit
    end
  end

  abort "Metadata validation failed:\n- #{errors.join("\n- ")}" unless errors.empty?

  puts "Validated #{metadata.length} locales from #{METADATA_PATH}"
end

def validate_whats_new(metadata, path)
  errors = []
  metadata.each do |locale, fields|
    value = fields.fetch(:whatsNew)
    errors << "#{locale} whatsNew is empty" if value.empty?
    count = character_count(value)
    errors << "#{locale} whatsNew is #{count} characters (limit 4000)" if count > 4_000
  end
  abort "What's New validation failed:\n- #{errors.join("\n- ")}" unless errors.empty?

  puts "Validated #{metadata.length} What's New locales from #{path}"
end

def chinese_locale?(locale)
  %w[zh-Hans zh-Hant].include?(locale)
end

def resource(type, id: nil, attributes: nil, relationships: nil)
  data = { type: type }
  data[:id] = id if id
  data[:attributes] = attributes if attributes
  data[:relationships] = relationships if relationships
  { data: data }
end

def attributes_match?(resource_data, desired)
  desired.all? do |key, value|
    resource_data.dig("attributes", key.to_s) == value
  end
end

if WHATS_NEW_ONLY
  abort "ASC_WHATS_NEW_PATH is required when ASC_WHATS_NEW_ONLY=1" if WHATS_NEW_PATH.nil? || WHATS_NEW_PATH.empty?

  metadata = parse_whats_new(WHATS_NEW_PATH)
  validate_whats_new(metadata, WHATS_NEW_PATH)
else
  metadata = parse_metadata(METADATA_PATH)
  if WHATS_NEW_PATH && !WHATS_NEW_PATH.empty?
    overrides = parse_whats_new(WHATS_NEW_PATH)
    metadata.each do |locale, fields|
      fields[:whatsNew] = overrides.fetch(locale).fetch(:whatsNew)
    end
  end
  validate_metadata(metadata)
  validate_whats_new(metadata, WHATS_NEW_PATH) if WHATS_NEW_PATH && !WHATS_NEW_PATH.empty?
end
exit 0 if VALIDATE_ONLY

unless WHATS_NEW_ONLY
  app_info_localizations = request("Get", "/v1/appInfos/#{APP_INFO_ID}/appInfoLocalizations?limit=50")
    .fetch("data").to_h { |item| [item.dig("attributes", "locale"), item] }

  metadata.each do |locale, fields|
    english_urls = !chinese_locale?(locale)
    attributes = {
      name: fields[:name],
      subtitle: fields[:subtitle],
      privacyPolicyUrl: english_urls ? "https://castreader.com/en/privacy-policy" : "https://castreader.com/zh/privacy-policy",
      privacyChoicesUrl: english_urls ? "https://castreader.com/en/terms-of-service" : "https://castreader.com/zh/terms-of-service"
    }
    existing = app_info_localizations[locale]
    if existing
      if attributes_match?(existing, attributes)
        puts "Unchanged app info: #{locale}"
      else
        request("Patch", "/v1/appInfoLocalizations/#{existing.fetch("id")}", resource("appInfoLocalizations", id: existing.fetch("id"), attributes: attributes))
        puts "Updated app info: #{locale}"
      end
    else
      relationships = { appInfo: { data: { type: "appInfos", id: APP_INFO_ID } } }
      request("Post", "/v1/appInfoLocalizations", resource("appInfoLocalizations", attributes: attributes.merge(locale: locale), relationships: relationships))
      puts "Created app info: #{locale}"
    end
  end
end

version_localizations = request("Get", "/v1/appStoreVersions/#{VERSION_ID}/appStoreVersionLocalizations?limit=50")
  .fetch("data").to_h { |item| [item.dig("attributes", "locale"), item] }

metadata.each do |locale, fields|
  attributes = if WHATS_NEW_ONLY
    { whatsNew: fields[:whatsNew] }
  else
    english_urls = !chinese_locale?(locale)
    {
      description: fields[:description],
      keywords: fields[:keywords],
      marketingUrl: english_urls ? "https://castreader.com/castreader-app" : "https://castreader.com/zh/castreader-app",
      promotionalText: fields[:promotionalText],
      supportUrl: english_urls ? "https://castreader.com" : "https://castreader.com/",
      whatsNew: fields[:whatsNew]
    }
  end
  existing = version_localizations[locale]
  if existing
    if attributes_match?(existing, attributes)
      puts "Unchanged version metadata: #{locale}"
    else
      request("Patch", "/v1/appStoreVersionLocalizations/#{existing.fetch("id")}", resource("appStoreVersionLocalizations", id: existing.fetch("id"), attributes: attributes))
      puts "Updated version metadata: #{locale}"
    end
  else
    relationships = { appStoreVersion: { data: { type: "appStoreVersions", id: VERSION_ID } } }
    request("Post", "/v1/appStoreVersionLocalizations", resource("appStoreVersionLocalizations", attributes: attributes.merge(locale: locale), relationships: relationships))
    puts "Created version metadata: #{locale}"
  end
end

unless BUILD_ID == "-" || WHATS_NEW_ONLY
  build_relationship = { build: { data: { type: "builds", id: BUILD_ID } } }
  request("Patch", "/v1/appStoreVersions/#{VERSION_ID}", resource("appStoreVersions", id: VERSION_ID, relationships: build_relationship))
  puts "Attached build #{BUILD_ID}"
end

unless WHATS_NEW_ONLY
  review_response = request("Get", "/v1/appStoreVersions/#{VERSION_ID}/appStoreReviewDetail")
  unless review_response["data"]
    review_attributes = {
      contactFirstName: "Vin",
      contactLastName: "Xu",
      contactPhone: "+86-13918641416",
      contactEmail: "328644490@qq.com",
      demoAccountRequired: false
    }
    relationships = { appStoreVersion: { data: { type: "appStoreVersions", id: VERSION_ID } } }
    request("Post", "/v1/appStoreReviewDetails", resource("appStoreReviewDetails", attributes: review_attributes, relationships: relationships))
    puts "Created review contact details"
  else
    puts "Review contact details already present"
  end
end
