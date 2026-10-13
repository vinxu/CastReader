require 'json'
require 'time'
require '/Users/xuxuheng/.codex/skills/submit-castreader-ios-to-app-store/scripts/asc_client'
OUT=__dir__;ROOT=File.expand_path('../..',OUT);VERSION='680b0b6d-968f-4a0c-a5a2-b8c25496e078'
def save(name,x)
 File.open(File.join(OUT,name),'w',0o600) { |f| f.write(JSON.pretty_generate(x)+"\n") }
end
c=ASCClient.new
version=c.request('GET',"/v1/appStoreVersions/#{VERSION}")['data'];abort 'Wrong target state' unless version.dig('attributes','appStoreState')=='PREPARE_FOR_SUBMISSION'
locs=c.get_all("/v1/appStoreVersions/#{VERSION}/appStoreVersionLocalizations?limit=200")
review=c.request('GET',"/v1/appStoreVersions/#{VERSION}/appStoreReviewDetail")['data']
raise 'Missing review details' unless review
infos=%w[988607e7-fe9f-45ad-9432-86fca303d591 6cb57cf9-7f8d-48d8-8845-a59995d8a66e].map { |id| {'id'=>id,'localizations'=>c.get_all("/v1/appInfos/#{id}/appInfoLocalizations?limit=200")} }
subs=c.get_all('/v1/apps/6757636395/reviewSubmissions?filter[platform]=IOS&limit=200').reject { |s| %w[COMPLETE CANCELED].include?(s.dig('attributes','state')) }.map { |s| {'submission'=>s,'items'=>c.get_all("/v1/reviewSubmissions/#{s['id']}/items?include=appStoreVersion,appCustomProductPageVersion&limit=200")} }
save('asc-baseline-private.json',{'version'=>version,'localizations'=>locs,'review'=>review,'appInfos'=>infos,'submissions'=>subs})
queue=Queue.new;locs.each { |l| queue << l };shots={};lock=Mutex.new
workers=4.times.map do
 Thread.new do
  client=ASCClient.new
  loop do
   begin;loc=queue.pop(true);rescue ThreadError;break;end
   sets=client.get_all("/v1/appStoreVersionLocalizations/#{loc['id']}/appScreenshotSets?limit=200")
   item=sets.map { |s| {'set'=>s,'images'=>client.get_all("/v1/appScreenshotSets/#{s['id']}/appScreenshots?limit=200")} }
   lock.synchronize { shots[loc.dig('attributes','locale')]=item }
  end
 end
end
workers.each(&:value);save('screenshots-baseline.json',shots)
errors=[]
shots.each do |locale,sets|
 %w[APP_IPHONE_67 APP_IPAD_PRO_3GEN_129].each do |display|
  matching=sets.select { |s| s.dig('set','attributes','screenshotDisplayType')==display }
  errors << "#{locale}/#{display}: need five COMPLETE" unless matching.size==1 && matching[0]['images'].size==5 && matching[0]['images'].all? { |i| i.dig('attributes','assetDeliveryState','state')=='COMPLETE' }
 end
end
abort errors.join("\n") unless errors.empty?
notes=JSON.parse(File.read(File.join(ROOT,'docs/AppStore-Whats-New-1.2.49.json')))
expected=JSON.parse(File.read(File.join(OUT,'expected-localizations.json')))
abort 'Locale set differs' unless notes.keys.sort==locs.map { |l| l.dig('attributes','locale') }.sort
receipts=[]
locs.each do |l|
 locale=l.dig('attributes','locale');attrs=l['attributes'];want=expected.fetch(locale)
 %w[description keywords supportUrl marketingUrl promotionalText].each { |k| abort "Concurrent change #{locale}/#{k}" unless attrs[k].to_s==want[k].to_s }
 path="/v1/appStoreVersionLocalizations/#{l['id']}"
 unless attrs['whatsNew']==notes[locale]
  begin;c.request('PATCH',path,{data:{type:'appStoreVersionLocalizations',id:l['id'],attributes:{whatsNew:notes[locale]}}});rescue ASCError => e
   raise unless c.request('GET',path)['data']['attributes']==attrs.merge('whatsNew'=>notes[locale])
  end
 end
 result=c.request('GET',path)['data']['attributes'];abort "Readback differs #{locale}" unless result==attrs.merge('whatsNew'=>notes[locale])
 receipts << {locale:locale,status:'verified',fields:['whatsNew']};save('whats-new-receipts.json',receipts)
 puts "#{locale}: What's New verified";STDOUT.flush
end
# Release-specific explanation only; preserve contacts and existing demo credentials.
existing=review.dig('attributes','notes').to_s
add="Release 1.2.49 (77): This update refreshes localized App Store names, subtitles, keywords and descriptions across 29 storefront localizations. App functionality and embedded resources are unchanged from approved iOS 1.2.48 (75); only version/build identifiers advance. It does not introduce OCR model downloads or change language detection."
newnotes=existing.include?(add) ? existing : add+"\n\n"+existing
abort 'Review notes exceed limit' if newnotes.length>4000
abort 'Rejected reference in reviewer notes' if newnotes.match?(/google[\s-]*play|play[\s-]*books|play\.google\.com/i)
path="/v1/appStoreReviewDetails/#{review['id']}"
c.request('PATCH',path,{data:{type:'appStoreReviewDetails',id:review['id'],attributes:{notes:newnotes}}}) unless existing==newnotes
actual=c.request('GET',path)['data'];abort 'Review details drift' unless actual['attributes']==review['attributes'].merge('notes'=>newnotes)
save('review-detail-final-private.json',actual)
puts JSON.generate(status:'PASS',locales:locs.size,screenshots:shots.values.flat_map { |s| s.flat_map { |x| x['images'] } }.size,reviewCredentialsPresent:!actual.dig('attributes','demoAccountName').to_s.empty?,reviewNotesUpdated:true)
