#!/usr/bin/env ruby
# This release may change only What's New and the selected build.
require 'json'
require 'time'
require_relative '/Users/xuxuheng/.codex/skills/submit-castreader-ios-to-app-store/scripts/asc_client'

VERSION_ID = '213c6094-64f1-45e0-bde4-da467d93d7b5'
INFO_ID = '75498bac-ab20-4f71-9bed-51e0a923c58b'
LOCALES = %w[en-US zh-Hans ja es-ES fr-FR pt-BR it hi de-DE zh-Hant es-MX].sort.freeze
ROOT = File.expand_path('../..', __dir__)
BEFORE = File.join(__dir__, 'user-metadata-before.json')

def localizations(client)
  client.get_all("/v1/appStoreVersions/#{VERSION_ID}/appStoreVersionLocalizations?limit=50")
end

def snapshot(client)
  version = client.request('GET', "/v1/appStoreVersions/#{VERSION_ID}").fetch('data')
  abort 'Wrong version' unless version.dig('attributes', 'versionString') == '1.2.35'
  locales = localizations(client)
  infos = client.get_all("/v1/appInfos/#{INFO_ID}/appInfoLocalizations?limit=50")
  [locales, infos].each do |items|
    abort 'Expected exactly 11 locales' unless items.map { |i| i.dig('attributes', 'locale') }.sort == LOCALES
  end
  screenshots = locales.to_h do |item|
    sets = client.get_all("/v1/appStoreVersionLocalizations/#{item.fetch('id')}/appScreenshotSets?limit=50")
    entries = sets.sort_by { |set| set.fetch('id') }.map do |set|
      images = client.get_all("/v1/appScreenshotSets/#{set.fetch('id')}/appScreenshots?limit=50")
      { 'id' => set.fetch('id'), 'attributes' => set.fetch('attributes'),
        'images' => images.map { |image| {
          'id' => image.fetch('id'),
          'attributes' => image.fetch('attributes').select { |key, _| %w[fileName fileSize sourceFileChecksum assetDeliveryState].include?(key) }
        } } }
    end
    [item.dig('attributes', 'locale'), entries]
  end
  {
    'versionId' => VERSION_ID, 'appInfoId' => INFO_ID,
    'versionFields' => version.fetch('attributes').select { |key, _| %w[copyright releaseType earliestReleaseDate].include?(key) },
    'appInfo' => infos.to_h { |i| [i.dig('attributes', 'locale'), i.fetch('attributes')] },
    'versionCopy' => locales.to_h { |i| [i.dig('attributes', 'locale'), i.fetch('attributes').reject { |key, _| key == 'whatsNew' }] },
    'screenshots' => screenshots
  }
end

def check_preserved(client)
  before = JSON.parse(File.read(BEFORE))
  current = snapshot(client)
  changed = before.keys.reject { |key| before[key] == current[key] }
  abort "Protected metadata changed: #{changed.join(', ')}" unless changed.empty?
  current
end

client = ASCClient.new
case ARGV.fetch(0)
when 'snapshot'
  abort 'Snapshot already exists; do not overwrite user baseline' if File.exist?(BEFORE)
  data = snapshot(client)
  File.write(BEFORE, JSON.pretty_generate(data))
  puts JSON.pretty_generate(saved: BEFORE, screenshots: data.fetch('screenshots').transform_values { |sets| sets.sum { |set| set.fetch('images').length } })
when 'whats-new'
  check_preserved(client)
  notes = JSON.parse(File.read(File.join(ROOT, 'docs/AppStore-Whats-New-1.2.35.json')))
  abort 'Wrong update locales' unless notes.keys.sort == LOCALES
  changed = []
  localizations(client).each do |item|
    locale = item.dig('attributes', 'locale')
    text = notes.fetch(locale)
    next if item.dig('attributes', 'whatsNew') == text
    path = "/v1/appStoreVersionLocalizations/#{item.fetch('id')}"
    begin
      client.request('PATCH', path, data: {type: 'appStoreVersionLocalizations', id: item.fetch('id'), attributes: {whatsNew: text}})
    rescue ASCError => error
      raise unless error.ambiguous_write && client.request('GET', path).dig('data', 'attributes', 'whatsNew') == text
    end
    changed << locale
  end
  check_preserved(client)
  actual = localizations(client).to_h { |item| [item.dig('attributes', 'locale'), item.dig('attributes', 'whatsNew')] }
  abort 'Update readback differs' unless actual == notes
  result = {time: Time.now.utc.iso8601, updatedLocales: changed, verifiedLocales: actual.keys.sort, protectedMetadataUnchanged: true}
  File.write(File.join(__dir__, 'whats-new-readback.json'), JSON.pretty_generate(result))
  puts JSON.pretty_generate(result)
when 'attach-build'
  build_id = ARGV.fetch(1)
  build = client.request('GET', "/v1/builds/#{build_id}").fetch('data')
  abort 'Build is not 56 / VALID / APP_STORE_ELIGIBLE' unless build.dig('attributes', 'version') == '56' && build.dig('attributes', 'processingState') == 'VALID' && build.dig('attributes', 'buildAudienceType') == 'APP_STORE_ELIGIBLE'
  path = "/v1/appStoreVersions/#{VERSION_ID}/relationships/build"
  unless client.request('GET', path).dig('data', 'id') == build_id
    begin
      client.request('PATCH', path, data: {type: 'builds', id: build_id})
    rescue ASCError => error
      raise unless error.ambiguous_write && client.request('GET', path).dig('data', 'id') == build_id
    end
  end
  abort 'Build attachment mismatch' unless client.request('GET', path).dig('data', 'id') == build_id
  puts JSON.pretty_generate(versionId: VERSION_ID, attachedBuildId: build_id)
when 'verify'
  data = check_preserved(client)
  notes = JSON.parse(File.read(File.join(ROOT, 'docs/AppStore-Whats-New-1.2.35.json')))
  actual = localizations(client).to_h { |item| [item.dig('attributes', 'locale'), item.dig('attributes', 'whatsNew')] }
  abort 'Update readback differs' unless actual == notes
  result = {time: Time.now.utc.iso8601, protectedMetadataUnchanged: true, whatsNewMatches: true,
            appInfoLocales: data.fetch('appInfo').keys.sort,
            screenshots: data.fetch('screenshots').transform_values { |sets| sets.sum { |set| set.fetch('images').length } }}
  File.write(File.join(__dir__, 'metadata-preservation-audit.json'), JSON.pretty_generate(result))
  puts JSON.pretty_generate(result)
else
  abort 'Use snapshot, whats-new, attach-build BUILD_ID or verify'
end
