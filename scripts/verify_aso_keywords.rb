#!/usr/bin/env ruby
# frozen_string_literal: true
# Read-only ASO validation: keywords, names/subtitles, and iOS descriptions.
# Defaults to the latest released iOS version, never a Mac version.
require 'optparse'
require_relative 'aso_metadata'
require_relative 'app_store_connect_api'
options = { platform: 'IOS' }
OptionParser.new do |p|
  p.on('--platform PLATFORM', %w[IOS MAC_OS]) { |v| options[:platform] = v }
  p.on('--version-id ID') { |v| options[:id] = v }
  p.on('--app-info-id ID') { |v| options[:info_id] = v }
  p.on('--snapshot PATH') { |v| options[:snapshot] = v }
  p.on('--catalog-only') { options[:catalog_only] = true }
end.parse!
options[:number] = ARGV.shift
abort 'Unexpected arguments' unless ARGV.empty?
catalog = ASOMetadata.catalog
languages = JSON.parse(File.read(File.join(ASOMetadata::ROOT, 'config/ios-language-capabilities.json'))).dig('serviceRegions', 'global')
approved = JSON.parse(File.read(File.join(ASOMetadata::ROOT, 'docs/aso/approved-keywords.json')))
errors = ASOMetadata.validate(catalog, languages: languages, approved: approved)
descriptions = ASOMetadata.descriptions
errors.concat(ASOMetadata.validate_descriptions(descriptions, search_catalog: catalog))
abort errors.join("\n") unless errors.empty?
if options[:catalog_only]
  puts "PASS: #{catalog['localizations'].size} store locales; #{languages.size} app languages accounted for"
  exit
end
fetch_all = lambda do |path|
  ASOMetadata.get_all(path) do |page|
    response = asc_request('GET', page)
    abort "ASC read failed (#{response.code})" unless response.is_a?(Net::HTTPSuccess)
    JSON.parse(response.body)
  end
end
snapshot = options[:snapshot] && JSON.parse(File.read(options[:snapshot]))
versions = snapshot ? snapshot.fetch('versions').map { |x| x.fetch('version') } : fetch_all.call("/v1/apps/6757636395/appStoreVersions?filter[platform]=#{options[:platform]}&limit=200")
version = ASOMetadata.select_version(versions, platform: options[:platform], number: options[:number], id: options[:id])
abort 'Target version not found on the selected platform' unless version
infos = snapshot ? snapshot.fetch('appInfos').map { |x| x.fetch('appInfo') } : fetch_all.call('/v1/apps/6757636395/appInfos?limit=200')
info = if options[:info_id]
  infos.find { |i| i['id'] == options[:info_id] }
elsif %w[READY_FOR_SALE READY_FOR_DISTRIBUTION].include?(version.dig('attributes', 'appStoreState'))
  infos.find { |i| %w[READY_FOR_SALE READY_FOR_DISTRIBUTION].include?(i.dig('attributes', 'appStoreState')) }
else
  pending = infos.reject { |i| %w[READY_FOR_SALE READY_FOR_DISTRIBUTION].include?(i.dig('attributes', 'appStoreState')) }
  pending.one? ? pending.first : nil
end
abort 'App Info is ambiguous or missing; supply --app-info-id' unless info
locs = snapshot ? snapshot.fetch('versions').find { |x| x['version']['id'] == version['id'] }.fetch('localizations') : fetch_all.call("/v1/appStoreVersions/#{version['id']}/appStoreVersionLocalizations?limit=200")
info_locs = snapshot ? snapshot.fetch('appInfos').find { |x| x['appInfo']['id'] == info['id'] }.fetch('localizations') : fetch_all.call("/v1/appInfos/#{info['id']}/appInfoLocalizations?limit=200")
errors = ASOMetadata.compare(catalog, version_localizations: locs, app_info_localizations: info_locs)
errors.concat(ASOMetadata.compare_descriptions(descriptions, version_localizations: locs)) if options[:platform] == 'IOS'
puts JSON.pretty_generate({ passed: errors.empty?, platform: options[:platform], version: version['attributes']['versionString'], versionId: version['id'], appInfoId: info['id'], checkedLocales: locs.size, errors: errors })
exit(errors.empty? ? 0 : 1)
