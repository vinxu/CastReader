#!/usr/bin/env ruby
# Apply only the approved Duo description/update-note additions to the ASO draft.
require 'json'
require 'digest'
require File.expand_path('~/.codex/skills/submit-castreader-ios-to-app-store/scripts/asc_client.rb')
root = File.expand_path('../../..', __dir__)
report = File.join(root, 'reports/ios-duo-20261011')
proposal = JSON.parse(File.read(File.join(report,'metadata-duo-merged.json')))
baseline = JSON.parse(File.read(File.join(report,'metadata-baseline-1249.json')))
execute = ARGV.include?('--execute')
version_id = '680b0b6d-968f-4a0c-a5a2-b8c25496e078'
abort 'Proposal target mismatch' unless proposal.values_at('targetVersion','targetVersionID') == ['1.2.49',version_id]
client = ASCClient.new
version = client.request('GET',"/v1/appStoreVersions/#{version_id}").fetch('data')
abort 'Unexpected target' unless version.dig('attributes','versionString') == '1.2.49' && version.dig('attributes','appStoreState') == 'PREPARE_FOR_SUBMISSION'
actual = client.get_all("/v1/appStoreVersions/#{version_id}/appStoreVersionLocalizations?limit=200")
rows = proposal.fetch('localizations')
abort 'Locale scope changed' unless rows.size == 29 && rows.map{|l|l['locale']}.sort == actual.map{|l|l.dig('attributes','locale')}.sort
rows.each do |row|
  old = baseline.fetch('localizations').find{|l|l['id']==row['sourceLocalizationID']} or abort 'Missing baseline'
  current = actual.find{|l|l['id']==old['id']} or abort 'Localization changed'
  wanted = row.slice('description','whatsNew')
  wanted.each do |field,value|
    abort "Invalid #{row['locale']}/#{field}" unless value.is_a?(String) && value.length <= 4000
    abort "Concurrent edit #{row['locale']}/#{field}" unless [old['attributes'][field],value].include?(current['attributes'][field])
  end
  untouched = old['attributes'].keys - wanted.keys
  abort "Unrelated fields changed #{row['locale']}" unless untouched.all?{|k|current['attributes'][k] == old['attributes'][k]}
  if execute && wanted.any?{|k,v|current['attributes'][k]!=v}
    client.request('PATCH',"/v1/appStoreVersionLocalizations/#{current['id']}",{data:{type:'appStoreVersionLocalizations',id:current['id'],attributes:wanted}})
  end
  puts "#{execute ? 'Applied' : 'Validated'} #{row['locale']}: description + whatsNew"; $stdout.flush
end
if execute
  final = client.get_all("/v1/appStoreVersions/#{version_id}/appStoreVersionLocalizations?limit=200")
  rows.each do |row|
    item = final.find{|l|l['id']==row['sourceLocalizationID']}
    abort 'Readback mismatch' unless row.slice('description','whatsNew').all?{|k,v|item.dig('attributes',k)==v}
    old = baseline['localizations'].find{|l|l['id']==item['id']}
    abort 'Untouched field changed' unless (old['attributes'].keys-%w[description whatsNew]).all?{|k|item['attributes'][k]==old['attributes'][k]}
  end
  File.write(File.join(report,'metadata-duo-applied.json'),JSON.pretty_generate({versionID:version_id,verifiedAt:Time.now.utc.to_s,localizations:final})+"\n",perm:0o600)
end
