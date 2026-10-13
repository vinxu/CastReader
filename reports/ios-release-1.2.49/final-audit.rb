require 'json'
require 'time'
require 'digest'
require '/Users/xuxuheng/.codex/skills/submit-castreader-ios-to-app-store/scripts/asc_client'
require_relative '../../scripts/aso_metadata'
OUT=__dir__
def read(name); JSON.parse(File.read(File.join(OUT,name))); end
def save(name,data); File.open(File.join(OUT,name),'w',0o600) { |f| f.write(JSON.pretty_generate(data)+"\n") }; end
c=ASCClient.new; plan=read('release-plan.json'); errors=[]
version=c.request('GET',"/v1/appStoreVersions/#{plan['versionId']}")['data']
locs=c.get_all("/v1/appStoreVersions/#{plan['versionId']}/appStoreVersionLocalizations?limit=200")
expected=read('expected-localizations.json')
notes=JSON.parse(File.read(File.expand_path('../../docs/AppStore-Whats-New-1.2.49.json',OUT)))
errors << 'Locale coverage mismatch' unless locs.map { |l| l.dig('attributes','locale') }.sort==expected.keys.sort
locs.each do |l|
 locale=l.dig('attributes','locale'); want=expected.fetch(locale).merge('whatsNew'=>notes.fetch(locale))
 %w[description keywords supportUrl marketingUrl promotionalText whatsNew].each do |field|
  errors << "#{locale}/#{field}: changed" unless l.dig('attributes',field).to_s==want[field].to_s
 end
end
baseline=read('asc-baseline-private.json')
infos=baseline['appInfos'].map do |info|
 current=c.get_all("/v1/appInfos/#{info['id']}/appInfoLocalizations?limit=200")
 index=lambda { |xs| xs.to_h { |x| [x.dig('attributes','locale'),x['attributes']] } }
 errors << "App Info attributes changed: #{info['id']}" unless index.call(current)==index.call(info['localizations'])
 {'id'=>info['id'],'localizations'=>current}
end
pending=infos.find { |i| i['id']==plan['appInfoId'] }['localizations']
errors.concat(ASOMetadata.compare(ASOMetadata.catalog,version_localizations:locs,app_info_localizations:pending))
errors.concat(ASOMetadata.compare_descriptions(ASOMetadata.descriptions,version_localizations:locs))
review=c.request('GET',"/v1/appStoreVersions/#{plan['versionId']}/appStoreReviewDetail")['data']
errors << 'Review details changed' unless review['attributes']==read('review-detail-final-private.json')['attributes']
if review.dig('attributes','demoAccountRequired')
 %w[demoAccountName demoAccountPassword].each { |k| errors << "Review missing #{k}" if review.dig('attributes',k).to_s.empty? }
end
build=c.request('GET',"/v1/appStoreVersions/#{plan['versionId']}/build")['data']
if build
 attrs=build['attributes']; pre=c.request('GET',"/v1/builds/#{build['id']}/preReleaseVersion")['data']['attributes']
 errors << 'Build mismatch' unless attrs['version']=='77' && attrs['processingState']=='VALID' && attrs['buildAudienceType']=='APP_STORE_ELIGIBLE' && attrs['usesNonExemptEncryption']==false && pre['version']=='1.2.49' && pre['platform']=='IOS'
else
 errors << 'Missing build'
end
errors << 'Release mode differs' unless version.dig('attributes','releaseType')=='AFTER_APPROVAL'
core=read('core-gate.json'); cells=core['regions'].values.flat_map(&:values)
errors << 'Core/source gate incomplete' unless core['status']=='PASS' && core['archiveSourceVerified']==true && cells.size==12 && cells.all? { |x| x['status']=='PASS' && x['evidence'].all? { |p| File.exist?(p) } }
archive=read('archive-verification.json')
errors << 'Archive mismatch' unless archive['status']=='PASS' && archive['sourceCommit']==plan['sourceCommit'] && archive['applicationManifestSHA256']==core['applicationManifestSHA256']
errors << 'Public metadata links failed' unless read('metadata-links.json')['passed']==true
errors << 'Screenshot source identity failed' unless read('screenshot-source-identity.json')['status']=='PASS'
generic=read('asc-release-audit.json')
errors << 'Generic release audit failed' unless generic['errors']==[]
generic.fetch('screenshots').each do |locale,detail|
 sets=detail['sets']; errors << "#{locale}: screenshot coverage" unless sets.size==2 && sets.map { |s| s['displayType'] }.sort==%w[APP_IPHONE_67 APP_IPAD_PRO_3GEN_129].sort && sets.all? { |s| s['total']==5 && s['complete']==5 }
end
errors << 'Archive payload changed during upload' unless read('post-upload-archive-integrity.json')['status']=='PASS'
save('asc-final-private.json',{'version'=>version,'localizations'=>locs,'appInfos'=>infos,'review'=>review,'build'=>build})
result={status:errors.empty? ? 'PASS' : 'FAIL',checkedAt:Time.now.utc.iso8601,versionId:plan['versionId'],buildId:build && build['id'],storeLocales:locs.size,coreCells:cells.size,screenshots:290,canonicalASOCopyExact:true,appInfoAttributesPreserved:true,reviewDetailsPreserved:true,releaseType:version.dig('attributes','releaseType'),errors:errors}
save('final-release-audit.json',result);puts JSON.pretty_generate(result);exit(errors.empty? ? 0 : 1)
