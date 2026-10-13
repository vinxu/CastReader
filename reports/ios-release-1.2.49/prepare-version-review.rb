# Apple permits an app-version submission alongside independent content reviews.
# Do not cancel, edit, or add items to those independent submissions.
require 'json'
require 'time'
require '/Users/xuxuheng/.codex/skills/submit-castreader-ios-to-app-store/scripts/asc_client'
OUT=__dir__; APP='6757636395'; VERSION='680b0b6d-968f-4a0c-a5a2-b8c25496e078'
def save(name,data); File.open(File.join(OUT,name),'w',0o600) { |f| f.write(JSON.pretty_generate(data)+"\n") }; end
audit=JSON.parse(File.read(File.join(OUT,'final-release-audit.json')))
abort 'Final release gate missing' unless audit['status']=='PASS' && audit['versionId']==VERSION && Time.now-Time.iso8601(audit['checkedAt'])<1800
c=ASCClient.new
active=c.get_all("/v1/apps/#{APP}/reviewSubmissions?filter[platform]=IOS&limit=200").reject { |s| %w[COMPLETE CANCELED].include?(s.dig('attributes','state')) }
rows=active.map { |s| {'submission'=>s,'items'=>c.get_all("/v1/reviewSubmissions/#{s['id']}/items?include=appStoreVersion&limit=200")} }
save('review-concurrency-precheck.json',rows)
matching=[]
rows.each do |r|
 r['items'].each do |i|
  rel=i.fetch('relationships').fetch('appStoreVersion')
  abort 'Missing explicit app-version relationship' unless rel.key?('data')
  next if rel['data'].nil?
  abort "Another app version is under review in #{r['submission']['id']}" unless rel['data']['id']==VERSION
  matching << r
 end
end
abort 'Multiple matching version reviews' if matching.size>1
if matching.one?
 selected=matching.first
 abort 'Mixed review items' unless selected['items'].size==1
 submission=selected['submission']
else
 empty=rows.select { |r| r['items'].empty? && r['submission'].dig('attributes','state')=='READY_FOR_REVIEW' }
 receipt_path=File.join(OUT,'own-review-created.json')
 if File.exist?(receipt_path)
  known=JSON.parse(File.read(receipt_path)); submission=active.find { |s| s['id']==known['id'] }
  abort 'Saved submission is missing or no longer empty/ready' unless submission && empty.any? { |r| r['submission']['id']==submission['id'] }
 else
  abort 'An unowned empty submission exists; inspect first' unless empty.empty?
  # Never retry an ambiguous POST automatically; save/read server state first.
  submission=c.request('POST','/v1/reviewSubmissions',{data:{type:'reviewSubmissions',attributes:{platform:'IOS'},relationships:{app:{data:{type:'apps',id:APP}}}}})['data']
  save('own-review-created.json',submission)
 end
 c.request('POST','/v1/reviewSubmissionItems',{data:{type:'reviewSubmissionItems',relationships:{reviewSubmission:{data:{type:'reviewSubmissions',id:submission['id']}},appStoreVersion:{data:{type:'appStoreVersions',id:VERSION}}}}})
end
items=c.get_all("/v1/reviewSubmissions/#{submission['id']}/items?include=appStoreVersion&limit=200")
abort 'Own review item invariant failed' unless items.size==1 && items[0].dig('relationships','appStoreVersion','data','id')==VERSION
result={id:submission['id'],versionId:VERSION,items:items,otherSubmissionsUnmodified:rows.reject { |r| r['submission']['id']==submission['id'] }.map { |r| r['submission']['id'] },checkedAt:Time.now.utc.iso8601}
save('own-review-ready.json',result);puts JSON.pretty_generate(result)
