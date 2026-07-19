#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"

APP_ID = "6757636395"
VERSION_ID = ARGV.fetch(0)
BUILD_ID = ARGV.fetch(1)
METADATA_PATH = ARGV.fetch(2, File.expand_path("../docs/CastReader-AppStore-Metadata-8-Languages.md", __dir__))
APP_INFO_ID = ARGV.fetch(3)
KEY_ID = ENV.fetch("ASC_KEY_ID", "6QN4G1IJDEP1")
KEY_PATH = ENV.fetch("ASC_KEY_PATH", File.expand_path("~/.appstoreconnect/private_keys/AuthKey_#{KEY_ID}.p8"))
BASE_URL = "https://api.appstoreconnect.apple.com"
LOCALES = %w[en-US zh-Hans ja es-ES fr-FR pt-BR it hi].freeze

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
  sections = File.read(path).scan(/^## .*?— `([^`]+)`\n(.*?)(?=^## |\z)/m).to_h
  LOCALES.to_h do |locale|
    blocks = sections.fetch(locale).scan(/```text\n(.*?)\n```/m).flatten
    abort "Expected six metadata fields for #{locale}, found #{blocks.length}" unless blocks.length == 6
    [locale, {
      name: blocks[0], subtitle: blocks[1], promotionalText: blocks[2], keywords: blocks[3],
      description: blocks[4], whatsNew: blocks[5]
    }]
  end
end

def resource(type, id: nil, attributes: nil, relationships: nil)
  data = { type: type }
  data[:id] = id if id
  data[:attributes] = attributes if attributes
  data[:relationships] = relationships if relationships
  { data: data }
end

metadata = parse_metadata(METADATA_PATH)

app_info_localizations = request("Get", "/v1/appInfos/#{APP_INFO_ID}/appInfoLocalizations?limit=50")
  .fetch("data").to_h { |item| [item.dig("attributes", "locale"), item] }

metadata.each do |locale, fields|
  english_urls = locale != "zh-Hans"
  attributes = {
    name: fields[:name],
    subtitle: fields[:subtitle],
    privacyPolicyUrl: english_urls ? "https://castreader.com/en/privacy-policy" : "https://castreader.com/zh/privacy-policy",
    privacyChoicesUrl: english_urls ? "https://castreader.com/en/terms-of-service" : "https://castreader.com/zh/terms-of-service"
  }
  existing = app_info_localizations[locale]
  if existing
    request("Patch", "/v1/appInfoLocalizations/#{existing.fetch("id")}", resource("appInfoLocalizations", id: existing.fetch("id"), attributes: attributes))
    puts "Updated app info: #{locale}"
  else
    relationships = { appInfo: { data: { type: "appInfos", id: APP_INFO_ID } } }
    request("Post", "/v1/appInfoLocalizations", resource("appInfoLocalizations", attributes: attributes.merge(locale: locale), relationships: relationships))
    puts "Created app info: #{locale}"
  end
end

version_localizations = request("Get", "/v1/appStoreVersions/#{VERSION_ID}/appStoreVersionLocalizations?limit=50")
  .fetch("data").to_h { |item| [item.dig("attributes", "locale"), item] }

metadata.each do |locale, fields|
  english_urls = locale != "zh-Hans"
  attributes = {
    description: fields[:description],
    keywords: fields[:keywords],
    marketingUrl: english_urls ? "https://castreader.com/castreader-app" : "https://castreader.com/zh/castreader-app",
    promotionalText: fields[:promotionalText],
    supportUrl: english_urls ? "https://castreader.com" : "https://castreader.com/",
    whatsNew: fields[:whatsNew]
  }
  existing = version_localizations[locale]
  if existing
    request("Patch", "/v1/appStoreVersionLocalizations/#{existing.fetch("id")}", resource("appStoreVersionLocalizations", id: existing.fetch("id"), attributes: attributes))
    puts "Updated version metadata: #{locale}"
  else
    relationships = { appStoreVersion: { data: { type: "appStoreVersions", id: VERSION_ID } } }
    request("Post", "/v1/appStoreVersionLocalizations", resource("appStoreVersionLocalizations", attributes: attributes.merge(locale: locale), relationships: relationships))
    puts "Created version metadata: #{locale}"
  end
end

unless BUILD_ID == "-"
  build_relationship = { build: { data: { type: "builds", id: BUILD_ID } } }
  request("Patch", "/v1/appStoreVersions/#{VERSION_ID}", resource("appStoreVersions", id: VERSION_ID, relationships: build_relationship))
  puts "Attached build #{BUILD_ID}"
end

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
