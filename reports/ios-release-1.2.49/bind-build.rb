require 'json'
require '/Users/xuxuheng/.codex/skills/submit-castreader-ios-to-app-store/scripts/asc_client'
out=__dir__; plan=JSON.parse(File.read(File.join(out,'release-plan.json'))); receipt=JSON.parse(File.read(File.join(out,'build-77.json')))
c=ASCClient.new; id=receipt.fetch('id')
build=c.request('GET',"/v1/builds/#{id}")['data']; attrs=build['attributes']
pre=c.request('GET',"/v1/builds/#{id}/preReleaseVersion")['data']['attributes']
abort 'Wrong or ineligible build' unless attrs['version']=='77' && attrs['processingState']=='VALID' && attrs['buildAudienceType']=='APP_STORE_ELIGIBLE' && pre['version']=='1.2.49' && pre['platform']=='IOS'
abort 'Encryption declaration changed' unless attrs['usesNonExemptEncryption']==false
version=c.request('GET',"/v1/appStoreVersions/#{plan['versionId']}")['data']
abort 'Version state changed' unless %w[PREPARE_FOR_SUBMISSION READY_FOR_REVIEW].include?(version.dig('attributes','appStoreState')) && version.dig('attributes','releaseType')=='AFTER_APPROVAL'
path="/v1/appStoreVersions/#{plan['versionId']}/relationships/build"
current=c.request('GET',"/v1/appStoreVersions/#{plan['versionId']}/build")['data']
abort 'Unexpected existing build binding' if current && current['id']!=id
c.request('PATCH',path,{data:{type:'builds',id:id}}) unless current
bound=c.request('GET',"/v1/appStoreVersions/#{plan['versionId']}/build")['data']
abort 'Build binding readback mismatch' unless bound['id']==id
result={status:'PASS',versionId:plan['versionId'],buildId:id,build:'77',version:'1.2.49',platform:'IOS'}
File.write(File.join(out,'build-binding.json'),JSON.pretty_generate(result)+"\n");puts JSON.pretty_generate(result)
