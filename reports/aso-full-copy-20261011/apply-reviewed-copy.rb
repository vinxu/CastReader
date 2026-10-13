# Metadata-only transaction plan with per-resource readback; no version, build or review mutations.
require 'json'
require 'time'
require_relative '../../scripts/aso_metadata'
require '/Users/xuxuheng/.codex/skills/submit-castreader-ios-to-app-store/scripts/asc_client'
ROOT=File.expand_path('../..',__dir__)
OUT=__dir__
IOS='680b0b6d-968f-4a0c-a5a2-b8c25496e078'
MAC='e9065422-ce33-4ff5-81e1-a7b7aef4f7b4'
LIVE='968ba86c-0722-43fa-b55c-ff0425533966'
INFO='988607e7-fe9f-45ad-9432-86fca303d591'
HISTORICAL='6cb57cf9-7f8d-48d8-8845-a59995d8a66e'
def save(name,value)
 File.write(File.join(OUT,name),JSON.pretty_generate(value)+"\n")
end
def snapshot(c)
 {'checkedAt'=>Time.now.utc.iso8601,'versions'=>[IOS,MAC,LIVE].map { |id| {'version'=>c.request('GET',"/v1/appStoreVersions/#{id}").fetch('data'),'localizations'=>c.get_all("/v1/appStoreVersions/#{id}/appStoreVersionLocalizations?limit=200"),'build'=>c.request('GET',"/v1/appStoreVersions/#{id}/relationships/build").fetch('data')} },'appInfos'=>[INFO,HISTORICAL].map { |id| {'appInfo'=>c.request('GET',"/v1/appInfos/#{id}").fetch('data'),'localizations'=>c.get_all("/v1/appInfos/#{id}/appInfoLocalizations?limit=200")} }}
end
def attributes(items)
 items.to_h { |i| [i.fetch('id'),i.fetch('attributes')] }
end
c=ASCClient.new
catalog=ASOMetadata.catalog;descriptions=ASOMetadata.descriptions
errors=ASOMetadata.validate(catalog)+ASOMetadata.validate_descriptions(descriptions)
abort errors.join("\n") unless errors.empty?
if ARGV==['--apply']
 plan=JSON.parse(File.read(File.join(OUT,'planned-writes.json')))
 before=JSON.parse(File.read(File.join(OUT,'prewrite-snapshot.json')))
else
 abort 'Use no args to prepare or --apply to execute the reviewed plan' unless ARGV.empty?
 before=snapshot(c)
 original=JSON.parse(File.read(File.join(OUT,'online-before.json')))
 expected_states={IOS=>'PREPARE_FOR_SUBMISSION',MAC=>'WAITING_FOR_REVIEW',LIVE=>'READY_FOR_SALE'}
 before['versions'].each { |v| abort "Version state changed #{v['version']['id']}" unless expected_states[v['version']['id']]==v['version'].dig('attributes','appStoreState') }
 abort 'iOS draft already has a build; review scope again' unless before['versions'].find { |v| v['version']['id']==IOS }['build'].nil?
 abort 'Shared App Info state changed' unless before['appInfos'].find { |v| v['appInfo']['id']==INFO }.dig('appInfo','attributes','appStoreState')=='WAITING_FOR_REVIEW'
 plan=[]
 original['versions'].each do |group|
  id=group['version']['id'];fresh=before['versions'].find { |g| g['version']['id']==id }
  group['localizations'].each do |item|
   attrs=item['attributes'];locale=attrs['locale'];r=catalog['localizations'].fetch(locale)
   target={'keywords'=>r['keywords']};target['description']=descriptions['localizations'][locale]['description'] if id==IOS
   delta=target.reject { |k,v| attrs[k]==v };next if delta.empty?
   actual=fresh['localizations'].find { |i| i['id']==item['id'] }
   abort "Concurrent change detected #{locale}" unless actual && actual['attributes']==attrs
   plan << {'type'=>'appStoreVersionLocalizations','id'=>item['id'],'locale'=>locale,'platform'=>id==IOS ? 'IOS' : 'MAC_OS','before'=>attrs,'attributes'=>delta}
  end
 end
 original_info=original['appInfos'].find { |g| g['appInfo']['id']==INFO }
 fresh_info=before['appInfos'].find { |g| g['appInfo']['id']==INFO }
 original_info['localizations'].each do |item|
  attrs=item['attributes'];locale=attrs['locale'];r=catalog['localizations'].fetch(locale)
  target=r.select { |k,_| %w[name subtitle].include?(k) };delta=target.reject { |k,v| attrs[k]==v };next if delta.empty?
  actual=fresh_info['localizations'].find { |i| i['id']==item['id'] }
  abort "Concurrent App Info change #{locale}" unless actual && actual['attributes']==attrs
  plan << {'type'=>'appInfoLocalizations','id'=>item['id'],'locale'=>locale,'platform'=>'SHARED','before'=>attrs,'attributes'=>delta}
 end
 save('prewrite-snapshot.json',before);save('planned-writes.json',plan)
 puts JSON.generate(prepared:true,resources:plan.size,byPlatform:plan.group_by { |p| p['platform'] }.transform_values(&:size),fields:plan.flat_map { |p| p['attributes'].keys }.group_by(&:itself).transform_values(&:size))
 exit
end
# Revalidate mutable-state parents immediately before the first write.
[[IOS,'appStoreVersions','PREPARE_FOR_SUBMISSION'],[MAC,'appStoreVersions','WAITING_FOR_REVIEW'],[INFO,'appInfos','WAITING_FOR_REVIEW']].each do |id,type,state|
 actual=c.request('GET',"/v1/#{type}/#{id}").fetch('data')
 abort "State changed before apply #{id}" unless actual.dig('attributes','appStoreState')==state
end
receipt=[]
plan.each do |op|
 path="/v1/#{op['type']}/#{op['id']}"
 current=c.request('GET',path).fetch('data').fetch('attributes')
 expected=op['before'].merge(op['attributes'])
 if current==expected
  status='already_applied_verified'
 else
  abort "Concurrent change before write #{op['locale']} #{op['platform']}" unless current==op['before']
  begin
   c.request('PATCH',path,{data:{type:op['type'],id:op['id'],attributes:op['attributes']}})
  rescue ASCError => e
   # Unknown outcomes are resolved by reading; never blind-retry a write.
   actual=c.request('GET',path).fetch('data').fetch('attributes')
   raise unless actual==expected
  end
  actual=c.request('GET',path).fetch('data').fetch('attributes')
  abort "Readback mismatch #{op['locale']} #{op['platform']}" unless actual==expected
  status='applied_verified'
 end
 receipt << op.slice('platform','locale','id').merge('fields'=>op['attributes'].keys,'status'=>status,'checkedAt'=>Time.now.utc.iso8601)
 save('write-receipt.json',receipt)
 puts "#{op['platform']} #{op['locale']} #{op['attributes'].keys.join(',')}: #{status}"
 STDOUT.flush
end
after=snapshot(c);save('online-after.json',after)
errors=[]
# Verify every intended and untouched field, including published iOS and historical App Info.
[['versions','version','appStoreVersionLocalizations'],['appInfos','appInfo','appInfoLocalizations']].each do |key,parent,type|
 before[key].each do |group|
  result=after[key].find { |g| g[parent]['id']==group[parent]['id'] }
  errors << "Parent state changed #{group[parent]['id']}" unless result[parent]['attributes']==group[parent]['attributes']
  errors << "Build relationship changed #{group[parent]['id']}" if key=='versions' && result['build']!=group['build']
  expected=attributes(group['localizations'])
  plan.select { |p| p['type']==type && expected.key?(p['id']) }.each { |p| expected[p['id']]=expected[p['id']].merge(p['attributes']) }
  errors << "Unexpected field change #{group[parent]['id']}" unless expected==attributes(result['localizations'])
 end
end
iloc=after['versions'].find { |v| v['version']['id']==IOS }['localizations']
mloc=after['versions'].find { |v| v['version']['id']==MAC }['localizations']
aloc=after['appInfos'].find { |v| v['appInfo']['id']==INFO }['localizations']
errors.concat(ASOMetadata.compare(catalog,version_localizations:iloc,app_info_localizations:aloc))
errors.concat(ASOMetadata.compare_descriptions(descriptions,version_localizations:iloc))
errors.concat(ASOMetadata.compare(catalog,version_localizations:mloc,app_info_localizations:aloc))
final={passed:errors.empty?,checkedAt:Time.now.utc.iso8601,resources:receipt.size,iosLocales:iloc.size,sharedInfoLocales:aloc.size,descriptionLocales:descriptions['localizations'].size,fields:plan.flat_map { |p| p['attributes'].keys }.group_by(&:itself).transform_values(&:size),iosVersion:'1.2.49',iosVersionId:IOS,iosState:'PREPARE_FOR_SUBMISSION',iosBuild:nil,macVersion:'1.2.48',macState:'WAITING_FOR_REVIEW',untouchedFieldsVerified:errors.empty?,publishedIOSPreserved:errors.empty?,historicalAppInfoPreserved:errors.empty?,macDescriptionsPreserved:errors.empty?,errors:errors}
save('completion-receipt.json',final)
puts JSON.generate(final)
exit(errors.empty? ? 0 : 1)
