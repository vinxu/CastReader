#!/usr/bin/env ruby
require File.expand_path('~/.codex/skills/submit-castreader-ios-to-app-store/scripts/asc_client.rb')
version_id='b4c6afe6-bf93-475e-ae52-0af7b5bee9ab'
c=ASCClient.new
version=c.request('GET',"/v1/appStoreVersions/#{version_id}")['data']
abort 'Wrong version/platform/state' unless version['attributes'].values_at('versionString','platform','appStoreState')==['1.2.47','MAC_OS','PREPARE_FOR_SUBMISSION']
rows=JSON.parse(File.read('reports/mac-app-store-20261006/metadata.json'))
locales=c.get_all("/v1/appStoreVersions/#{version_id}/appStoreVersionLocalizations?limit=200")
abort 'Locale mismatch' unless rows.map{|r|r['locale']}.sort==locales.map{|l|l.dig('attributes','locale')}.sort
report=[]
rows.each do |row|
 item=locales.find{|l|l.dig('attributes','locale')==row['locale']}
 attrs=row['attributes']
 abort 'Invalid copy' unless attrs['description'].length.between?(1,4000) && attrs['keywords'].length<=100
 differences=attrs.reject{|k,v|item['attributes'][k]==v}
 if !differences.empty? && ARGV.include?('--execute')
  c.request('PATCH',"/v1/appStoreVersionLocalizations/#{item['id']}",{data:{type:'appStoreVersionLocalizations',id:item['id'],attributes:differences}})
 end
 report << {locale:row['locale'],fields:differences.keys,descriptionLength:attrs['description'].length}
end
if ARGV.include?('--execute')
 after=c.get_all("/v1/appStoreVersions/#{version_id}/appStoreVersionLocalizations?limit=200")
 rows.each do |r|
  actual=after.find{|a|a.dig('attributes','locale')==r['locale']}['attributes']
  abort "Readback mismatch #{r['locale']}" unless r['attributes'].all?{|k,v|actual[k]==v}
 end
 File.write('reports/mac-app-store-20261006/metadata-verified.json',JSON.pretty_generate(report)+"\n")
end
puts JSON.pretty_generate(executed:ARGV.include?('--execute'),localizations:report)
