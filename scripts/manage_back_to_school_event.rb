#!/usr/bin/env ruby
# frozen_string_literal: true

require "base64"
require "json"
require "net/http"
require "openssl"
require "time"
require "uri"

KEY_ID = ENV.fetch("ASC_KEY_ID", "6QN4G1IJDEP1")
KEY_PATH = ENV.fetch(
  "ASC_KEY_PATH",
  File.expand_path("~/.appstoreconnect/private_keys/AuthKey_#{KEY_ID}.p8")
)
BASE_URL = "https://api.appstoreconnect.apple.com"
APP_ID = "6757636395"
REFERENCE_NAME = "BTS_STUDY_BOOST_2026"
EXECUTE = ARGV.include?("--execute")

EVENT_SCHEDULE = {
  publishStart: "2026-08-06T00:00:00Z",
  eventStart: "2026-08-18T00:00:00Z",
  eventEnd: "2026-09-15T23:59:00Z"
}.freeze

EVENT_ATTRIBUTES = {
  badge: "CHALLENGE",
  deepLink: "castreader://study",
  primaryLocale: "en-US",
  priority: "NORMAL",
  purchaseRequirement: "NO_COST_ASSOCIATED",
  purpose: "ATTRACT_NEW_USERS"
}.freeze

MUTABLE_EVENT_STATES = %w[DRAFT REJECTED].freeze

ASSET_DIRECTORY = File.expand_path(
  "../AppStoreAssets/in-app-events/back-to-school-2026",
  __dir__
)

LOCALIZATIONS = {
  "en-US" => {
    name: "Back-to-School Study Boost",
    shortDescription: "Study on 7 different days by September 15",
    longDescription: "Import materials, listen with synced highlights, and use AI explanations. Study on 7 different days by September 15."
  },
  "zh-Hans" => {
    name: "开学季 · 学习加速",
    shortDescription: "截至 9 月 15 日，完成 7 个不同学习日",
    longDescription: "导入教材或讲义，边听边看同步高亮，用 AI 解读难点；截至 9 月 15 日，完成 7 个不同学习日。"
  },
  "ja" => {
    name: "新学期・スタディブースト",
    shortDescription: "9月15日までに別々の7日間学習しよう",
    longDescription: "教材を読み込み、同期ハイライト付きで聴き、AI解説で難所を理解。9月15日までに別々の7日間学習しましょう。"
  },
  "es-ES" => {
    name: "Impulso de vuelta a clase",
    shortDescription: "Estudia 7 días distintos hasta el 15 de sept.",
    longDescription: "Importa textos, escucha con resaltado sincronizado y usa explicaciones de IA. Estudia 7 días distintos hasta el 15/9."
  },
  "fr-FR" => {
    name: "Boost d’études de rentrée",
    shortDescription: "Étudiez 7 jours différents d’ici au 15 sept.",
    longDescription: "Importez un cours. Suivez le surlignage synchronisé et les explications IA. Étudiez 7 jours différents d’ici au 15/9."
  },
  "de-DE" => {
    name: "Lernboost zum Schulstart",
    shortDescription: "Lerne bis 15. Sept. an 7 verschiedenen Tagen",
    longDescription: "Importiere Texte, nutze synchrone Hervorhebung und KI-Erklärungen. Lerne bis 15. Sept. an 7 verschiedenen Tagen."
  },
  "pt-BR" => {
    name: "Impulso de volta às aulas",
    shortDescription: "Estude em 7 dias diferentes até 15 de setembro",
    longDescription: "Importe textos, ouça com destaques sincronizados e use explicações de IA. Estude em 7 dias diferentes até 15/9."
  },
  "it" => {
    name: "Sprint studio per il rientro",
    shortDescription: "Studia in 7 giorni diversi entro il 15 settembre",
    longDescription: "Importa testi, ascolta con evidenziazione sincronizzata e usa spiegazioni IA. Studia 7 giorni diversi entro il 15 set."
  },
  "hi" => {
    name: "स्कूल वापसी स्टडी बूस्ट",
    shortDescription: "15 सितंबर तक 7 अलग दिनों में पढ़ें",
    longDescription: "सामग्री खोलें, सिंक हाइलाइट के साथ सुनें और AI से कठिन भाग समझें। 15 सितंबर तक 7 अलग दिनों में पढ़ें।"
  }
}.freeze

LOCALIZATION_LIMITS = {
  name: 30,
  shortDescription: 50,
  longDescription: 120
}.freeze

ASSETS = {
  "EVENT_CARD" => {
    file: "event-card-1920x1080.png",
    width: 1_920,
    height: 1_080
  },
  "EVENT_DETAILS_PAGE" => {
    file: "event-details-1080x1920.png",
    width: 1_080,
    height: 1_920
  }
}.freeze

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
  if method.to_sym != :get && !EXECUTE
    abort "Refusing App Store Connect #{method.to_s.upcase} without --execute"
  end

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

def validate_configuration!
  abort "Expected exactly 9 event localizations" unless LOCALIZATIONS.length == 9
  abort "Missing primary event localization" unless LOCALIZATIONS.key?(EVENT_ATTRIBUTES.fetch(:primaryLocale))

  LOCALIZATIONS.each do |locale, attributes|
    LOCALIZATION_LIMITS.each do |attribute, limit|
      value = attributes.fetch(attribute)
      next if value.length <= limit

      abort "#{locale} #{attribute} is #{value.length} characters; maximum is #{limit}"
    end
  end

  publish_start = Time.iso8601(EVENT_SCHEDULE.fetch(:publishStart))
  event_start = Time.iso8601(EVENT_SCHEDULE.fetch(:eventStart))
  event_end = Time.iso8601(EVENT_SCHEDULE.fetch(:eventEnd))
  abort "Event dates must satisfy publishStart < eventStart < eventEnd" unless publish_start < event_start && event_start < event_end
end

def all_territory_codes
  path = "/v1/territories?limit=200"
  codes = []
  expected_total = nil

  loop do
    response = asc_request(:get, path)
    expected_total ||= response.dig("meta", "paging", "total")
    codes.concat(response.fetch("data").map { |territory| territory.fetch("id") })
    path = response.dig("links", "next")
    break if path.nil? || path.empty?
  end

  codes = codes.uniq.sort
  abort "App Store Connect returned no active territories" if codes.empty?
  if expected_total && codes.length != expected_total
    abort "Expected #{expected_total} active territories, received #{codes.length} unique territory IDs"
  end

  codes
end

def desired_event_attributes(territory_codes)
  EVENT_ATTRIBUTES.merge(
    territorySchedules: [EVENT_SCHEDULE.merge(territories: territory_codes)]
  )
end

def normalized_time(value)
  Time.iso8601(value).utc.iso8601
rescue ArgumentError, TypeError
  value
end

def normalized_schedules(schedules)
  Array(schedules).map do |schedule|
    {
      publishStart: normalized_time(schedule["publishStart"] || schedule[:publishStart]),
      eventStart: normalized_time(schedule["eventStart"] || schedule[:eventStart]),
      eventEnd: normalized_time(schedule["eventEnd"] || schedule[:eventEnd]),
      territories: Array(schedule["territories"] || schedule[:territories]).sort
    }
  end.sort_by { |schedule| [schedule.fetch(:eventStart), schedule.fetch(:eventEnd)] }
end

def event_configuration_matches?(event, desired_attributes)
  current = event.fetch("attributes")
  scalar_attributes_match = EVENT_ATTRIBUTES.all? do |attribute, desired_value|
    current[attribute.to_s] == desired_value
  end
  scalar_attributes_match &&
    normalized_schedules(current["territorySchedules"]) == normalized_schedules(desired_attributes.fetch(:territorySchedules))
end

def assert_event_mutable!(event)
  state = event.dig("attributes", "eventState")
  return if MUTABLE_EVENT_STATES.include?(state)

  abort "Refusing to modify app event #{event.fetch("id")} in state #{state || "UNKNOWN"}"
end

def png_dimensions(path)
  header = File.binread(path, 24)
  abort "Not a PNG: #{path}" unless header.start_with?("\x89PNG\r\n\x1A\n".b)

  header.byteslice(16, 8).unpack("NN")
end

def upload_operations(path, operations)
  abort "Refusing asset upload without --execute" unless EXECUTE

  File.open(path, "rb") do |file|
    operations.each_with_index do |operation, index|
      offset = operation.fetch("offset")
      length = operation.fetch("length")
      file.seek(offset)
      bytes = file.read(length)
      abort "Unable to read upload chunk #{index + 1}: #{path}" unless bytes&.bytesize == length

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

def wait_for_screenshot_delivery(screenshot_id, timeout_seconds: 1_800)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  loop do
    screenshot = asc_request(
      :get,
      "/v1/appEventScreenshots/#{screenshot_id}?fields%5BappEventScreenshots%5D=appEventAssetType,fileName,assetDeliveryState"
    ).fetch("data")
    state = screenshot.dig("attributes", "assetDeliveryState", "state")
    return screenshot if state == "COMPLETE"
    abort "App event screenshot #{screenshot_id} failed processing" if state == "FAILED"
    if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > timeout_seconds
      abort "App event screenshot #{screenshot_id} processing timed out"
    end

    sleep 10
  end
end

def find_event
  fields = %w[
    referenceName badge eventState deepLink purchaseRequirement primaryLocale
    priority purpose territorySchedules
  ].join(",")
  asc_request(
    :get,
    "/v1/apps/#{APP_ID}/appEvents?limit=50&fields%5BappEvents%5D=#{fields}"
  ).fetch("data").find do |event|
    event.dig("attributes", "referenceName") == REFERENCE_NAME
  end
end

def create_event(attributes)
  asc_request(
    :post,
    "/v1/appEvents",
    resource(
      "appEvents",
      attributes: attributes.merge(referenceName: REFERENCE_NAME),
      relationships: {
        app: { data: { type: "apps", id: APP_ID } }
      }
    )
  ).fetch("data")
end

def update_event(event, attributes)
  if event_configuration_matches?(event, attributes)
    puts "Event metadata and territory schedule already match"
    return event
  end

  asc_request(
    :patch,
    "/v1/appEvents/#{event.fetch("id")}",
    resource(
      "appEvents",
      id: event.fetch("id"),
      attributes: attributes
    )
  ).fetch("data")
end

def ensure_localization(event_id, locale, attributes)
  existing = asc_request(
    :get,
    "/v1/appEvents/#{event_id}/localizations?limit=50&fields%5BappEventLocalizations%5D=locale,name,shortDescription,longDescription"
  ).fetch("data").find { |item| item.dig("attributes", "locale") == locale }
  if existing
    matches = attributes.all? do |attribute, desired_value|
      existing.dig("attributes", attribute.to_s) == desired_value
    end
    return existing if matches

    return asc_request(
      :patch,
      "/v1/appEventLocalizations/#{existing.fetch("id")}",
      resource(
        "appEventLocalizations",
        id: existing.fetch("id"),
        attributes: attributes
      )
    ).fetch("data")
  end

  asc_request(
    :post,
    "/v1/appEventLocalizations",
    resource(
      "appEventLocalizations",
      attributes: attributes.merge(locale: locale),
      relationships: {
        appEvent: { data: { type: "appEvents", id: event_id } }
      }
    )
  ).fetch("data")
end

def ensure_screenshot(localization_id, asset_type, path)
  existing = asc_request(
    :get,
    "/v1/appEventLocalizations/#{localization_id}/appEventScreenshots?limit=50"
  ).fetch("data").find do |item|
    item.dig("attributes", "appEventAssetType") == asset_type &&
      item.dig("attributes", "fileName") == File.basename(path)
  end
  if existing
    state = existing.dig("attributes", "assetDeliveryState", "state")
    return existing if state == "COMPLETE"
    abort "Existing app event screenshot #{existing.fetch("id")} is FAILED" if state == "FAILED"

    operations = existing.dig("attributes", "uploadOperations")
    unless operations.nil? || operations.empty?
      upload_operations(path, operations)
      asc_request(
        :patch,
        "/v1/appEventScreenshots/#{existing.fetch("id")}",
        resource(
          "appEventScreenshots",
          id: existing.fetch("id"),
          attributes: { uploaded: true }
        )
      )
    end
    return wait_for_screenshot_delivery(existing.fetch("id"))
  end

  screenshot = asc_request(
    :post,
    "/v1/appEventScreenshots",
    resource(
      "appEventScreenshots",
      attributes: {
        appEventAssetType: asset_type,
        fileName: File.basename(path),
        fileSize: File.size(path)
      },
      relationships: {
        appEventLocalization: {
          data: { type: "appEventLocalizations", id: localization_id }
        }
      }
    )
  ).fetch("data")

  operations = screenshot.dig("attributes", "uploadOperations")
  abort "No upload operations returned for #{path}" if operations.nil? || operations.empty?
  upload_operations(path, operations)
  asc_request(
    :patch,
    "/v1/appEventScreenshots/#{screenshot.fetch("id")}",
    resource(
      "appEventScreenshots",
      id: screenshot.fetch("id"),
      attributes: { uploaded: true }
    )
  )
  wait_for_screenshot_delivery(screenshot.fetch("id"))
end

validate_configuration!

ASSETS.each_value do |asset|
  path = File.join(ASSET_DIRECTORY, asset.fetch(:file))
  abort "Missing event asset: #{path}" unless File.file?(path)
  actual = png_dimensions(path)
  expected = [asset.fetch(:width), asset.fetch(:height)]
  abort "Wrong dimensions for #{path}: #{actual.join("x")}, expected #{expected.join("x")}" unless actual == expected
end

unless EXECUTE
  puts JSON.pretty_generate(
    execute: false,
    networkCalls: false,
    referenceName: REFERENCE_NAME,
    eventAttributes: EVENT_ATTRIBUTES,
    territorySchedule: EVENT_SCHEDULE.merge(
      territories: "all active App Store territories from GET /v1/territories"
    ),
    localizationCount: LOCALIZATIONS.length,
    localizations: LOCALIZATIONS,
    assetsPerLocalization: ASSETS.keys,
    executionGate: "Pass --execute to allow writes",
    intentionallyOmitted: ["reviewSubmission"]
  )
  exit 0
end

territory_codes = all_territory_codes
attributes = desired_event_attributes(territory_codes)
event = find_event
if event
  assert_event_mutable!(event)
  event = update_event(event, attributes)
else
  event = create_event(attributes)
end
event_id = event.fetch("id")
puts "Event draft: #{event_id}"
puts "Territory schedule: #{territory_codes.length} active App Store territories"

LOCALIZATIONS.each do |locale, attributes|
  localization = ensure_localization(event_id, locale, attributes)
  localization_id = localization.fetch("id")
  puts "Localization #{locale}: #{localization_id}"

  ASSETS.each do |asset_type, asset|
    path = File.join(ASSET_DIRECTORY, asset.fetch(:file))
    screenshot = ensure_screenshot(localization_id, asset_type, path)
    state = screenshot.dig("attributes", "assetDeliveryState", "state") || "PROCESSING"
    puts "  #{asset_type}: #{screenshot.fetch("id")} (#{state})"
  end
end

puts "Challenge draft prepared with deep link, schedule, 9 localizations, and complete assets."
puts "No review submission was created."
