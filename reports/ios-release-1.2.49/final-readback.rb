require 'json'
require 'time'
require '/Users/xuxuheng/.codex/skills/submit-castreader-ios-to-app-store/scripts/asc_client'
out=__dir__; c=ASCClient.new
plan=JSON.parse(File.read(File.join(out,'release-plan.json')))
own=JSON.parse(File.read(File.join(out,'own-review-ready.json')))
binding=JSON.parse(File.read(File.join(out,'build-binding.json')))
version=c.request('GET',"/v1/appStoreVersions/#{plan['versionId']}")['data']
submission=c.request('GET',"/v1/reviewSubmissions/#{own['id']}")['data']
build=c.request('GET',"/v1/appStoreVersions/#{plan['versionId']}/build")['data']
items=c.get_all("/v1/reviewSubmissions/#{own['id']}/items?include=appStoreVersion&limit=200")
abort 'Wrong build' unless build['id']==binding['buildId']
abort 'Wrong submission items' unless items.size==1 && items[0].dig('relationships','appStoreVersion','data','id')==plan['versionId']
abort 'Version not submitted' unless %w[WAITING_FOR_REVIEW IN_REVIEW PENDING_APPLE_RELEASE PENDING_DEVELOPER_RELEASE READY_FOR_SALE READY_FOR_DISTRIBUTION].include?(version.dig('attributes','appStoreState'))
abort 'Review not submitted' unless %w[WAITING_FOR_REVIEW IN_REVIEW COMPLETING COMPLETE].include?(submission.dig('attributes','state'))
pre=JSON.parse(File.read(File.join(out,'review-concurrency-precheck.json')))
unrelated=pre.reject { |r| r['submission']['id']==own['id'] }.map do |r|
 id=r['submission']['id']; now=c.request('GET',"/v1/reviewSubmissions/#{id}")['data']; now_items=c.get_all("/v1/reviewSubmissions/#{id}/items?include=appStoreVersion&limit=200")
 abort 'Unrelated review item set changed' unless now_items.map { |i| i['id'] }.sort==r['items'].map { |i| i['id'] }.sort
 abort 'Unrelated review unexpectedly canceled' if now.dig('attributes','state')=='CANCELED'
 {id:id,state:now.dig('attributes','state'),itemsPreserved:true}
end
mac=c.request('GET','/v1/appStoreVersions/e9065422-ce33-4ff5-81e1-a7b7aef4f7b4')['data']
result={status:'PASS',checkedAt:Time.now.utc.iso8601,version:version.dig('attributes','versionString'),build:build.dig('attributes','version'),buildId:build['id'],versionId:version['id'],versionState:version.dig('attributes','appStoreState'),reviewSubmissionId:submission['id'],reviewSubmissionState:submission.dig('attributes','state'),submittedDate:submission.dig('attributes','submittedDate'),releaseType:version.dig('attributes','releaseType'),unrelatedReviews:unrelated,macVersionState:mac.dig('attributes','appStoreState')}
File.write(File.join(out,'submission-final-readback.json'),JSON.pretty_generate(result)+"\n"); puts JSON.pretty_generate(result)
