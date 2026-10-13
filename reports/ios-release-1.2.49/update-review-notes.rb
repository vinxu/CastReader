require 'json'
require '/Users/xuxuheng/.codex/skills/submit-castreader-ios-to-app-store/scripts/asc_client'
c=ASCClient.new;r=JSON.parse(File.read(File.join(__dir__,'asc-baseline-private.json')))['review'];old=r['attributes']['notes'];blocks=old.split("\n\n")
abort 'Unexpected old review introduction' unless blocks[0].start_with?('BUILD 72 RESUBMISSION') && blocks[1].start_with?('Version 1.2.47')
intro="VERSION 1.2.49 (77) — LOCALIZED STORE INFORMATION\nThis update improves App Store names, subtitles, keywords and descriptions across 29 localizations. App behavior and embedded resources are unchanged from approved iOS 1.2.48 (75); only version/build identifiers advance. The international app supports 28 languages; China retains nine. Review instructions below still apply."
notes=([intro]+blocks.drop(2)).join("\n\n")
abort 'Review notes exceed limit' if notes.length>4000
path="/v1/appStoreReviewDetails/#{r['id']}";before=c.request('GET',path)['data']['attributes'];abort 'Concurrent review edit' unless before==r['attributes']
begin;c.request('PATCH',path,{data:{type:'appStoreReviewDetails',id:r['id'],attributes:{notes:notes}}});rescue ASCError
 raise unless c.request('GET',path)['data']['attributes']==before.merge('notes'=>notes)
end
after=c.request('GET',path)['data'];abort 'Review fields changed unexpectedly' unless after['attributes']==before.merge('notes'=>notes)
File.open(File.join(__dir__,'review-detail-final-private.json'),'w',0o600){|f|f.write(JSON.pretty_generate(after)+"\n")}
puts JSON.generate(status:'PASS',noteCharacters:notes.length,reviewInstructionsPreserved:true,contactsAndAccountFieldsPreserved:true)
