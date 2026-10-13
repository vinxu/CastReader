require '/Users/xuxuheng/.codex/skills/submit-castreader-ios-to-app-store/scripts/asc_client'
require_relative '../../scripts/aso_metadata'
require 'time'
$stdout.sync=true
c=ASCClient.new
catalog=ASOMetadata.catalog
out='reports/aso-28-languages-20261011'
recovered=JSON.parse(File.read("#{out}/ios-draft-recovered.json"))
versions=recovered['versions'].select { |v| v.dig('attributes','platform')=='IOS' && v.dig('attributes','versionString')=='1.2.49' }
abort 'Ambiguous draft' unless versions.one?
version_id=versions.first['id']
version=c.request('GET',"/v1/appStoreVersions/#{version_id}").fetch('data')
abort 'Draft is no longer editable' unless version.dig('attributes','appStoreState')=='PREPARE_FOR_SUBMISSION'
locs=c.get_all("/v1/appStoreVersions/#{version_id}/appStoreVersionLocalizations?limit=200")
File.write("#{out}/ios-draft-localizations-before.json",JSON.pretty_generate(locs))
abort 'Unexpected inherited locales' unless locs.map { |l| l.dig('attributes','locale') }.sort == catalog['localizations'].keys.sort
baseline=JSON.parse(File.read("#{out}/online-before.json"))['versions'].find { |v| v.dig('version','attributes','platform')=='IOS' }['localizations'].to_h { |l| [l.dig('attributes','locale'),l.dig('attributes','keywords')] }
receipt=[]
locs.each do |loc|
 locale=loc.dig('attributes','locale');desired=catalog['localizations'][locale]['keywords'];path="/v1/appStoreVersionLocalizations/#{loc['id']}"
 current=c.request('GET',path).fetch('data').fetch('attributes')
 if current['keywords']==desired
  receipt << {locale:locale,status:'already_matches'};next
 end
 abort "Concurrent keyword change in #{locale}" unless current['keywords']==baseline[locale]
 begin
  c.request('PATCH',path,{data:{type:'appStoreVersionLocalizations',id:loc['id'],attributes:{keywords:desired}}})
 rescue ASCError=>e
  raise unless e.ambiguous_write
  # Never retry a write with an unknown outcome. First read it back.
  readback=c.request('GET',path).fetch('data').fetch('attributes')
  raise unless readback['keywords']==desired
 end
 after=c.request('GET',path).fetch('data').fetch('attributes')
 abort "Readback mismatch #{locale}" unless after['keywords']==desired
 receipt << {locale:locale,status:'applied_and_verified',keywords:desired}
 File.write("#{out}/ios-draft-write-receipt.json",JSON.pretty_generate({checkedAt:Time.now.utc.iso8601,versionId:version_id,items:receipt}))
 puts "Applied iOS draft #{locale}"
end
File.write("#{out}/ios-draft-write-receipt.json",JSON.pretty_generate({checkedAt:Time.now.utc.iso8601,versionId:version_id,items:receipt}))
