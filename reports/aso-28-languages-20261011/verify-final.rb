require '/Users/xuxuheng/.codex/skills/submit-castreader-ios-to-app-store/scripts/asc_client'
require_relative '../../scripts/aso_metadata'
require 'time'
c=ASCClient.new
out='reports/aso-28-languages-20261011'
before=JSON.parse(File.read("#{out}/online-before.json"))
ids=before['versions'].map { |v| v['version']['id'] }+['680b0b6d-968f-4a0c-a5a2-b8c25496e078']
after={'checkedAt'=>Time.now.utc.iso8601,'versions'=>[],'appInfos'=>[]}
ids.each do |id|
 after['versions'] << {'version'=>c.request('GET',"/v1/appStoreVersions/#{id}").fetch('data'),'localizations'=>c.get_all("/v1/appStoreVersions/#{id}/appStoreVersionLocalizations?limit=200")}
end
c.get_all('/v1/apps/6757636395/appInfos?limit=200').each do |i|
 after['appInfos'] << {'appInfo'=>i,'localizations'=>c.get_all("/v1/appInfos/#{i['id']}/appInfoLocalizations?limit=200")}
end
File.write("#{out}/online-after.json",JSON.pretty_generate(after))
pending=after['appInfos'].find { |i| i['appInfo']['id']=='988607e7-fe9f-45ad-9432-86fca303d591' }
checks=[]
['e9065422-ce33-4ff5-81e1-a7b7aef4f7b4','680b0b6d-968f-4a0c-a5a2-b8c25496e078'].each do |id|
 v=after['versions'].find { |v| v['version']['id']==id }
 errors=ASOMetadata.compare(ASOMetadata.catalog,version_localizations:v['localizations'],app_info_localizations:pending['localizations'])
 checks << {versionId:id,platform:v['version']['attributes']['platform'],version:v['version']['attributes']['versionString'],state:v['version']['attributes']['appStoreState'],locales:v['localizations'].size,passed:errors.empty?,errors:errors}
end
preservation=[]
before['versions'].each do |v|
 a=after['versions'].find { |x| x['version']['id']==v['version']['id'] }
 v['localizations'].each do |l|
  now=a['localizations'].find { |x| x['id']==l['id'] }
  expected=l['attributes'].reject { |k,_| k=='keywords' }
  actual=now['attributes'].reject { |k,_| k=='keywords' }
  preservation << "Non-keyword change: #{v['version']['id']}/#{l['attributes']['locale']}" unless actual==expected
 end
end
before['appInfos'].each do |i|
 a=after['appInfos'].find { |x| x['appInfo']['id']==i['appInfo']['id'] }
 i['localizations'].each do |l|
  now=a['localizations'].find { |x| x['id']==l['id'] }
  allowed=i['appInfo']['id']==pending['appInfo']['id'] ? %w[name subtitle] : []
  preservation << "Unexpected App Info change #{l['attributes']['locale']}" unless l['attributes'].reject { |k,_| allowed.include?(k) } == now['attributes'].reject { |k,_| allowed.include?(k) }
 end
end
old_ios=before['versions'].find { |v| v['version']['attributes']['platform']=='IOS' }
new_old_ios=after['versions'].find { |v| v['version']['id']==old_ios['version']['id'] }
old_keywords=old_ios['localizations'].to_h { |l| [l.dig('attributes','locale'),l.dig('attributes','keywords')] }
new_keywords=new_old_ios['localizations'].to_h { |l| [l.dig('attributes','locale'),l.dig('attributes','keywords')] }
build=c.request('GET','/v1/appStoreVersions/680b0b6d-968f-4a0c-a5a2-b8c25496e078/relationships/build')['data']
review=c.request('GET','/v1/reviewSubmissions/c3c2a6cc-598f-4196-9f5d-1188fd743ea2')['data']
receipt={checkedAt:Time.now.utc.iso8601,asoChecks:checks,nonASOFieldsPreserved:preservation.empty?,preservationErrors:preservation,publishedIOSKeywordsUnchanged:old_keywords==new_keywords,iosDraftHasBuild:!build.nil?,existingIOSReviewState:review.dig('attributes','state'),sharedPendingAppInfoId:pending['appInfo']['id'],sharedPendingAppInfoState:pending.dig('appInfo','attributes','appStoreState'),successfulKeywordWrites:58,successfulAppInfoWrites:19,newIOSDraftCreated:'1.2.49',appCodeChanged:false}
File.write("#{out}/completion-receipt.json",JSON.pretty_generate(receipt))
puts JSON.pretty_generate(receipt)
abort 'Final verification failed' unless checks.all? { |r| r[:passed] } && preservation.empty? && old_keywords==new_keywords && build.nil?
