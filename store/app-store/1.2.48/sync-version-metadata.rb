#!/usr/bin/env ruby
# Apply only this release's intended version copy; shared App Info is untouched.
require 'json'
require 'time'
require 'fileutils'
require '/Users/xuxuheng/.codex/skills/submit-castreader-ios-to-app-store/scripts/asc_client'
root = File.expand_path('../../..', __dir__)
report = File.join(root, 'reports/ios-release-1.2.48')
state = JSON.parse(File.read(File.join(report, 'release-state.json')))
version_id = state.fetch('versionId')
meta = JSON.parse(File.read(File.join(__dir__, 'asc-metadata.json')))
raise 'Expected 29 store locales (27 languages + 2 retained variants)' unless meta.size == 29
meta.each do |locale, row|
  {'title'=>30,'subtitle'=>30,'description'=>4000,'whatsNew'=>4000}.each do |key,limit|
    raise "Invalid #{locale}/#{key}" unless row[key].is_a?(String) && !row[key].empty? && row[key].scan(/\X/).length <= limit
  end
  raise "Long keywords #{locale}" if row.fetch('keywords').bytesize > 100
  raise "Other platform reference #{locale}" if row.values.grep(String).join(' ').match?(/google[\s-]*play|play\.google\.com|\bAndroid\b/i)
end
client = ASCClient.new
version = client.request('GET', "/v1/appStoreVersions/#{version_id}").fetch('data')
raise 'Wrong version or state' unless version.dig('attributes','versionString') == '1.2.48' && version.dig('attributes','appStoreState') == 'PREPARE_FOR_SUBMISSION'
items = client.get_all("/v1/appStoreVersions/#{version_id}/appStoreVersionLocalizations?limit=50")
File.write(File.join(report, 'metadata-before-update.json'),JSON.pretty_generate(items)) unless File.exist?(File.join(report, 'metadata-before-update.json'))
existing = items.to_h { |x| [x.dig('attributes','locale'),x] }
fields = %w[description whatsNew keywords promotionalText supportUrl marketingUrl]
plan = meta.map do |locale,row|
  desired = row.select { |k,_| fields.include?(k) }
  item = existing[locale]
  changes = desired.reject { |k,v| item && item.dig('attributes',k)==v }
  {locale:locale, action:item ? 'PATCH' : 'POST', id:item && item['id'], attributes:changes}
end.reject { |x| x[:attributes].empty? }
File.write(File.join(report,'metadata-update-plan.json'),JSON.pretty_generate(plan))
puts JSON.generate(locales:meta.size,updates:plan.size,execute:ARGV.include?('--execute'),sharedAppInfo:'preserved')
exit unless ARGV.include?('--execute')
plan.each do |row|
  attributes = row[:attributes]
  if row[:id]
    item = client.request('PATCH',"/v1/appStoreVersionLocalizations/#{row[:id]}",data:{type:'appStoreVersionLocalizations',id:row[:id],attributes:attributes}).fetch('data')
  else
    item = client.request('POST','/v1/appStoreVersionLocalizations',data:{type:'appStoreVersionLocalizations',attributes:attributes.merge('locale'=>row[:locale]),relationships:{appStoreVersion:{data:{type:'appStoreVersions',id:version_id}}}}).fetch('data')
  end
  File.open(File.join(report,'metadata-write-receipts.jsonl'),'a') { |f| f.puts JSON.generate(locale:row[:locale],id:item['id'],time:Time.now.utc.iso8601) }
  puts "Saved #{row[:locale]} #{item['id']}"
end
actual = client.get_all("/v1/appStoreVersions/#{version_id}/appStoreVersionLocalizations?limit=50")
File.write(File.join(report,'asc-version-localizations-updated.json'),JSON.pretty_generate(actual))
raise 'Locale mismatch' unless actual.map { |x| x.dig('attributes','locale') }.sort == meta.keys.sort
actual.each do |item|
  locale = item.dig('attributes','locale')
  fields.each { |f| raise "Readback mismatch #{locale}/#{f}" unless item.dig('attributes',f)==meta[locale][f] }
end
puts 'Readback verified for every intended field in 29 locales'
