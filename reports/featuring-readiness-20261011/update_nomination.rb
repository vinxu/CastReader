require '/Users/xuxuheng/.codex/skills/submit-castreader-ios-to-app-store/scripts/asc_client'
require 'json'
require 'time'
P=File.expand_path(__dir__)
ID='e12dea24-c8b4-45b6-828b-061d97d5d459'
def save(name,data);File.write(File.join(P,name),JSON.pretty_generate(data)+"\n");end
c=ASCClient.new
path="/v1/nominations/#{ID}?include=relatedApps,inAppEvents,supportedTerritories&limit[supportedTerritories]=200"
before=c.request('GET',path)
save('nomination-revision-before.json',before)
a=JSON.parse(File.read(File.join(P,'nomination-revision.json')))
expected=JSON.parse(File.read(File.join(P,'nomination.json')))['data']['attributes']
raise 'Nomination has changed since initial read' unless before['data']['attributes']==expected
raise 'Wrong state or app' unless before['data']['attributes']['state']=='SUBMITTED' && before['data'].dig('relationships','relatedApps','data').map{|x|x['id']}.include?('6757636395')
raise 'Field length exceeds limit' unless a['description'].length<=1000 && a['notes'].length<=500 && a['supplementalMaterialsUris'].length==5
payload={data:{type:'nominations',id:ID,attributes:a.merge('submitted'=>true)}}
save('nomination-revision-payload.json',payload)
unless ARGV.include?('--execute');puts JSON.generate(status:'VALIDATED',id:ID,changedFields:a.keys);exit;end
v=JSON.parse(File.read(File.join(P,'trial-production-check.json')))
raise 'Public guide must be verified first' unless v['base']=='https://press.castreader.com/' && v['epubTextMatchesTXT']
begin
 save('nomination-revision-response.json',c.request('PATCH',"/v1/nominations/#{ID}",payload))
rescue ASCError=>e
 save('nomination-revision-error.json',{status:e.status,document:e.document,ambiguous:e.ambiguous_write})
 raise unless e.ambiguous_write
end
after=c.request('GET',path);save('nomination-revision-after.json',after)
ba=before['data']['attributes'];aa=after['data']['attributes']
a.each{|k,v|raise "Mismatch: #{k}" unless k=='supplementalMaterialsUris' ? aa[k].sort==v.sort : aa[k]==v}
(ba.keys-a.keys-['lastModifiedDate']).each{|k|raise "Unexpected change: #{k}" unless aa[k]==ba[k]}
raise 'Related data changed' unless before['data']['relationships']==after['data']['relationships']
raise 'Wrong final state' unless aa['state']=='SUBMITTED'
r={verifiedAt:Time.now.utc.iso8601,id:ID,name:aa['name'],state:aa['state'],lastModifiedDate:aa['lastModifiedDate'],originalSubmittedDate:aa['submittedDate'],publishStartDate:aa['publishStartDate'],publishEndDate:aa['publishEndDate'],changedFields:a.keys,links:aa['supplementalMaterialsUris'],unrelatedFieldsAndRelationshipsPreserved:true}
save('nomination-receipt.json',r);puts JSON.pretty_generate(r)
